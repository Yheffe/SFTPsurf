import Foundation
import SFTPsurfCore

/// Thin wrappers that make the suite read clearly.
enum TestSupport {
    /// macOS ships the real server; driving the subsystem directly exercises the
    /// full packet layer without needing a live sshd.
    static var systemSFTPServerAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: AppPaths.systemSFTPServer.path)
    }

    static func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftpsurf-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs `body` against a freshly connected local SFTP session and always
    /// tears the session and sandbox down again.
    static func withLocalSFTPSession<T>(
        _ body: (SFTPClient, URL) async throws -> T
    ) async throws -> T {
        Bootstrap.configureProcess()
        let sandbox = try makeSandbox()
        let client = SFTPClient(endpoint: .localServer(executable: AppPaths.systemSFTPServer))

        do {
            try await client.connect(
                profile: ConnectionProfile(nickname: "local", host: "localhost"),
                credential: .none
            )
            let result = try await body(client, sandbox)
            await client.disconnect()
            try? FileManager.default.removeItem(at: sandbox)
            return result
        } catch {
            await client.disconnect()
            try? FileManager.default.removeItem(at: sandbox)
            throw error
        }
    }

    /// Records progress callbacks, which arrive from arbitrary threads.
    final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [(done: Int64, total: Int64)] = []

        func record(done: Int64, total: Int64) {
            lock.lock()
            samples.append((done, total))
            lock.unlock()
        }

        var last: (done: Int64, total: Int64)? {
            lock.lock()
            defer { lock.unlock() }
            return samples.last
        }

        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return samples.isEmpty
        }
    }
}
