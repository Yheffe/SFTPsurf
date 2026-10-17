import Foundation

/// A duplex byte stream. Both the SSH pipe carrying SFTP and the TCP sockets
/// carrying FTP funnel through this, so the protocol layers above never care
/// which one they are talking to.
public protocol ByteStream: AnyObject, Sendable {
    func write(_ data: Data) async throws
    /// Reads exactly `count` bytes, or throws if the peer closes early.
    func readExactly(_ count: Int) async throws -> Data
    /// Reads up to and including the next LF. Throws at EOF with no data left.
    func readLine(maxLength: Int) async throws -> Data
    /// Reads whatever is available, waiting for at least one byte.
    func readSome(maxLength: Int) async throws -> Data
    /// Like `readSome`, but returns nil once the peer has cleanly closed.
    func readSomeOrEOF(maxLength: Int) async throws -> Data?
    func close()
    var isClosed: Bool { get }
}

/// Reads a file descriptor on a dedicated thread and hands bytes to async callers.
///
/// A background thread is the simplest correct way to bridge a blocking `read(2)`
/// into Swift concurrency, and it avoids fighting `DispatchSource` bookkeeping
/// for the handful of sockets a file browser opens.
public final class BlockingByteReader: @unchecked Sendable {
    /// What the reader does with bytes as they arrive.
    public enum Mode {
        /// Buffer them for `readExactly` / `readLine` callers.
        case buffered
        /// Hand them straight to the closure (used for draining child stderr).
        case streaming(@Sendable (Data) -> Void)
    }

    private let fd: Int32
    private let mode: Mode
    /// Called to unblock a thread stuck in `read(2)`; closing an fd alone does
    /// not reliably wake a blocked reader on Darwin.
    private let interrupter: @Sendable (Int32) -> Void

    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var reachedEOF = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var closedFlag = false
    private var thread: Thread?

    private let chunkSize = 128 * 1024

    public init(fd: Int32, mode: Mode = .buffered, interrupter: (@Sendable (Int32) -> Void)? = nil) {
        self.fd = fd
        self.mode = mode
        self.interrupter = interrupter ?? { _ in }
    }

    public func start() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "SFTPsurf.ByteReader"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    public var isClosed: Bool {
        withLock { closedFlag }
    }

    /// Runs `body` while holding the state lock. Kept synchronous so the lock is
    /// never acquired directly from an async context.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Mutates state under the lock, then resumes any waiters *outside* it so a
    /// continuation can never run while the lock is held.
    private func mutate(_ body: (inout [CheckedContinuation<Void, Error>]) -> Void) {
        var pending: [CheckedContinuation<Void, Error>] = []
        lock.lock()
        body(&pending)
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    public func close() {
        var alreadyClosed = false
        mutate { pending in
            if closedFlag { alreadyClosed = true; return }
            closedFlag = true
            if failure == nil { failure = ByteStreamError.closed }
            reachedEOF = true
            pending = waiters
            waiters.removeAll()
        }
        guard !alreadyClosed else { return }
        interrupter(fd)
    }

    // MARK: - Reading thread

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            if withLock({ closedFlag }) { return }

            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, raw.count)
            }

            if count > 0 {
                deliver(Data(chunk[0..<count]))
            } else if count == 0 {
                mutate { pending in
                    reachedEOF = true
                    pending = waiters
                    waiters.removeAll()
                }
                return
            } else {
                let code = errno
                if code == EINTR { continue }
                let message = String(cString: strerror(code))
                mutate { pending in
                    if failure == nil {
                        failure = ByteStreamError.connectFailed("read failed: \(message)")
                    }
                    reachedEOF = true
                    pending = waiters
                    waiters.removeAll()
                }
                return
            }
        }
    }

    private func deliver(_ data: Data) {
        switch mode {
        case .streaming(let sink):
            sink(data)
        case .buffered:
            mutate { pending in
                buffer.append(contentsOf: data)
                pending = waiters
                waiters.removeAll()
            }
        }
    }

    /// Suspends until more bytes are buffered, EOF is reached, or the stream closes.
    private func awaitMoreData() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            // Re-check under the lock so a fast producer cannot lose the wakeup.
            let ready = buffer.count > cursor || reachedEOF || failure != nil || closedFlag
            if !ready { waiters.append(continuation) }
            lock.unlock()
            if ready { continuation.resume() }
        }
    }

    private func compactIfNeeded() {
        guard cursor > 1_048_576, cursor > buffer.count / 2 else { return }
        buffer.removeFirst(cursor)
        cursor = 0
    }

    /// Pulls `count` buffered bytes, or nil when the buffer is short.
    /// Callers must already hold the lock.
    private func takeBuffered(_ count: Int) -> Data? {
        let available = buffer.count - cursor
        guard available >= count else { return nil }
        let start = buffer.startIndex + cursor
        let slice = buffer[start..<(start + count)]
        cursor += count
        compactIfNeeded()
        return Data(slice)
    }

    /// Outcome of one buffered-read attempt.
    private enum ReadOutcome {
        case data(Data)
        case endOfStream
        case needMore
        case failed(Error)
    }

    private func tryReadExactly(_ count: Int) -> ReadOutcome {
        withLock {
            if let data = takeBuffered(count) { return .data(data) }
            if let failure { return .failed(failure) }
            if reachedEOF { return .failed(ByteStreamError.endedUnexpectedly) }
            return .needMore
        }
    }

    public func readExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        while true {
            switch tryReadExactly(count) {
            case .data(let data): return data
            case .endOfStream: throw ByteStreamError.endedUnexpectedly
            case .failed(let error): throw error
            case .needMore: try await awaitMoreData()
            }
        }
    }

    private func tryReadSome(maxLength: Int) -> ReadOutcome {
        withLock {
            let available = buffer.count - cursor
            if available > 0, let data = takeBuffered(min(available, maxLength)) {
                return .data(data)
            }
            if let failure { return .failed(failure) }
            if reachedEOF { return .failed(ByteStreamError.endedUnexpectedly) }
            return .needMore
        }
    }

    public func readSome(maxLength: Int) async throws -> Data {
        while true {
            switch tryReadSome(maxLength: maxLength) {
            case .data(let data): return data
            case .endOfStream: throw ByteStreamError.endedUnexpectedly
            case .failed(let error): throw error
            case .needMore: try await awaitMoreData()
            }
        }
    }

    /// Reports a clean end of stream as nil rather than an error, which is what
    /// protocols that signal completion by closing the socket need.
    private func tryReadSomeOrEOF(maxLength: Int) -> ReadOutcome {
        withLock {
            let available = buffer.count - cursor
            if available > 0, let data = takeBuffered(min(available, maxLength)) {
                return .data(data)
            }
            if let failure { return .failed(failure) }
            if reachedEOF { return .endOfStream }
            return .needMore
        }
    }

    public func readSomeOrEOF(maxLength: Int) async throws -> Data? {
        while true {
            switch tryReadSomeOrEOF(maxLength: maxLength) {
            case .data(let data): return data
            case .endOfStream: return nil
            case .failed(let error): throw error
            case .needMore: try await awaitMoreData()
            }
        }
    }

    private func tryReadLine(maxLength: Int) -> ReadOutcome {
        withLock {
            let available = buffer.count - cursor
            if available > 0 {
                let start = buffer.startIndex + cursor
                let searchEnd = start + min(available, maxLength)
                if let newline = buffer[start..<searchEnd].firstIndex(of: 0x0A) {
                    if let data = takeBuffered(newline - start + 1) { return .data(data) }
                } else if available >= maxLength {
                    if let data = takeBuffered(maxLength) { return .data(data) }
                }
            }
            if let failure { return .failed(failure) }
            if reachedEOF {
                // Hand back a trailing line that arrived without its newline.
                if available > 0, let data = takeBuffered(available) { return .data(data) }
                return .failed(ByteStreamError.endedUnexpectedly)
            }
            return .needMore
        }
    }

    public func readLine(maxLength: Int = 1 << 20) async throws -> Data {
        while true {
            switch tryReadLine(maxLength: maxLength) {
            case .data(let data): return data
            case .endOfStream: throw ByteStreamError.endedUnexpectedly
            case .failed(let error): throw error
            case .needMore: try await awaitMoreData()
            }
        }
    }
}
