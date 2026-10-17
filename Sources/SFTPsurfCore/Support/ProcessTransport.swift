import Foundation

/// Runs a helper process (`ssh`, or `sftp-server` in tests) and exposes its
/// stdin/stdout as a `ByteStream`.
public final class ProcessTransport: ByteStream, @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let workingDirectory: URL?

    private let process = Process()
    private var reader: BlockingByteReader?
    /// Retained deliberately: the reader's thread holds only a weak reference to
    /// itself, so if nothing owns it the reader is deallocated immediately and
    /// the child's stderr is never read.
    private var errorReader: BlockingByteReader?
    private var writeFD: Int32 = -1
    private let stderrBuffer = StderrBuffer()
    private let lock = NSLock()
    private var started = false
    private var closedFlag = false
    /// Serialises writes so concurrent callers cannot interleave partial packets.
    private let writeQueue = DispatchQueue(label: "SFTPsurf.ProcessTransport.write")

    /// Accumulates a bounded tail of the child's stderr so failures can be
    /// reported with the server's own words.
    private final class StderrBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit = 64 * 1024

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
            lock.unlock()
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closedFlag
    }

    public var stderrText: String { stderrBuffer.text }

    /// Waits for the child to finish, so its stderr has definitely been read.
    ///
    /// When ssh fails to authenticate it writes the reason to stderr and exits.
    /// The stdout pipe can close before that write lands, which would otherwise
    /// leave us with an empty stderr and a useless "connection ended" message.
    @discardableResult
    public func waitForExit(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            // stderr arriving is a good enough signal even if ssh lingers.
            if !stderrBuffer.text.isEmpty, process.isRunning == false { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }

    /// Blocks until stderr has something in it, or the timeout lapses.
    public func waitForStandardError(timeout: TimeInterval = 3) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = stderrBuffer.text
            if !text.isEmpty { return text }
            if !process.isRunning {
                // Give the reader thread a moment to drain the pipe.
                Thread.sleep(forTimeInterval: 0.05)
                return stderrBuffer.text
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return stderrBuffer.text
    }

    public var terminationStatus: Int32? {
        process.isRunning ? nil : process.terminationStatus
    }

    /// Launches the process. Throws if the executable cannot be started.
    public func start() throws {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        do {
            try process.run()
        } catch {
            throw RemoteClientError.transport(
                "Could not start \(executable.lastPathComponent): \(error.localizedDescription)"
            )
        }

        writeFD = stdinPipe.fileHandleForWriting.fileDescriptor

        let errorReader = BlockingByteReader(
            fd: stderrPipe.fileHandleForReading.fileDescriptor,
            mode: .streaming { [stderrBuffer] data in stderrBuffer.append(data) }
        )
        errorReader.start()
        self.errorReader = errorReader

        let stdoutReader = BlockingByteReader(fd: stdoutPipe.fileHandleForReading.fileDescriptor)
        stdoutReader.start()
        reader = stdoutReader

        // The parent must drop its copies of the far ends, otherwise stdout
        // never reports EOF when the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe.fileHandleForReading.close()
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let fd = writeFD
        guard fd >= 0 else { throw RemoteClientError.notConnected }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ByteStreamError.closed)
                    return
                }
                do {
                    try data.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if n > 0 { offset += n; continue }
                            if n < 0 && errno == EINTR { continue }
                            if n < 0 && errno == EPIPE {
                                throw ByteStreamError.connectFailed(self.brokenPipeMessage())
                            }
                            throw ByteStreamError.connectFailed(
                                "write failed: \(String(cString: strerror(errno)))"
                            )
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Turns the child's stderr into something worth showing the user.
    private func brokenPipeMessage() -> String {
        let stderr = stderrBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if let status = terminationStatus, status != 0 {
            return "The helper process exited with status \(status)."
        }
        return "The connection was closed by the server."
    }

    public func readExactly(_ count: Int) async throws -> Data {
        guard let reader else { throw RemoteClientError.notConnected }
        return try await reader.readExactly(count)
    }

    public func readLine(maxLength: Int) async throws -> Data {
        guard let reader else { throw RemoteClientError.notConnected }
        return try await reader.readLine(maxLength: maxLength)
    }

    public func readSome(maxLength: Int) async throws -> Data {
        guard let reader else { throw RemoteClientError.notConnected }
        return try await reader.readSome(maxLength: maxLength)
    }

    public func readSomeOrEOF(maxLength: Int) async throws -> Data? {
        guard let reader else { throw RemoteClientError.notConnected }
        return try await reader.readSomeOrEOF(maxLength: maxLength)
    }

    public func close() {
        lock.lock()
        if closedFlag { lock.unlock(); return }
        closedFlag = true
        let fd = writeFD
        writeFD = -1
        lock.unlock()

        if fd >= 0 { Darwin.close(fd) }
        reader?.close()
        errorReader?.close()

        if process.isRunning {
            process.terminate()
        }
    }
}
