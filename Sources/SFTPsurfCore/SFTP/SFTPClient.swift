import Foundation

/// Rate-limits progress callbacks so a fast transfer doesn't flood the UI.
struct ProgressThrottle {
    private var lastEmit = Date.distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.08) {
        self.interval = interval
    }

    mutating func shouldEmit(force: Bool = false) -> Bool {
        if force {
            lastEmit = Date()
            return true
        }
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= interval else { return false }
        lastEmit = now
        return true
    }
}

/// An SFTP session speaking protocol version 3 over a byte stream.
///
/// Requests are routed by id so several can be outstanding at once, which is
/// what makes transfers fast on links with any meaningful round-trip time.
public actor SFTPClient: RemoteFileClient {
    public enum Endpoint: Sendable {
        /// Launch `/usr/bin/ssh` and ask for the `sftp` subsystem.
        case systemSSH
        /// Run a local `sftp-server` binary directly. Used by the test suite.
        case localServer(executable: URL)
    }

    private let endpoint: Endpoint
    private let displayName: String

    private var stream: ByteStream?
    private var processTransport: ProcessTransport?
    private var ownedTransports: [ProcessTransport] = []

    private var nextRequestID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    /// Responses that arrived before their waiter registered.
    private var earlyResponses: [UInt32: SFTPResponse] = [:]
    private var readerTask: Task<Void, Never>?

    private var closed = false
    private var serverVersion: UInt32 = 3
    private var home = "/"

    /// Number of request/response pairs kept in flight during a transfer.
    private let pipelineWindow = 32
    /// Upper bound on a single SFTP data packet, from the v3 specification.
    private let maxPacketSize = 32 * 1024

    public init(endpoint: Endpoint = .systemSSH, displayName: String = "SFTP") {
        self.endpoint = endpoint
        self.displayName = displayName
    }

    // MARK: - Connecting

    public func connect(profile: ConnectionProfile, credential: Credential) async throws {
        if stream != nil { await disconnect() }

        let spec: ProcessSpec
        switch endpoint {
        case .systemSSH:
            // Only the real ssh path needs our known-hosts file.
            KnownHostsManager.shared.prepare()
            spec = try SSHInvocation.spec(for: profile, credential: credential)
        case .localServer(let executable):
            spec = SSHInvocation.localServerSpec(executable: executable)
        }

        let transport = ProcessTransport(
            executable: spec.executable,
            arguments: spec.arguments,
            environment: spec.environment
        )

        // Anything ssh needs on disk (the askpass helper) is only read during
        // authentication, which is done by the time the handshake returns.
        defer {
            for url in spec.cleanup { try? FileManager.default.removeItem(at: url) }
        }

        do {
            try transport.start()
        } catch {
            throw error
        }

        processTransport = transport
        ownedTransports.append(transport)
        stream = transport
        closed = false

        do {
            try await handshake()
        } catch {
            // ssh reports the real reason (bad password, unknown host key, …) on
            // stderr, but stdout can close first. Wait for that message before
            // deciding what went wrong, otherwise every failure looks like an
            // unexplained disconnect.
            let stderr = transport.waitForStandardError(timeout: 3)
            let mapped = SSHInvocation.error(fromStderr: stderr, fallback: error)
            await disconnect()
            throw mapped
        }
    }

    /// Sends `SSH_FXP_INIT` and reads the server's version reply.
    private func handshake() async throws {
        guard let stream else { throw RemoteClientError.notConnected }

        var writer = SFTPWriter()
        writer.beginPacket()
        writer.writeByte(SFTPPacketType.initialize.rawValue)
        writer.writeUInt32(3) // highest version we speak
        try await stream.write(writer.finish())

        let packet = try await readPacket(from: stream)
        guard packet.type == SFTPPacketType.version.rawValue else {
            throw SFTPError.unexpectedResponse("expected VERSION, got type \(packet.type)")
        }
        var reader = SFTPReader(packet.payload)
        let version = try reader.readUInt32()
        guard version >= 3 else { throw SFTPError.protocolMismatch(version) }
        serverVersion = version

        // Servers advertise extension name/value pairs; none are required here,
        // so a malformed pair just ends the list.
        while reader.remaining > 0 {
            guard (try? reader.readString()) != nil, (try? reader.readString()) != nil else { break }
        }

        startReadLoop()
        home = (try? await resolveRealPath(".")) ?? "/"
    }

    public func homePath() async throws -> String {
        let resolved = try? await resolveRealPath(".")
        return resolved ?? home
    }

    // MARK: - Packet plumbing

    private struct Packet {
        let type: UInt8
        let payload: Data
    }

    private func readPacket(from stream: ByteStream) async throws -> Packet {
        let header = [UInt8](try await stream.readExactly(4))
        let length = UInt32(header[0]) << 24 | UInt32(header[1]) << 16
            | UInt32(header[2]) << 8 | UInt32(header[3])
        guard length >= 1 else { throw SFTPError.malformedPacket("zero-length packet") }
        // A well-behaved server never sends anything close to this; a huge value
        // means we have lost framing.
        guard length <= 64 * 1024 * 1024 else {
            throw SFTPError.malformedPacket("packet length \(length) is implausible")
        }
        let body = try await stream.readExactly(Int(length))
        return Packet(type: body[body.startIndex], payload: body.dropFirst())
    }

    private func startReadLoop() {
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let stream = await self.currentStream() else { return }
                do {
                    let packet = try await self.readPacket(from: stream)
                    await self.route(packet)
                } catch {
                    await self.failEverything(error)
                    return
                }
            }
        }
    }

    private func currentStream() -> ByteStream? { stream }

    private func route(_ packet: Packet) async {
        var reader = SFTPReader(packet.payload)
        guard let id = try? reader.readUInt32() else {
            failEverything(SFTPError.malformedPacket("response without an id"))
            return
        }

        let response: SFTPResponse
        do {
            response = try SFTPClient.decode(type: packet.type, reader: &reader)
        } catch {
            failEverything(error)
            return
        }

        if let waiter = pending.removeValue(forKey: id) {
            waiter.resume(returning: response)
        } else {
            earlyResponses[id] = response
        }
    }

    private static func decode(type: UInt8, reader: inout SFTPReader) throws -> SFTPResponse {
        switch type {
        case SFTPPacketType.status.rawValue:
            let code = try reader.readUInt32()
            let message = (try? reader.readText()) ?? ""
            return .status(code, message)
        case SFTPPacketType.handle.rawValue:
            return .handle(try reader.readString())
        case SFTPPacketType.data.rawValue:
            return .data(try reader.readString())
        case SFTPPacketType.name.rawValue:
            let count = try reader.readUInt32()
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                let filename = try reader.readText()
                let longName = (try? reader.readText()) ?? ""
                let attributes = try reader.readAttributes()
                entries.append(SFTPNameEntry(filename: filename, longName: longName, attributes: attributes))
            }
            return .name(entries)
        case SFTPPacketType.attributes.rawValue:
            return .attributes(try reader.readAttributes())
        default:
            throw SFTPError.unexpectedResponse("unknown packet type \(type)")
        }
    }

    private func failEverything(_ error: Error) {
        let waiters = pending
        pending.removeAll()
        for (_, waiter) in waiters { waiter.resume(throwing: error) }
        stream?.close()
    }

    private func failRequest(id: UInt32, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Reserves an id, builds the packet, and returns both.
    private func buildPacket(_ body: (inout SFTPWriter, UInt32) -> Void) -> (id: UInt32, data: Data) {
        let id = nextRequestID
        nextRequestID &+= 1
        var writer = SFTPWriter()
        writer.beginPacket()
        body(&writer, id)
        return (id, writer.finish())
    }

    private func reserveID() -> UInt32 {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    private func awaitResponse(id: UInt32) async throws -> SFTPResponse {
        if let ready = earlyResponses.removeValue(forKey: id) { return ready }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    private func send(_ packet: Data) async throws {
        guard let stream else { throw RemoteClientError.notConnected }
        try await stream.write(packet)
    }

    /// Sends a request and waits for its reply, mapping STATUS failures to errors.
    @discardableResult
    private func perform(
        path: String? = nil,
        _ body: (inout SFTPWriter, UInt32) -> Void
    ) async throws -> SFTPResponse {
        let (id, packet) = buildPacket(body)
        do {
            try await send(packet)
        } catch {
            failRequest(id: id, error: error)
            throw error
        }
        let response = try await awaitResponse(id: id)
        if case .status(let code, let message) = response,
           let error = SFTPResponse.error(fromStatus: code, message: message, path: path) {
            throw error
        }
        return response
    }

    // MARK: - Directory listing

    public func list(_ path: String) async throws -> [RemoteEntry] {
        let directory = RemotePath.normalize(path)
        let handle = try await openDirectoryHandle(directory)

        var entries: [RemoteEntry] = []
        do {
            while true {
                let response = try await perform(path: directory) { writer, id in
                    writer.writeByte(SFTPPacketType.readdir.rawValue)
                    writer.writeUInt32(id)
                    writer.writeString(handle)
                }

                switch response {
                case .status(let code, _):
                    if code == SFTPStatusCode.eof.rawValue {
                        try await closeHandle(handle)
                        return entries.sorted(by: RemoteEntry.sortByName)
                    }
                    // Any other status was already thrown by `perform`.
                    try await closeHandle(handle)
                    return entries.sorted(by: RemoteEntry.sortByName)
                case .name(let names):
                    for name in names where name.filename != "." && name.filename != ".." {
                        entries.append(makeEntry(name: name, parent: directory))
                    }
                default:
                    throw SFTPError.unexpectedResponse("expected NAME or STATUS while listing \(directory)")
                }
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
    }

    private func makeEntry(name: SFTPNameEntry, parent: String) -> RemoteEntry {
        let mode = name.attributes.permissions
        var isDirectory = false
        var isSymlink = false

        if let mode {
            let typeBits = mode & 0o170000
            isDirectory = typeBits == RemoteEntry.directoryModeBit
            isSymlink = typeBits == RemoteEntry.symlinkModeBit
        } else if let first = name.longName.first {
            // Fall back to the long name when the server omits mode bits.
            isDirectory = first == "d"
            isSymlink = first == "l"
        }
        if isSymlink && name.filename.hasSuffix("/") { isDirectory = true }

        return RemoteEntry(
            name: name.filename,
            path: RemotePath.join(parent, name.filename),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: Int64(bitPattern: name.attributes.size ?? 0),
            modified: name.attributes.modificationDate,
            permissions: mode
        )
    }

    private func openDirectoryHandle(_ path: String) async throws -> Data {
        let response = try await perform(path: path) { writer, id in
            writer.writeByte(SFTPPacketType.opendir.rawValue)
            writer.writeUInt32(id)
            writer.writeString(path)
        }
        guard case .handle(let handle) = response else {
            throw RemoteClientError.pathNotFound(path)
        }
        return handle
    }

    private func closeHandle(_ handle: Data) async throws {
        try await perform { writer, id in
            writer.writeByte(SFTPPacketType.close.rawValue)
            writer.writeUInt32(id)
            writer.writeString(handle)
        }
    }

    // MARK: - Metadata

    public func attributes(of path: String) async throws -> RemoteEntry? {
        if let entry = try? await statEntry(path, followSymlinks: true) { return entry }
        return try? await statEntry(path, followSymlinks: false)
    }

    private func statEntry(_ path: String, followSymlinks: Bool) async throws -> RemoteEntry {
        let type: SFTPPacketType = followSymlinks ? .stat : .lstat
        let response = try await perform(path: path) { writer, id in
            writer.writeByte(type.rawValue)
            writer.writeUInt32(id)
            writer.writeString(path)
        }
        guard case .attributes(let attributes) = response else {
            throw RemoteClientError.pathNotFound(path)
        }
        let mode = attributes.permissions
        let typeBits = (mode ?? 0) & 0o170000
        return RemoteEntry(
            name: RemotePath.lastComponent(of: path),
            path: RemotePath.normalize(path),
            isDirectory: typeBits == RemoteEntry.directoryModeBit,
            isSymlink: typeBits == RemoteEntry.symlinkModeBit,
            size: Int64(bitPattern: attributes.size ?? 0),
            modified: attributes.modificationDate,
            permissions: mode
        )
    }

    private func resolveRealPath(_ path: String) async throws -> String {
        let response = try await perform(path: path) { writer, id in
            writer.writeByte(SFTPPacketType.realpath.rawValue)
            writer.writeUInt32(id)
            writer.writeString(path)
        }
        guard case .name(let names) = response, let first = names.first else {
            return RemotePath.normalize(path)
        }
        return RemotePath.normalize(first.filename)
    }

    // MARK: - Mutations

    public func createDirectory(_ path: String) async throws {
        try await perform(path: path) { writer, id in
            writer.writeByte(SFTPPacketType.mkdir.rawValue)
            writer.writeUInt32(id)
            writer.writeString(path)
            // Empty attribute set: let the server apply its own defaults.
            let attributes = SFTPAttributes()
            attributes.encode(into: &writer)
        }
    }

    public func removeFile(_ path: String) async throws {
        try await perform(path: path) { writer, id in
            writer.writeByte(SFTPPacketType.remove.rawValue)
            writer.writeUInt32(id)
            writer.writeString(path)
        }
    }

    public func removeDirectory(_ path: String) async throws {
        try await perform(path: path) { writer, id in
            writer.writeByte(SFTPPacketType.rmdir.rawValue)
            writer.writeUInt32(id)
            writer.writeString(path)
        }
    }

    public func rename(_ from: String, to: String) async throws {
        do {
            try await sendRename(from: from, to: to)
        } catch {
            // SFTP v3 RENAME refuses to clobber an existing destination, so clear
            // the way and retry once. Re-throw the original if the target is absent.
            guard (try? await attributes(of: to)) != nil else { throw error }
            try await removeFile(to)
            try await sendRename(from: from, to: to)
        }
    }

    private func sendRename(from: String, to: String) async throws {
        try await perform(path: from) { writer, id in
            writer.writeByte(SFTPPacketType.rename.rawValue)
            writer.writeUInt32(id)
            writer.writeString(from)
            writer.writeString(to)
        }
    }

    public func setPermissions(_ path: String, mode: UInt32) async throws {
        try await perform(path: path) { writer, id in
            writer.writeByte(SFTPPacketType.setstat.rawValue)
            writer.writeUInt32(id)
            writer.writeString(path)
            let attributes = SFTPAttributes(permissions: mode)
            attributes.encode(into: &writer)
        }
    }

    // MARK: - Files

    private func openFile(_ path: String, flags: SFTPOpenFlags) async throws -> Data {
        let response = try await perform(path: path) { writer, id in
            writer.writeByte(SFTPPacketType.open.rawValue)
            writer.writeUInt32(id)
            writer.writeString(path)
            writer.writeUInt32(flags.rawValue)
            let attributes = SFTPAttributes()
            attributes.encode(into: &writer)
        }
        guard case .handle(let handle) = response else {
            throw RemoteClientError.server("The server did not return a file handle for \(path).")
        }
        return handle
    }

    private func readData(handle: Data, offset: UInt64, length: Int) async throws -> Data? {
        let response = try await perform { writer, id in
            writer.writeByte(SFTPPacketType.read.rawValue)
            writer.writeUInt32(id)
            writer.writeString(handle)
            writer.writeUInt64(offset)
            writer.writeUInt32(UInt32(length))
        }
        switch response {
        case .data(let data):
            return data
        case .status(let code, _):
            if code == SFTPStatusCode.eof.rawValue { return nil }
            return nil
        default:
            throw SFTPError.unexpectedResponse("expected DATA while reading")
        }
    }

    public func readFile(_ path: String, limit: Int) async throws -> Data {
        let handle = try await openFile(path, flags: [.read])
        defer { Task { try? await closeHandle(handle) } }

        var collected = Data()
        var offset: UInt64 = 0
        while collected.count < limit {
            let want = min(TransferTuning.chunkSize, limit - collected.count)
            guard let chunk = try await readData(handle: handle, offset: offset, length: want),
                  !chunk.isEmpty else { break }
            collected.append(chunk)
            offset += UInt64(chunk.count)
        }
        return collected
    }

    // MARK: - Transfers

    public func download(
        remotePath: String,
        to localURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        let entry = try await statEntry(remotePath, followSymlinks: true)
        guard !entry.isDirectory else {
            throw RemoteClientError.unsupported("Downloading a directory as a single file")
        }
        let total = entry.size

        let handle = try await openFile(remotePath, flags: [.read])

        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.createFile(atPath: localURL.path, contents: nil) {
            try? await closeHandle(handle)
            throw RemoteClientError.transport("Could not create “\(localURL.lastPathComponent)”.")
        }

        guard let output = FileHandle(forWritingAtPath: localURL.path) else {
            try? await closeHandle(handle)
            throw RemoteClientError.transport("Could not open “\(localURL.lastPathComponent)” for writing.")
        }

        var throttle = ProgressThrottle()
        progress?(0, total)
        var written: Int64 = 0

        do {
            try await pipelineDownload(
                handle: handle,
                sink: { data in
                    try output.write(contentsOf: data)
                    written += Int64(data.count)
                    if throttle.shouldEmit(force: written >= total) {
                        progress?(written, total)
                    }
                }
            )
            try? output.close()
            try? await closeHandle(handle)
            progress?(written, total)
        } catch {
            try? output.close()
            try? await closeHandle(handle)
            // Leave no half-written file behind for the user to trip over.
            try? fileManager.removeItem(at: localURL)
            throw error
        }
    }

    /// Keeps several READ requests outstanding so throughput does not collapse
    /// on links with non-trivial latency.
    private func pipelineDownload(
        handle: Data,
        sink: (Data) throws -> Void
    ) async throws {
        let chunkSize = maxPacketSize
        var nextOffset: UInt64 = 0
        var inFlight: [UInt32] = []
        var reachedEOF = false

        while true {
            while inFlight.count < pipelineWindow && !reachedEOF {
                let offset = nextOffset
                nextOffset += UInt64(chunkSize)
                let (id, packet) = buildPacket { writer, id in
                    writer.writeByte(SFTPPacketType.read.rawValue)
                    writer.writeUInt32(id)
                    writer.writeString(handle)
                    writer.writeUInt64(offset)
                    writer.writeUInt32(UInt32(chunkSize))
                }
                try await send(packet)
                inFlight.append(id)
            }

            guard !inFlight.isEmpty else { return }
            let id = inFlight.removeFirst()
            let response = try await awaitResponse(id: id)

            switch response {
            case .data(let data):
                if data.isEmpty {
                    reachedEOF = true
                } else {
                    try sink(data)
                }
            case .status(let code, let message):
                if code == SFTPStatusCode.eof.rawValue {
                    reachedEOF = true
                } else if let error = SFTPResponse.error(fromStatus: code, message: message, path: nil) {
                    throw error
                }
            default:
                throw SFTPError.unexpectedResponse("expected DATA while downloading")
            }
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

        let handle = try await openFile(
            remotePath,
            flags: [.write, .create, .truncate]
        )

        var throttle = ProgressThrottle()
        progress?(0, total)
        var offset: UInt64 = 0
        var inFlight: [UInt32] = []
        /// Sizes of the chunks still awaiting acknowledgement, oldest first.
        var inFlightSizes: [Int] = []
        var inFlightBytes = 0

        do {
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: TransferTuning.chunkSize) ?? Data()
                if chunk.isEmpty { break }

                let id = reserveID()
                var writer = SFTPWriter()
                writer.beginPacket()
                writer.writeByte(SFTPPacketType.write.rawValue)
                writer.writeUInt32(id)
                writer.writeString(handle)
                writer.writeUInt64(offset)
                writer.writeString(chunk)
                try await send(writer.finish())

                inFlight.append(id)
                inFlightSizes.append(chunk.count)
                inFlightBytes += chunk.count
                offset += UInt64(chunk.count)

                if inFlight.count >= pipelineWindow {
                    let oldest = inFlight.removeFirst()
                    let ackedSize = inFlightSizes.removeFirst()
                    try await acknowledgeWrite(id: oldest)
                    inFlightBytes -= ackedSize
                    // Everything sent minus what is still unacknowledged is what
                    // the server has definitely committed.
                    let sent = offset - UInt64(inFlightBytes)
                    if throttle.shouldEmit(force: sent >= UInt64(total)) {
                        progress?(Int64(sent), total)
                    }
                }
            }

            for id in inFlight {
                try await acknowledgeWrite(id: id)
            }
            try? input.close()
            try? await closeHandle(handle)
            progress?(total, total)
        } catch {
            try? input.close()
            try? await closeHandle(handle)
            throw error
        }
    }

    private func acknowledgeWrite(id: UInt32) async throws {
        let response = try await awaitResponse(id: id)
        guard case .status(let code, let message) = response else { return }
        if let error = SFTPResponse.error(fromStatus: code, message: message, path: nil) {
            throw error
        }
    }

    // MARK: - Teardown

    public func disconnect() async {
        closed = true
        readerTask?.cancel()
        readerTask = nil

        for (_, waiter) in pending {
            waiter.resume(throwing: ByteStreamError.closed)
        }
        pending.removeAll()
        earlyResponses.removeAll()

        stream?.close()
        stream = nil
        for transport in ownedTransports { transport.close() }
        ownedTransports.removeAll()
        processTransport = nil
    }
}

