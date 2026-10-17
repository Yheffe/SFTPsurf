import Foundation

/// A plain TCP connection represented as a `ByteStream`.
public final class SocketTransport: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let reader: BlockingByteReader
    private let lock = NSLock()
    private var closedFlag = false
    private let sendTimeout: TimeInterval
    /// Serialises writes so concurrent callers cannot interleave partial packets.
    private let writeQueue = DispatchQueue(label: "SFTPsurf.SocketTransport.write")

    private init(fd: Int32, sendTimeout: TimeInterval) {
        self.fd = fd
        self.sendTimeout = sendTimeout
        // Shutting down the socket is what actually unblocks a pending read(2).
        self.reader = BlockingByteReader(fd: fd, interrupter: { socketFD in
            shutdown(socketFD, SHUT_RDWR)
        })
        self.reader.start()
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closedFlag
    }

    // MARK: - Connecting

    public static func connect(
        host: String,
        port: Int,
        timeout: TimeInterval = 30,
        sendTimeout: TimeInterval = 60
    ) throws -> SocketTransport {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &info)
        guard status == 0, let head = info else {
            let message = String(cString: gai_strerror(status))
            if status == EAI_NONAME || status == EAI_FAIL || status == EAI_NODATA {
                throw RemoteClientError.hostNotFound(host)
            }
            throw RemoteClientError.transport("Could not resolve \(host): \(message)")
        }
        defer { freeaddrinfo(head) }

        let deadline = Date().addingTimeInterval(timeout)
        var lastError = "no addresses to try"

        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let current = cursor {
            let ai = current.pointee
            cursor = ai.ai_next

            let candidate = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
            if candidate < 0 {
                lastError = String(cString: strerror(errno))
                continue
            }

            let originalFlags = fcntl(candidate, F_GETFL, 0)
            _ = fcntl(candidate, F_SETFL, originalFlags | O_NONBLOCK)

            var connected = Darwin.connect(candidate, ai.ai_addr, ai.ai_addrlen) == 0
            if !connected && errno == EINPROGRESS {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    Darwin.close(candidate)
                    throw RemoteClientError.timedOut("Connecting to \(host):\(port) took longer than \(Int(timeout))s.")
                }
                var descriptor = pollfd(fd: candidate, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, Int32(remaining * 1000))
                if ready == 0 {
                    Darwin.close(candidate)
                    throw RemoteClientError.timedOut("Connecting to \(host):\(port) took longer than \(Int(timeout))s.")
                }
                if ready < 0 {
                    lastError = String(cString: strerror(errno))
                    Darwin.close(candidate)
                    continue
                }
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(candidate, SOL_SOCKET, SO_ERROR, &socketError, &length)
                if socketError != 0 {
                    lastError = String(cString: strerror(socketError))
                    Darwin.close(candidate)
                    continue
                }
                connected = true
            } else if !connected {
                lastError = String(cString: strerror(errno))
                Darwin.close(candidate)
                continue
            }

            // Back to blocking mode now that the handshake is done.
            _ = fcntl(candidate, F_SETFL, originalFlags)
            setSocketOptions(candidate, sendTimeout: sendTimeout)
            return SocketTransport(fd: candidate, sendTimeout: sendTimeout)
        }

        if lastError.contains("Connection refused") || lastError.contains("refused") {
            throw RemoteClientError.connectionRefused(lastError)
        }
        throw RemoteClientError.transport("Could not connect to \(host):\(port) — \(lastError)")
    }

    private static func setSocketOptions(_ fd: Int32, sendTimeout: TimeInterval) {
        var one: Int32 = 1
        // Never let a broken peer turn into a fatal SIGPIPE.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Detect dead peers rather than hanging forever on a stalled transfer.
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(
            tv_sec: Int(sendTimeout),
            tv_usec: suseconds_t((sendTimeout - Double(Int(sendTimeout))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Peer identity

    /// The numeric address of the remote end, as reported by the kernel.
    /// Extended passive mode needs this to know where to open the data socket.
    public var peerHost: String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getpeername(fd, address, &length)
            }
        }
        guard result == 0 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafeMutablePointer(to: &storage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getnameinfo(
                    address,
                    length,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        guard status == 0 else { return nil }
        return String(cString: host)
    }

    // MARK: - Writing

    public func write(_ data: Data) async throws {
        guard !isClosed else { throw ByteStreamError.closed }
        guard !data.isEmpty else { return }
        let descriptor = fd

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    try data.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let written = send(
                                descriptor,
                                raw.baseAddress!.advanced(by: offset),
                                raw.count - offset,
                                MSG_NOSIGNAL
                            )
                            if written > 0 { offset += written; continue }
                            if written < 0 && errno == EINTR { continue }
                            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                                // Send timed out; surface it instead of spinning.
                                throw RemoteClientError.timedOut("Sending data stalled.")
                            }
                            throw RemoteClientError.transport(
                                "Send failed: \(String(cString: strerror(errno)))"
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

    // MARK: - Reading

    public func readExactly(_ count: Int) async throws -> Data {
        try await reader.readExactly(count)
    }

    public func readLine(maxLength: Int) async throws -> Data {
        try await reader.readLine(maxLength: maxLength)
    }

    public func readSome(maxLength: Int) async throws -> Data {
        try await reader.readSome(maxLength: maxLength)
    }

    public func readSomeOrEOF(maxLength: Int) async throws -> Data? {
        try await reader.readSomeOrEOF(maxLength: maxLength)
    }

    public func close() {
        lock.lock()
        if closedFlag { lock.unlock(); return }
        closedFlag = true
        lock.unlock()

        shutdown(fd, SHUT_RDWR)
        reader.close()
        Darwin.close(fd)
    }
}
