import Foundation
import SFTPsurfCore

/// Exercises the SFTP protocol layer end to end against macOS's own
/// `sftp-server`, which speaks the same wire protocol as a remote OpenSSH
/// server.
enum SFTPClientTests {
    static var cases: [TestCase] {
        [
            TestCase("handshake reports an absolute home directory") {
                try await requireServer()
                let home = try await TestSupport.withLocalSFTPSession { client, _ in
                    try await client.homePath()
                }
                try expect(home.hasPrefix("/"), "home should be absolute, got \(home)")
            },

            TestCase("list returns files and directories with directories first") {
                try await requireServer()
                let names = try await TestSupport.withLocalSFTPSession { client, sandbox in
                    try Data("hello".utf8).write(to: sandbox.appendingPathComponent("alpha.txt"))
                    try Data(repeating: 0x41, count: 4096)
                        .write(to: sandbox.appendingPathComponent("big.bin"))
                    try FileManager.default.createDirectory(
                        at: sandbox.appendingPathComponent("nested"),
                        withIntermediateDirectories: true
                    )
                    return try await client.list(sandbox.path).map(\.name)
                }

                try expect(Set(names) == ["alpha.txt", "big.bin", "nested"], "got \(names)")
                try expect(names.first == "nested", "directories must sort above files")
            },

            TestCase("list reports sizes, timestamps and mode bits") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    try Data("hello".utf8).write(to: sandbox.appendingPathComponent("alpha.txt"))
                    try FileManager.default.createDirectory(
                        at: sandbox.appendingPathComponent("nested"),
                        withIntermediateDirectories: true
                    )

                    let entries = try await client.list(sandbox.path)

                    let alpha = try require(
                        entries.first { $0.name == "alpha.txt" }, "alpha.txt missing"
                    )
                    try expect(alpha.size == 5, "expected 5 bytes, got \(alpha.size)")
                    try expect(alpha.isDirectory == false)
                    try expect(alpha.modified != nil, "modification date should be present")
                    try expect(alpha.permissionString?.count == 10)

                    let nested = try require(
                        entries.first { $0.name == "nested" }, "nested missing"
                    )
                    try expect(nested.isDirectory)
                    try expect(nested.permissionString?.hasPrefix("d") == true)
                }
            },

            TestCase("list omits dot entries") {
                try await requireServer()
                let entries = try await TestSupport.withLocalSFTPSession { client, sandbox in
                    try await client.list(sandbox.path)
                }
                try expect(entries.contains { $0.name == "." } == false)
                try expect(entries.contains { $0.name == ".." } == false)
            },

            TestCase("listing a missing directory fails cleanly") {
                try await requireServer()
                try await expectThrows {
                    try await TestSupport.withLocalSFTPSession { client, sandbox in
                        _ = try await client.list(sandbox.appendingPathComponent("does-not-exist").path)
                    }
                }
            },

            TestCase("attributes describe files and report missing paths as nil") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let file = sandbox.appendingPathComponent("meta.txt")
                    try Data("meta".utf8).write(to: file)

                    let entry = try require(try await client.attributes(of: file.path))
                    try expect(entry.size == 4)
                    try expect(entry.isDirectory == false)

                    let missing = try await client.attributes(
                        of: sandbox.appendingPathComponent("ghost").path
                    )
                    try expect(missing == nil, "a missing path should give nil, not an error")
                }
            },

            TestCase("create, rename and remove round trip") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let directory = sandbox.appendingPathComponent("created")
                    try await client.createDirectory(directory.path)

                    let afterCreate = try await client.list(sandbox.path)
                    try expect(afterCreate.contains { $0.name == "created" && $0.isDirectory })

                    let original = directory.appendingPathComponent("original.txt")
                    try Data("content".utf8).write(to: original)

                    let renamed = directory.appendingPathComponent("renamed.txt").path
                    try await client.rename(original.path, to: renamed)

                    let afterRename = try await client.list(directory.path)
                    try expect(afterRename.map(\.name) == ["renamed.txt"])

                    try await client.removeFile(renamed)
                    let afterRemove = try await client.list(directory.path)
                    try expect(afterRemove.isEmpty)

                    try await client.removeDirectory(directory.path)
                    let root = try await client.list(sandbox.path)
                    try expect(root.contains { $0.name == "created" } == false)
                }
            },

            TestCase("rename overwrites an existing destination") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let source = sandbox.appendingPathComponent("source.txt")
                    let destination = sandbox.appendingPathComponent("destination.txt")
                    try Data("from source".utf8).write(to: source)
                    try Data("already here".utf8).write(to: destination)

                    try await client.rename(source.path, to: destination.path)

                    let contents = try String(contentsOf: destination, encoding: .utf8)
                    try expect(contents == "from source", "got \(contents)")
                    try expect(FileManager.default.fileExists(atPath: source.path) == false)
                }
            },

            TestCase("setPermissions changes the mode") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let file = sandbox.appendingPathComponent("perms.txt")
                    try Data("x".utf8).write(to: file)

                    try await client.setPermissions(file.path, mode: 0o600)

                    let entry = try require(try await client.attributes(of: file.path))
                    let mode = try require(entry.permissions) & 0o777
                    try expect(mode == 0o600, "expected 0600, got \(String(mode, radix: 8))")
                }
            },

            TestCase("upload and download round trip byte for byte") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    // Larger than one 32 KB chunk, and not a round multiple of it.
                    let payload = Data((0..<(200 * 1024 + 1234)).map { UInt8($0 % 251) })
                    let source = sandbox.appendingPathComponent("payload.bin")
                    try payload.write(to: source)

                    let remotePath = sandbox.appendingPathComponent("uploaded.bin").path
                    let uploadRecorder = TestSupport.ProgressRecorder()
                    try await client.upload(
                        localURL: source,
                        to: remotePath,
                        progress: { done, total in uploadRecorder.record(done: done, total: total) }
                    )

                    let uploaded = try require(try await client.attributes(of: remotePath))
                    try expect(
                        uploaded.size == Int64(payload.count),
                        "server stored \(uploaded.size) of \(payload.count) bytes"
                    )
                    try expect(uploadRecorder.isEmpty == false, "upload reported no progress")
                    try expect(uploadRecorder.last?.done == Int64(payload.count))

                    let destination = sandbox.appendingPathComponent("downloaded.bin")
                    let downloadRecorder = TestSupport.ProgressRecorder()
                    try await client.download(
                        remotePath: remotePath,
                        to: destination,
                        progress: { done, total in downloadRecorder.record(done: done, total: total) }
                    )

                    let roundTripped = try Data(contentsOf: destination)
                    try expect(
                        roundTripped == payload,
                        "downloaded \(roundTripped.count) bytes that differ from the source"
                    )
                    try expect(downloadRecorder.last?.done == Int64(payload.count))
                }
            },

            TestCase("uploading an empty file yields an empty file") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let empty = sandbox.appendingPathComponent("empty.bin")
                    try Data().write(to: empty)

                    let remotePath = sandbox.appendingPathComponent("empty-remote.bin").path
                    try await client.upload(localURL: empty, to: remotePath, progress: nil)

                    let entry = try require(try await client.attributes(of: remotePath))
                    try expect(entry.size == 0)
                }
            },

            TestCase("a failed download leaves no partial file behind") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let destination = sandbox.appendingPathComponent("should-not-exist.bin")
                    try await expectThrows {
                        try await client.download(
                            remotePath: sandbox.appendingPathComponent("absent.bin").path,
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

            TestCase("concurrent requests are routed to the right caller") {
                try await requireServer()
                // Stresses request-id routing and write serialisation: every task
                // must see its own empty directory, not another task's contents.
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let initial = try await client.list(sandbox.path)
                    try expect(initial.isEmpty)

                    try await withThrowingTaskGroup(of: Int.self) { group in
                        for _ in 0..<16 {
                            group.addTask { try await client.list(sandbox.path).count }
                        }
                        for try await count in group {
                            try expect(count == 0, "a concurrent listing saw \(count) entries")
                        }
                    }
                }
            },

            TestCase("readFile honours the caller's limit") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let payload = Data((0..<10_000).map { UInt8($0 % 256) })
                    let file = sandbox.appendingPathComponent("limited.bin")
                    try payload.write(to: file)

                    let data = try await client.readFile(file.path, limit: 1000)
                    try expect(data.count == 1000, "got \(data.count) bytes")
                    try expect(data == payload.prefix(1000))
                }
            },

            TestCase("disconnect can be called twice") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, _ in
                    await client.disconnect()
                    await client.disconnect()
                }
            },

            TestCase("actions on a disconnected client fail instead of hanging") {
                Bootstrap.configureProcess()
                let client = SFTPClient(endpoint: .localServer(executable: AppPaths.systemSFTPServer))
                try await expectThrows("operations must fail once disconnected") {
                    _ = try await client.list("/")
                }
            },

            TestCase("password auth without a password is rejected before launching ssh") {
                let profile = ConnectionProfile(host: "example.com", username: "user", authMethod: .password)
                let client = SFTPClient(displayName: "example.com")
                try await expectThrows("connecting without a password should fail") {
                    try await client.connect(profile: profile, credential: .none)
                }
            },
        ]
    }

    private static func requireServer() async throws {
        if !TestSupport.systemSFTPServerAvailable {
            try skip("no /usr/libexec/sftp-server on this machine")
        }
    }
}
