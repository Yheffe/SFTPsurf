import Foundation

/// An FTP session built directly on the control connection, so transfers get
/// real progress reporting rather than a black box.
///
/// Notes on compatibility:
/// * Extended passive mode (`EPSV`) is preferred and falls back to `PASV`.
/// * `MLSD` is preferred for listings and falls back to parsing `LIST`.
/// * The address a `PASV` reply advertises is ignored in favour of the control
///   connection's own peer address, which is what makes this work behind NAT.
public actor FTPClient: RemoteFileClient {
    private var control: SocketTransport?
    private var features: Set<String> = []
    private var supportsMLSD = false
    private var supportsEPSV = false
    private var supportsSIZE = false
    private var supportsMDTM = false
    private var passiveMode = true
    private var currentDirectory = "/"
    private var binaryMode = false
    private let displayName: String

    /// Everything in FTP shares one control connection: a data transfer and any
    /// other command (including a second transfer) cannot overlap, or `PASV`
    /// replies and completion codes get crossed. This hands out exclusive use.
    private var sessionBusy = false
    private var sessionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Takes exclusive use of the control connection.
    private func acquireSession() async {
        if !sessionBusy {
            sessionBusy = true
            return
        }
        // Ownership is handed over by `releaseSession` when it resumes this.
        await withCheckedContinuation { sessionWaiters.append($0) }
    }

    private func releaseSession() {
        if sessionWaiters.isEmpty {
            sessionBusy = false
        } else {
            // Pass the baton: `sessionBusy` stays true for the next waiter.
            sessionWaiters.removeFirst().resume()
        }
    }

    public init(displayName: String = "FTP") {
        self.displayName = displayName
    }

    // MARK: - Connecting

    public func connect(profile: ConnectionProfile, credential: Credential) async throws {
        if control != nil { await disconnect() }

        guard !profile.host.isEmpty else {
            throw RemoteClientError.hostNotFound("(empty host)")
        }
        guard let password = credential.password else {
            throw RemoteClientError.authenticationFailed("No password was provided.")
        }

        passiveMode = profile.ftpPassive

        let socket = try SocketTransport.connect(
            host: profile.host,
            port: profile.effectivePort,
            timeout: 30
        )
        control = socket

        do {
            let greeting = try await readReply()
            guard greeting.code == 220 || greeting.isPositive else {
                throw greeting.failure("connecting")
            }

            try await login(profile: profile, password: password)
            try await loadFeatures()
            if profile.ftpUTF8, features.contains("UTF8") {
                // Best effort: servers that advertise UTF8 usually accept this.
                _ = try? await send("OPTS UTF8 ON")
            }
            try await enterBinaryMode()
            currentDirectory = try await printWorkingDirectory()
        } catch {
            await disconnect()
            if let error = error as? RemoteClientError { throw error }
            throw RemoteClientError.transport(error.localizedDescription)
        }
    }

    private func login(profile: ConnectionProfile, password: String) async throws {
        let user = profile.username.isEmpty ? "anonymous" : profile.username
        let userReply = try await send("USER \(user)")

        switch userReply.code {
        case 230:
            return // Already logged in, e.g. anonymous access.
        case 331, 332:
            let passwordReply = try await send("PASS \(password)")
            guard passwordReply.code == 230 || passwordReply.code == 202 else {
                throw RemoteClientError.authenticationFailed(passwordReply.detail)
            }
        default:
            throw RemoteClientError.authenticationFailed(userReply.detail)
        }
    }

    /// `FEAT` is optional; servers that do not implement it just send 500.
    private func loadFeatures() async throws {
        let reply = try await send("FEAT")
        guard reply.isPositive else { return }

        for line in reply.lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, Int(trimmed.prefix(3)) == nil else { continue }
            let name = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
            features.insert(name.uppercased())
        }

        supportsMLSD = features.contains("MLSD")
        supportsEPSV = features.contains("EPSV")
        supportsSIZE = features.contains("SIZE")
        supportsMDTM = features.contains("MDTM")
    }

    private func enterBinaryMode() async throws {
        guard !binaryMode else { return }
        let reply = try await send("TYPE I")
        guard reply.isPositive else { throw reply.failure("switching to binary mode") }
        binaryMode = true
    }

    public func homePath() async throws -> String {
        if let path = try? await printWorkingDirectory() { return path }
        return currentDirectory
    }

    private func printWorkingDirectory() async throws -> String {
        let reply = try await send("PWD")
        guard reply.isPositive, let path = FTPClient.parseQuotedPath(reply.detail) else {
            return currentDirectory
        }
        currentDirectory = path
        return path
    }

    /// `PWD` answers with `"…"` when the server supports RFC 959 quoting, and
    /// with a bare path otherwise.
    public static func parseQuotedPath(_ text: String) -> String? {
        guard let first = text.firstIndex(of: "\"") else {
            let bare = text.trimmingCharacters(in: .whitespaces)
            return bare.hasPrefix("/") ? bare : nil
        }
        guard let last = text.lastIndex(of: "\""), last > first else { return nil }
        let path = String(text[text.index(after: first)..<last])
        return path.isEmpty ? "/" : path
    }

    // MARK: - Control channel

    /// Sends one command and reads its reply, with the session held throughout.
    @discardableResult
    private func send(_ command: String) async throws -> FTPReply {
        await acquireSession()
        defer { releaseSession() }
        return try await sendLocked(command)
    }

    /// For use by callers that already hold the session (a data transfer).
    @discardableResult
    private func sendLocked(_ command: String) async throws -> FTPReply {
        guard let control else { throw RemoteClientError.notConnected }
        // Commands may carry a password, so they are never logged.
        try await control.write(Data((command + "\r\n").utf8))
        return try await readReplyLocked()
    }

    private func readReply() async throws -> FTPReply {
        await acquireSession()
        defer { releaseSession() }
        return try await readReplyLocked()
    }

    private func readReplyLocked() async throws -> FTPReply {
        guard let control else { throw RemoteClientError.notConnected }
        return try await FTPReplyParser.readReply(from: control)
    }

    // MARK: - Data connections

    /// Opens the data socket before the command that uses it, as passive mode requires.
    private func openDataConnection() async throws -> SocketTransport {
        guard let control else { throw RemoteClientError.notConnected }

        if supportsEPSV || !passiveMode {
            if let port = try? await requestExtendedPassivePort(), let host = control.peerHost {
                return try SocketTransport.connect(host: host, port: port, timeout: 30)
            }
        }

        let (host, port) = try await requestPassivePort()
        // Prefer the address we already trust over whatever the server advertises.
        let targetHost = control.peerHost ?? host
        return try SocketTransport.connect(host: targetHost, port: port, timeout: 30)
    }

    private func requestExtendedPassivePort() async throws -> Int? {
        let reply = try await sendLocked("EPSV")
        guard reply.code == 229 else { return nil }
        // Format: 229 Entering Extended Passive Mode (|||6446|)
        guard let open = reply.detail.firstIndex(of: "("),
              let close = reply.detail[open...].firstIndex(of: ")") else { return nil }
        let body = reply.detail[reply.detail.index(after: open)..<close]
        let delimiter = body.first ?? "|"
        let portText = body.split(separator: delimiter).last.map(String.init)
        guard let portText, let port = Int(portText), port > 0 else { return nil }
        return port
    }

    private func requestPassivePort() async throws -> (String, Int) {
        let reply = try await sendLocked("PASV")
        guard reply.code == 227 else { throw reply.failure("opening a data connection") }
        guard let open = reply.detail.firstIndex(of: "("),
              let close = reply.detail[open...].firstIndex(of: ")") else {
            throw RemoteClientError.server("Malformed PASV reply: \(reply.detail)")
        }
        let numbers = reply.detail[reply.detail.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else {
            throw RemoteClientError.server("Malformed PASV reply: \(reply.detail)")
        }
        let host = numbers[0...3].map(String.init).joined(separator: ".")
        let port = numbers[4] * 256 + numbers[5]
        guard port > 0 else {
            throw RemoteClientError.server("PASV reply contained no usable port.")
        }
        return (host, port)
    }

    /// Sends a command that streams over a data connection, hands the socket to
    /// `body`, then waits for the server's completion reply.
    private func withDataConnection<T>(
        command: String,
        tolerateIncompleteTransfer: Bool = false,
        _ body: (SocketTransport) async throws -> T
    ) async throws -> T {
        // One transfer at a time, end to end.
        await acquireSession()
        defer { releaseSession() }

        let data = try await openDataConnection()

        let preliminary: FTPReply
        do {
            preliminary = try await sendLocked(command)
        } catch {
            data.close()
            throw error
        }

        guard preliminary.isPositive || preliminary.isPreliminary else {
            data.close()
            throw preliminary.failure(command)
        }

        let result: T
        do {
            result = try await body(data)
        } catch {
            data.close()
            throw error
        }

        data.close()
        // The transfer is only trustworthy once the server confirms it.
        let completion = try await readReplyLocked()
        if !tolerateIncompleteTransfer,
           completion.code == 426 || completion.code == 451 || completion.code == 550 {
            throw completion.failure(command)
        }
        return result
    }

    private func collectListLines(command: String) async throws -> [String] {
        try await withDataConnection(command: command) { socket in
            var text = ""
            while let chunk = try await socket.readSomeOrEOF(maxLength: 64 * 1024) {
                guard !chunk.isEmpty else { break }
                text += String(decoding: chunk, as: UTF8.self)
            }
            return text.split(whereSeparator: \.isNewline).map(String.init)
        }
    }

    // MARK: - Listing

    public func list(_ path: String) async throws -> [RemoteEntry] {
        let directory = RemotePath.normalize(path)
        var argumentFailure: Error?

        do {
            return try await listDirectory(directory, viaArgument: true)
        } catch {
            argumentFailure = error
        }

        // Not every server accepts a path argument, so retry after changing into
        // the directory. The previous directory is restored either way.
        guard directory != currentDirectory else {
            throw argumentFailure ?? RemoteClientError.unsupported("directory listings")
        }

        let previous = currentDirectory
        let change = try await send("CWD \(directory)")
        guard change.isPositive else {
            throw argumentFailure ?? change.failure("changing directory", path: directory)
        }
        currentDirectory = directory

        do {
            let entries = try await listDirectory(directory, viaArgument: false)
            _ = try? await send("CWD \(previous)")
            currentDirectory = previous
            return entries
        } catch {
            _ = try? await send("CWD \(previous)")
            currentDirectory = previous
            throw error
        }
    }

    /// Tries MLSD first (structured facts) and LIST second (universally present).
    private func listDirectory(_ directory: String, viaArgument: Bool) async throws -> [RemoteEntry] {
        var lastError: Error?

        if supportsMLSD {
            do {
                let command = viaArgument ? "MLSD \(directory)" : "MLSD"
                return try parseListing(try await collectListLines(command: command), parent: directory, isMLSD: true)
            } catch {
                lastError = error
            }
        }

        do {
            let command = viaArgument ? "LIST \(directory)" : "LIST"
            return try parseListing(try await collectListLines(command: command), parent: directory, isMLSD: false)
        } catch {
            lastError = error
        }

        throw lastError ?? RemoteClientError.unsupported("directory listings")
    }

    private func parseListing(_ lines: [String], parent: String, isMLSD: Bool) throws -> [RemoteEntry] {
        let entries = lines.compactMap { line -> RemoteEntry? in
            isMLSD
                ? FTPListingParser.parseMLSD(line, parent: parent)
                : FTPListingParser.parseUnix(line, parent: parent)
        }
        // Output that yields nothing means we do not understand this server's
        // format; say so rather than pretending the directory is empty.
        if entries.isEmpty && !lines.isEmpty {
            throw RemoteClientError.server("Unrecognised \(isMLSD ? "MLSD" : "LIST") listing.")
        }
        return entries.sorted(by: RemoteEntry.sortByName)
    }

    public func attributes(of path: String) async throws -> RemoteEntry? {
        let normalized = RemotePath.normalize(path)
        guard let parent = RemotePath.parent(of: normalized) else {
            return RemoteEntry(name: "/", path: "/", isDirectory: true, permissions: 0o040755)
        }
        let name = RemotePath.lastComponent(of: normalized)
        let entries = try await list(parent)
        return entries.first { $0.name == name }
    }

    // MARK: - Mutations

    public func createDirectory(_ path: String) async throws {
        let reply = try await send("MKD \(path)")
        guard reply.isPositive else { throw reply.failure("creating a directory", path: path) }
    }

    public func removeFile(_ path: String) async throws {
        let reply = try await send("DELE \(path)")
        guard reply.isPositive else { throw reply.failure("deleting a file", path: path) }
    }

    public func removeDirectory(_ path: String) async throws {
        let reply = try await send("RMD \(path)")
        guard reply.isPositive else { throw reply.failure("removing a directory", path: path) }
    }

    public func rename(_ from: String, to: String) async throws {
        let source = try await send("RNFR \(from)")
        guard source.code == 350 || source.isPositive else {
            throw source.failure("renaming", path: from)
        }
        let destination = try await send("RNTO \(to)")
        guard destination.isPositive else { throw destination.failure("renaming", path: to) }
    }

    public func setPermissions(_ path: String, mode: UInt32) async throws {
        let reply = try await send("SITE CHMOD \(String(mode, radix: 8)) \(path)")
        guard reply.isPositive else {
            throw RemoteClientError.unsupported("changing permissions (SITE CHMOD)")
        }
    }

    // MARK: - Files

    public func readFile(_ path: String, limit: Int) async throws -> Data {
        // Stopping mid-stream makes the server report a failed transfer, which is
        // expected here because we deliberately asked for a prefix.
        try await withDataConnection(command: "RETR \(path)", tolerateIncompleteTransfer: true) { socket in
            var collected = Data()
            while collected.count < limit,
                  let chunk = try await socket.readSomeOrEOF(maxLength: min(64 * 1024, limit)) {
                guard !chunk.isEmpty else { break }
                collected.append(chunk)
                if collected.count >= limit { break }
            }
            return Data(collected.prefix(limit))
        }
    }

    public func download(
        remotePath: String,
        to localURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        let entry = try await attributes(of: remotePath)
        let total = entry?.size ?? 0

        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: localURL.path, contents: nil),
              let output = FileHandle(forWritingAtPath: localURL.path) else {
            throw RemoteClientError.transport("Could not create “\(localURL.lastPathComponent)”.")
        }

        var throttle = ProgressThrottle()
        progress?(0, total)
        var written: Int64 = 0

        do {
            try await withDataConnection(command: "RETR \(remotePath)") { socket in
                while let chunk = try await socket.readSomeOrEOF(maxLength: 128 * 1024) {
                    guard !chunk.isEmpty else { break }
                    try output.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    if throttle.shouldEmit() { progress?(written, total) }
                }
            }
            try? output.close()
            progress?(written, max(total, written))
        } catch {
            try? output.close()
            // Never leave a truncated file looking like a successful download.
            try? fileManager.removeItem(at: localURL)
            throw error
        }
    }

    public func upload(
        localURL: URL,
        to remotePath: String,
        progress: TransferProgressHandler?
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        guard let input = FileHandle(forReadingAtPath: localURL.path) else {
            throw RemoteClientError.transport("Could not read “\(localURL.lastPathComponent)”.")
        }

        var throttle = ProgressThrottle()
        progress?(0, total)
        var sent: Int64 = 0

        do {
            try await withDataConnection(command: "STOR \(remotePath)") { socket in
                while true {
                    try Task.checkCancellation()
                    let chunk = try input.read(upToCount: 128 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    try await socket.write(chunk)
                    sent += Int64(chunk.count)
                    if throttle.shouldEmit(force: sent >= total) { progress?(sent, total) }
                }
            }
            try? input.close()
            progress?(sent, total)
        } catch {
            try? input.close()
            throw error
        }
    }

    // MARK: - Teardown

    public func disconnect() async {
        if let control {
            // Best effort: the server may already be gone.
            try? await control.write(Data("QUIT\r\n".utf8))
            control.close()
        }
        control = nil
        features.removeAll()
        supportsMLSD = false
        supportsEPSV = false
        supportsSIZE = false
        supportsMDTM = false
        binaryMode = false
        currentDirectory = "/"
    }

    /// Exposed for tests and diagnostics.
    public var isConnected: Bool { control?.isClosed == false }
}
