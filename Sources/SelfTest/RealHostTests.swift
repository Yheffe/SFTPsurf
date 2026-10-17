import Foundation
import SFTPsurfCore

/// Runs the SFTP client against a real server over real SSH.
///
/// The regular suite drives macOS's own `sftp-server` directly, which covers the
/// packet layer but not the `ssh` invocation, authentication, or a remote
/// server's quirks. This does the other half: a genuine SSH session.
///
/// The host comes from an existing bookmark plus its keychain password, so the
/// credential is read by the same code the UI uses and never appears on a
/// command line. Enable with:
///
///     SFTPsurf_REAL_HOST=<bookmark-uuid> Scripts/test.sh
enum RealHostFixture {
    /// Bookmark id to test against, if any.
    static var bookmarkID: String? {
        guard let value = ProcessInfo.processInfo.environment["SFTPsurf_REAL_HOST"],
              !value.isEmpty else { return nil }
        return value
    }

    static var isConfigured: Bool { bookmarkID != nil }

    struct Endpoint {
        let profile: ConnectionProfile
        let password: String?
    }

    /// Loads the bookmark and its stored secret.
    static func endpoint() throws -> Endpoint {
        guard let bookmarkID, let uuid = UUID(uuidString: bookmarkID) else {
            throw SkipError(message: "no SFTPsurf_REAL_HOST bookmark configured")
        }

        let store = BookmarkStore(fileURL: AppPaths.bookmarksFile)
        guard let profile = store.bookmark(id: uuid) else {
            throw SkipError(message: "no bookmark with id \(bookmarkID)")
        }

        return Endpoint(
            profile: profile,
            password: KeychainStore().password(for: uuid)
        )
    }
}

/// Exercises the operations the browser actually performs, against a real host.
///
/// Everything goes through `RemoteFileClient`, so it validates the whole stack:
/// ssh invocation, authentication, the packet layer, and remote semantics.
enum RealSFTPTests {
    static var cases: [TestCase] {
        [
            TestCase("host: connect and report the home directory") {
                try await withHost { client, _ in
                    let home = try await client.homePath()
                    try expect(home.hasPrefix("/"), "home should be absolute, got \(home)")
                }
            },

            TestCase("host: create a directory, upload, list, download, rename and delete") {
                try await withHost { client, sandbox in
                    let entries = try await client.list(sandbox)
                    try expect(entries.isEmpty, "a fresh directory should be empty, got \(entries.map(\.name))")

                    // Upload a payload that spans several packets.
                    let payload = Data((0..<(150 * 1024 + 321)).map { UInt8($0 % 251) })
                    let localSource = try TestSupport.makeSandbox().appendingPathComponent("payload.bin")
                    try payload.write(to: localSource)
                    defer { try? FileManager.default.removeItem(at: localSource.deletingLastPathComponent()) }

                    let remotePath = sandbox + "/payload.bin"
                    let uploadRecorder = TestSupport.ProgressRecorder()
                    try await client.upload(
                        localURL: localSource,
                        to: remotePath,
                        progress: { done, total in uploadRecorder.record(done: done, total: total) }
                    )

                    let stored = try require(
                        try await client.attributes(of: remotePath),
                        "the uploaded file should exist"
                    )
                    try expect(
                        stored.size == Int64(payload.count),
                        "server stored \(stored.size) bytes, expected \(payload.count)"
                    )
                    try expect(uploadRecorder.isEmpty == false, "upload reported no progress")

                    let listing = try await client.list(sandbox)
                    try expect(
                        listing.map(\.name) == ["payload.bin"],
                        "listing should show the upload, got \(listing.map(\.name))"
                    )

                    // Bring it back and compare byte for byte.
                    let destination = try TestSupport.makeSandbox()
                        .appendingPathComponent("payload.bin")
                    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

                    try await client.download(remotePath: remotePath, to: destination, progress: nil)
                    let roundTripped = try Data(contentsOf: destination)
                    try expect(
                        roundTripped == payload,
                        "downloaded \(roundTripped.count) bytes that differ from the source"
                    )

                    // Rename, then confirm the new name is what the server reports.
                    let renamed = sandbox + "/renamed.bin"
                    try await client.rename(remotePath, to: renamed)
                    let afterRename = try await client.list(sandbox)
                    try expect(afterRename.map(\.name) == ["renamed.bin"], "got \(afterRename.map(\.name))")

                    try await client.removeFile(renamed)
                    try expect(try await client.list(sandbox).isEmpty != false)
                }
            },

            TestCase("host: permissions round trip") {
                try await withHost { client, sandbox in
                    let file = sandbox + "/perms.txt"
                    try await client.upload(
                        localURL: try makeLocalFile(named: "perms.txt", contents: "x"),
                        to: file,
                        progress: nil
                    )

                    try await client.setPermissions(file, mode: 0o600)

                    let entry = try require(try await client.attributes(of: file))
                    let mode = try require(entry.permissions) & 0o777
                    try expect(mode == 0o600, "expected 0600, got \(String(mode, radix: 8))")
                }
            },

            TestCase("host: concurrent listings are routed correctly") {
                try await withHost { client, sandbox in
                    try await withThrowingTaskGroup(of: Int.self) { group in
                        for _ in 0..<8 {
                            group.addTask { try await client.list(sandbox).count }
                        }
                        for try await count in group {
                            try expect(count == 0, "a concurrent listing saw \(count) entries")
                        }
                    }
                }
            },

            TestCase("host: a missing path is reported, not hung") {
                try await withHost { client, sandbox in
                    try await expectThrows("listing a missing directory must throw") {
                        _ = try await client.list(sandbox + "/definitely-absent")
                    }
                    let missing = try await client.attributes(of: sandbox + "/definitely-absent")
                    try expect(missing == nil)
                }
            },

            TestCase("host: wrong password fails with an authentication error") {
                guard RealHostFixture.isConfigured else {
                    try skip("no SFTPsurf_REAL_HOST bookmark configured")
                }
                let endpoint = try RealHostFixture.endpoint()
                var profile = endpoint.profile
                profile.authMethod = .password

                let client = SFTPClient(displayName: profile.host)
                do {
                    try await client.connect(
                        profile: profile,
                        credential: Credential(password: "definitely-not-the-password")
                    )
                    await client.disconnect()
                    throw CheckError(
                        message: "connecting with a bad password should have failed",
                        file: #fileID,
                        line: #line
                    )
                } catch let error as RemoteClientError {
                    guard case .authenticationFailed = error else {
                        throw CheckError(
                            message: "expected authenticationFailed, got \(error)",
                            file: #fileID,
                            line: #line
                        )
                    }
                    await client.disconnect()
                }
            },
        ]
    }

    // MARK: - Session helper

    /// Connects to the configured host, gives the test a scratch directory on it,
    /// and removes that directory afterwards.
    private static func withHost<T>(
        _ body: (SFTPClient, String) async throws -> T
    ) async throws -> T {
        guard RealHostFixture.isConfigured else {
            try skip("set SFTPsurf_REAL_HOST=<bookmark-uuid> to run host tests")
        }
        let endpoint = try RealHostFixture.endpoint()

        Bootstrap.configureProcess()
        let client = SFTPClient(displayName: endpoint.profile.host)
        do {
            try await client.connect(profile: endpoint.profile, credential: Credential(password: endpoint.password))

            // A uniquely named scratch directory beside the home directory.
            let home = try await client.homePath()
            let sandbox = RemotePath.join(home, "sftpsurf-selftest-\(UUID().uuidString)")
            try await client.createDirectory(sandbox)

            do {
                let result = try await body(client, sandbox)
                await removeTree(client: client, path: sandbox)
                await client.disconnect()
                return result
            } catch {
                await removeTree(client: client, path: sandbox)
                await client.disconnect()
                throw error
            }
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// Removes a directory and everything in it, ignoring failures.
    private static func removeTree(client: SFTPClient, path: String) async {
        guard let children = try? await client.list(path) else {
            _ = try? await client.removeDirectory(path)
            return
        }
        for child in children {
            if child.isDirectory {
                await removeTree(client: client, path: child.path)
            } else {
                _ = try? await client.removeFile(child.path)
            }
        }
        _ = try? await client.removeDirectory(path)
    }

    private static func makeLocalFile(named name: String, contents: String) throws -> URL {
        let directory = try TestSupport.makeSandbox()
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
