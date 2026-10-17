import Foundation
import SFTPsurfCore

/// A helper process whose stdout is drained in the background, so the child
/// never blocks on a full pipe while a test waits for something to happen.
final class SpawnedProcess: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdoutText = ""
    private var stderrText = ""
    private var exited = false
    private var readyLine: String?

    init(executable: URL, arguments: [String], environment: [String: String]? = nil) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let environment { process.environment = environment }

        process.terminationHandler = { [weak self] _ in
            self?.lock.lock()
            self?.exited = true
            self?.lock.unlock()
        }
    }

    func start() throws {
        try process.run()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.append(String(decoding: data, as: UTF8.self), to: &self.stdoutText, flag: &self.readyLine)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.stderrText += String(decoding: data, as: UTF8.self)
            self.lock.unlock()
        }
    }

    private func append(_ chunk: String, to text: inout String, flag: inout String?) {
        lock.lock()
        text += chunk
        if flag == nil, let range = text.range(of: "READY ") {
            flag = String(text[range.upperBound...].prefix { $0.isNumber })
        }
        lock.unlock()
    }

    /// Waits until the child prints its READY marker, or throws on timeout/exit.
    func waitForReady(timeout: TimeInterval = 20) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let ready = readyLine
            let died = exited
            let errors = stderrText
            lock.unlock()

            if let ready, let port = Int(ready) { return port }
            if died {
                throw CheckError(
                    message: "helper exited before signalling READY. stderr: \(errors)",
                    file: #fileID,
                    line: #line
                )
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock()
        let errors = stderrText
        lock.unlock()
        throw CheckError(
            message: "timed out waiting for helper to start. stderr: \(errors)",
            file: #fileID,
            line: #line
        )
    }

    var capturedStdErr: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrText
    }

    func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

/// Starts the bundled Python FTP server so the FTP client can be tested against
/// something that speaks the real protocol.
enum FTPServerFixture {
    /// A Python interpreter that can import pyftpdlib, if there is one.
    static func pythonExecutable() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["SFTPsurf_FTP_PYTHON"],
            repoRoot.appendingPathComponent(".venv-test/bin/python").path,
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if canImportPyftpdlib(using: candidate) { return candidate }
        }
        return nil
    }

    private static func canImportPyftpdlib(using python: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import pyftpdlib"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static var serverScript: URL {
        repoRoot.appendingPathComponent("Scripts/test-ftp-server.py")
    }

    /// The package root, derived from this file's compile-time path so the tests
    /// work no matter which directory they are launched from.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Sources/SelfTest/FTPFixtures.swift
            .deletingLastPathComponent()          // Sources/SelfTest
            .deletingLastPathComponent()          // Sources
            .deletingLastPathComponent()          // package root
    }

    enum Availability {
        case ready(python: String)
        case unavailable(reason: String)
    }

    static var availability: Availability {
        guard FileManager.default.isExecutableFile(atPath: serverScript.path) else {
            return .unavailable(reason: "Scripts/test-ftp-server.py is missing")
        }
        guard let python = pythonExecutable() else {
            return .unavailable(
                reason: "no Python with pyftpdlib (run Scripts/setup-test-deps.sh)"
            )
        }
        return .ready(python: python)
    }

    /// A running server plus everything needed to talk to it.
    struct RunningServer {
        let process: SpawnedProcess
        let profile: ConnectionProfile
        let root: URL

        func stop() {
            process.terminate()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Boots a server and hands back a handle. The caller must call `stop()`.
    static func startServer(enableMLSD: Bool = true) throws -> RunningServer {
        guard case .ready(let python) = availability else {
            throw SkipError(message: "FTP integration tests need pyftpdlib")
        }

        let root = try TestSupport.makeSandbox()
        var arguments = [serverScript.path, "--root", root.path, "--port", "0"]
        if !enableMLSD { arguments.append("--no-mlsd") }

        let server = try SpawnedProcess(
            executable: URL(fileURLWithPath: python),
            arguments: arguments
        )
        do {
            try server.start()
            let port = try server.waitForReady()
            let profile = ConnectionProfile(
                nickname: "local-ftp",
                kind: .ftp,
                host: "127.0.0.1",
                port: port,
                username: "tester",
                authMethod: .password,
                initialPath: "/"
            )
            return RunningServer(process: server, profile: profile, root: root)
        } catch {
            server.terminate()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Boots a server rooted at a fresh temporary directory and runs `body`
    /// against it, tearing everything down afterwards.
    static func withServer<T>(
        enableMLSD: Bool = true,
        _ body: (ConnectionProfile, URL) async throws -> T
    ) async throws -> T {
        let handle = try startServer(enableMLSD: enableMLSD)
        do {
            let result = try await body(handle.profile, handle.root)
            handle.stop()
            return result
        } catch {
            handle.stop()
            throw error
        }
    }

    /// Connects a client to a freshly booted server and runs `body`.
    static func withSession<T>(
        enableMLSD: Bool = true,
        _ body: (FTPClient, ConnectionProfile, URL) async throws -> T
    ) async throws -> T {
        try await withServer(enableMLSD: enableMLSD) { profile, root in
            let client = FTPClient(displayName: profile.host)
            do {
                try await client.connect(
                    profile: profile,
                    credential: Credential(password: "hunter2")
                )
                let result = try await body(client, profile, root)
                await client.disconnect()
                return result
            } catch {
                await client.disconnect()
                throw error
            }
        }
    }
}
