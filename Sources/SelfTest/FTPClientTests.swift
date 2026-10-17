import Foundation
import SFTPsurfCore

/// FTP client integration tests, run against a real Python FTP server so both
/// the MLSD path and the plain `LIST` fallback are covered.
enum FTPClientTests {
    static var cases: [TestCase] {
        [
            TestCase("connects and reports the working directory") {
                try await requireServer()
                let home = try await FTPServerFixture.withSession { client, _, _ in
                    try await client.homePath()
                }
                try expect(home == "/" || home.hasPrefix("/"), "got \(home)")
            },

            TestCase("login with a wrong password fails") {
                try await requireServer()
                try await FTPServerFixture.withServer { profile, _ in
                    let client = FTPClient()
                    try await expectThrows("a bad password must be rejected") {
                        try await client.connect(
                            profile: profile,
                            credential: Credential(password: "definitely-wrong")
                        )
                    }
                    await client.disconnect()
                }
            },

            TestCase("listing reports files and directories") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, root in
                    try Data("hello".utf8).write(to: root.appendingPathComponent("alpha.txt"))
                    try Data(repeating: 0x42, count: 2048)
                        .write(to: root.appendingPathComponent("beta.bin"))
                    try FileManager.default.createDirectory(
                        at: root.appendingPathComponent("subdir"),
                        withIntermediateDirectories: true
                    )

                    let entries = try await client.list("/")
                    let names = entries.map(\.name)

                    try expect(names.contains("alpha.txt"), "got \(names)")
                    try expect(names.contains("beta.bin"))
                    try expect(names.contains("subdir"))
                    try expect(names.first == "subdir", "directories should sort first")

                    let subdir = try require(entries.first { $0.name == "subdir" })
                    try expect(subdir.isDirectory)
                    try expect(subdir.isDirectory && subdir.isSymlink == false)

                    let alpha = try require(entries.first { $0.name == "alpha.txt" })
                    try expect(alpha.isDirectory == false)
                    try expect(alpha.size == 5, "expected 5 bytes, got \(alpha.size)")
                    try expect(alpha.modified != nil, "listing should carry a timestamp")
                }
            },

            TestCase("listing works when the server has no MLSD") {
                try await requireServer()
                // Forces the classic LIST parser, which is all older servers offer.
                try await FTPServerFixture.withSession(enableMLSD: false) { client, _, root in
                    try Data("legacy".utf8).write(to: root.appendingPathComponent("legacy.txt"))
                    try FileManager.default.createDirectory(
                        at: root.appendingPathComponent("folder"),
                        withIntermediateDirectories: true
                    )

                    let entries = try await client.list("/")
                    let names = entries.map(\.name)

                    try expect(names.contains("legacy.txt"), "got \(names)")
                    try expect(names.contains("folder"))

                    let folder = try require(entries.first { $0.name == "folder" })
                    try expect(folder.isDirectory, "LIST parsing must detect directories")

                    let file = try require(entries.first { $0.name == "legacy.txt" })
                    try expect(file.isDirectory == false)
                    try expect(file.size == 6, "expected 6 bytes, got \(file.size)")
                }
            },

            TestCase("listing a missing directory fails cleanly") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, _ in
                    try await expectThrows("listing a missing directory must throw") {
                        _ = try await client.list("/no-such-directory")
                    }
                }
            },

            TestCase("attributes describe a file") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, root in
                    try Data("1234567890".utf8).write(to: root.appendingPathComponent("sized.txt"))

                    let entry = try require(try await client.attributes(of: "/sized.txt"))
                    try expect(entry.size == 10, "got \(entry.size)")
                    try expect(entry.isDirectory == false)

                    let missing = try await client.attributes(of: "/absent.txt")
                    try expect(missing == nil)
                }
            },

            TestCase("create, rename and remove round trip") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, root in
                    try await client.createDirectory("/newdir")
                    try expect(
                        FileManager.default.fileExists(
                            atPath: root.appendingPathComponent("newdir").path
                        ),
                        "MKD should have created a real directory"
                    )

                    try Data("payload".utf8).write(to: root.appendingPathComponent("newdir/move-me.txt"))
                    try await client.rename("/newdir/move-me.txt", to: "/newdir/moved.txt")

                    try expect(
                        FileManager.default.fileExists(
                            atPath: root.appendingPathComponent("newdir/moved.txt").path
                        ),
                        "RNFR/RNTO should have moved the file"
                    )

                    try await client.removeFile("/newdir/moved.txt")
                    try expect(
                        FileManager.default.fileExists(
                            atPath: root.appendingPathComponent("newdir/moved.txt").path
                        ) == false
                    )

                    try await client.removeDirectory("/newdir")
                    try expect(
                        FileManager.default.fileExists(
                            atPath: root.appendingPathComponent("newdir").path
                        ) == false
                    )
                }
            },

            TestCase("upload and download round trip byte for byte") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, root in
                    // Bigger than a single 128 KB write, and not a round multiple.
                    let payload = Data((0..<(300 * 1024 + 777)).map { UInt8($0 % 253) })
                    let source = try TestSupport.makeSandbox().appendingPathComponent("payload.bin")
                    try payload.write(to: source)
                    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

                    let uploadRecorder = TestSupport.ProgressRecorder()
                    try await client.upload(
                        localURL: source,
                        to: "/uploaded.bin",
                        progress: { done, total in uploadRecorder.record(done: done, total: total) }
                    )

                    let onDisk = root.appendingPathComponent("uploaded.bin")
                    let stored = try Data(contentsOf: onDisk)
                    try expect(
                        stored == payload,
                        "server stored \(stored.count) bytes that differ from the source"
                    )

                    let destination = try TestSupport.makeSandbox().appendingPathComponent("downloaded.bin")
                    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

                    let downloadRecorder = TestSupport.ProgressRecorder()
                    try await client.download(
                        remotePath: "/uploaded.bin",
                        to: destination,
                        progress: { done, total in downloadRecorder.record(done: done, total: total) }
                    )

                    let roundTripped = try Data(contentsOf: destination)
                    try expect(
                        roundTripped == payload,
                        "downloaded \(roundTripped.count) bytes that differ from the source"
                    )
                    try expect(uploadRecorder.last?.done == Int64(payload.count))
                    try expect(downloadRecorder.last?.done == Int64(payload.count))
                }
            },

            TestCase("uploading an empty file yields an empty file") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, root in
                    let empty = try TestSupport.makeSandbox().appendingPathComponent("empty.bin")
                    try Data().write(to: empty)
                    defer { try? FileManager.default.removeItem(at: empty.deletingLastPathComponent()) }

                    try await client.upload(localURL: empty, to: "/empty.bin", progress: nil)

                    let stored = try Data(contentsOf: root.appendingPathComponent("empty.bin"))
                    try expect(stored.isEmpty, "expected no bytes, got \(stored.count)")
                }
            },

            TestCase("a failed download leaves no partial file behind") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, _ in
                    let destination = try TestSupport.makeSandbox().appendingPathComponent("partial.bin")
                    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

                    try await expectThrows("downloading a missing file must throw") {
                        try await client.download(
                            remotePath: "/absent.bin",
                            to: destination,
                            progress: nil
                        )
                    }
                    try expect(
                        FileManager.default.fileExists(atPath: destination.path) == false,
                        "a failed download must not leave a partial file"
                    )
                }
            },

            TestCase("downloads a nested path") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, root in
                    let nested = root.appendingPathComponent("a/b")
                    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                    try Data("deep".utf8).write(to: nested.appendingPathComponent("deep.txt"))

                    let entries = try await client.list("/a/b")
                    try expect(entries.map(\.name) == ["deep.txt"], "got \(entries.map(\.name))")

                    let destination = try TestSupport.makeSandbox()
                        .appendingPathComponent("deep.txt")
                    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

                    try await client.download(remotePath: "/a/b/deep.txt", to: destination, progress: nil)
                    try expect(try String(contentsOf: destination, encoding: .utf8) == "deep")
                }
            },

            TestCase("operations after disconnect fail instead of hanging") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, _ in
                    await client.disconnect()
                    try await expectThrows("listing after disconnect must throw") {
                        _ = try await client.list("/")
                    }
                }
            },

            TestCase("concurrent transfers on one session all succeed") {
                try await requireServer()
                // FTP carries every command over a single control connection, so
                // overlapping transfers used to cross their PASV replies and
                // completion codes. They must be serialised instead.
                try await FTPServerFixture.withSession { client, _, root in
                    var remotePaths: [String] = []
                    for index in 0..<5 {
                        let name = "concurrent-\(index).bin"
                        let payload = Data((0..<(60_000 + index * 7_000)).map { UInt8(($0 + index) % 251) })
                        try payload.write(to: root.appendingPathComponent(name))
                        remotePaths.append("/" + name)
                    }

                    let destinationDirectory = try TestSupport.makeSandbox()
                    defer { try? FileManager.default.removeItem(at: destinationDirectory) }

                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for path in remotePaths {
                            group.addTask {
                                let name = (path as NSString).lastPathComponent
                                try await client.download(
                                    remotePath: path,
                                    to: destinationDirectory.appendingPathComponent(name),
                                    progress: nil
                                )
                            }
                        }
                        try await group.waitForAll()
                    }

                    for (index, path) in remotePaths.enumerated() {
                        let name = (path as NSString).lastPathComponent
                        let original = try Data(contentsOf: root.appendingPathComponent(name))
                        let downloaded = try Data(
                            contentsOf: destinationDirectory.appendingPathComponent(name)
                        )
                        try expect(
                            downloaded == original,
                            "file \(index) came back as \(downloaded.count) bytes, expected \(original.count)"
                        )
                    }
                }
            },

            TestCase("listing during a transfer does not corrupt either") {
                try await requireServer()
                try await FTPServerFixture.withSession { client, _, root in
                    let name = "mixed.bin"
                    let payload = Data((0..<400_000).map { UInt8($0 % 249) })
                    try payload.write(to: root.appendingPathComponent(name))

                    let destination = try TestSupport.makeSandbox()
                        .appendingPathComponent("mixed.bin")
                    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

                    // A listing races the download for the control connection.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await client.download(
                                remotePath: "/" + name,
                                to: destination,
                                progress: nil
                            )
                        }
                        group.addTask {
                            _ = try await client.list("/")
                        }
                        try await group.waitForAll()
                    }

                    let downloaded = try Data(contentsOf: destination)
                    try expect(
                        downloaded == payload,
                        "got \(downloaded.count) bytes, expected \(payload.count)"
                    )
                }
            },
        ]
    }

    private static func requireServer() async throws {
        switch FTPServerFixture.availability {
        case .ready:
            return
        case .unavailable(let reason):
            try skip(reason)
        }
    }
}
