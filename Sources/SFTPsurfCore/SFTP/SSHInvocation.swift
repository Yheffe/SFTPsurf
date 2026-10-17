import Foundation

/// The executable, arguments and environment for a helper process.
public struct ProcessSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]?
    /// Files created to support this launch, removed once it has been started.
    public var cleanup: [URL]

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        cleanup: [URL] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cleanup = cleanup
    }
}

/// Handles `SSH_ASKPASS` so password authentication works even though we launch
/// `ssh` without a terminal.
///
/// `ssh` refuses to read a password from stdin, so the only supported way to
/// supply one non-interactively is an askpass helper. The secret is written to a
/// `0600` file inside a `0700` directory, read by a tiny shell script, and the
/// directory is deleted as soon as the connection attempt is underway.
struct AskPassSession {
    let directory: URL
    let script: URL

    /// Returns nil when there is no secret to provide.
    init?(secret: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftpsurf-askpass-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let secretFile = directory.appendingPathComponent("secret")
            try Data(secret.utf8).write(to: secretFile, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFile.path)

            let script = directory.appendingPathComponent("askpass.sh")
            let body = """
            #!/bin/sh
            # Emits the stored secret for whatever prompt ssh is showing.
            exec cat "$(dirname "$0")/secret"
            """
            try Data(body.utf8).write(to: script, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

            self.directory = directory
            self.script = script
        } catch {
            return nil
        }
    }

    /// Environment variables that make ssh consult our helper.
    var environment: [String: String] {
        [
            "SSH_ASKPASS": script.path,
            "SSH_ASKPASS_REQUIRE": "force",
            // Some ssh builds only honour askpass when they believe a display exists.
            "DISPLAY": ":0",
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum SSHInvocation {
    /// Builds the argv for `ssh … -s host sftp`.
    static func spec(for profile: ConnectionProfile, credential: Credential) throws -> ProcessSpec {
        var arguments: [String] = []

        // Keep the connection responsive during long, quiet transfers.
        arguments += ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]
        arguments += ["-o", "ConnectTimeout=20"]
        // We hand ssh our own known-hosts file so first contact is trust-on-first-use
        // while a *changed* key is still a hard failure.
        arguments += ["-o", "UserKnownHostsFile=\(KnownHostsManager.shared.fileURL.path)"]
        arguments += ["-o", "StrictHostKeyChecking=accept-new"]
        arguments += ["-o", "LogLevel=ERROR"]
        arguments += ["-o", "RequestTTY=no"]
        arguments += ["-o", "NumberOfPasswordPrompts=1"]

        switch profile.authMethod {
        case .password:
            guard credential.password?.isEmpty == false else {
                throw RemoteClientError.authenticationFailed("No password was provided.")
            }
            // Skip pointless public-key probing; servers that want
            // keyboard-interactive still get it.
            arguments += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
            arguments += ["-o", "PubkeyAuthentication=no"]
        case .privateKey(let path):
            arguments += ["-i", (path as NSString).expandingTildeInPath]
            arguments += ["-o", "PreferredAuthentications=publickey,keyboard-interactive,password"]
        case .agentAndDefaults:
            arguments += ["-o", "PreferredAuthentications=publickey,keyboard-interactive,password"]
        }

        if let jump = profile.proxyJump, !jump.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["-J", jump.trimmingCharacters(in: .whitespaces)]
        }

        if profile.effectivePort != profile.kind.defaultPort {
            arguments += ["-p", String(profile.effectivePort)]
        }

        arguments += profile.sshOptions.filter { !$0.isEmpty }

        let destination = profile.username.isEmpty
            ? profile.host
            : "\(profile.username)@\(profile.host)"
        arguments += ["-s", destination, "sftp"]

        var environment = ProcessInfo.processInfo.environment
        var cleanup: [URL] = []

        // A passphrase doubles as the askpass secret for encrypted keys.
        let secret = credential.password ?? credential.passphrase
        if let secret, let session = AskPassSession(secret: secret) {
            environment.merge(session.environment) { _, new in new }
            cleanup.append(session.directory)
        }

        return ProcessSpec(
            executable: AppPaths.sshExecutable,
            arguments: arguments,
            environment: environment,
            cleanup: cleanup
        )
    }

    /// Spec for running a local `sftp-server` binary, used by the test suite.
    static func localServerSpec(executable: URL = AppPaths.systemSFTPServer) -> ProcessSpec {
        ProcessSpec(executable: executable, arguments: ["-e"])
    }

    /// Translates ssh's stderr into an error the UI can present usefully.
    static func error(fromStderr text: String, fallback: Error) -> Error {
        let stderr = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stderr.isEmpty else { return fallback }

        // ssh can be chatty; the last meaningful line is usually the real cause.
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let summary = lines.last(where: { !$0.isEmpty }) ?? stderr
        let lowered = stderr.lowercased()

        if lowered.contains("permission denied") || lowered.contains("authentication failed") {
            return RemoteClientError.authenticationFailed(summary)
        }
        if lowered.contains("host key verification failed")
            || lowered.contains("remote host identification has changed")
            || lowered.contains("no matching host key") {
            return RemoteClientError.hostKeyRejected(summary)
        }
        if lowered.contains("connection refused") {
            return RemoteClientError.connectionRefused(summary)
        }
        if lowered.contains("could not resolve hostname")
            || lowered.contains("nodename nor servname") {
            return RemoteClientError.hostNotFound(summary)
        }
        if lowered.contains("operation timed out") || lowered.contains("connection timed out")
            || lowered.contains("connection closed by") {
            return RemoteClientError.timedOut(summary)
        }
        return RemoteClientError.transport(summary)
    }
}

/// Owns SFTPsurf's known-hosts file so host keys are pinned separately from the
/// user's own `~/.ssh/known_hosts`.
final class KnownHostsManager: @unchecked Sendable {
    static let shared = KnownHostsManager()

    private let lock = NSLock()
    private var seeded = false

    var fileURL: URL { AppPaths.knownHostsFile }

    /// Makes sure the file exists and has picked up the user's existing trust
    /// anchors, so servers they already connect to do not re-prompt.
    func prepare() {
        lock.lock()
        defer { lock.unlock() }
        guard !seeded else { return }
        seeded = true

        let fileManager = FileManager.default
        let destination = fileURL

        if !fileManager.fileExists(atPath: destination.path) {
            var contents = Data()
            let userFile = AppPaths.userKnownHostsFile
            if let existing = try? Data(contentsOf: userFile) {
                contents = existing
            }
            fileManager.createFile(
                atPath: destination.path,
                contents: contents,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
