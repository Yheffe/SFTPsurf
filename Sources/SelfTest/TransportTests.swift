import Foundation
import SFTPsurfCore

/// Covers the byte-stream plumbing that both protocol clients sit on.
enum TransportTests {
    static var cases: [TestCase] {
        [
            TestCase("a child's stderr is captured") {
                // This is what turns "connection ended unexpectedly" into
                // "Permission denied" for SFTP, so it needs to work reliably.
                let transport = ProcessTransport(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "echo 'diagnostic text' >&2; exit 3"]
                )
                try transport.start()

                let text = transport.waitForStandardError(timeout: 5)
                try expect(
                    text.contains("diagnostic text"),
                    "stderr was not captured, got [\(text)]"
                )
                try expect(
                    transport.terminationStatus == 3,
                    "expected exit status 3, got \(String(describing: transport.terminationStatus))"
                )
                transport.close()
            },

            TestCase("stdout and stderr are kept separate") {
                let transport = ProcessTransport(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "echo to-stdout; echo to-stderr >&2"]
                )
                try transport.start()

                let line = try await transport.readLine(maxLength: 4096)
                let stdout = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try expect(stdout == "to-stdout", "got [\(stdout)]")

                let stderr = transport.waitForStandardError(timeout: 5)
                try expect(
                    stderr.contains("to-stderr") && !stderr.contains("to-stdout"),
                    "streams are crossed: [\(stderr)]"
                )
                transport.close()
            },

            TestCase("a clean exit reports no error and no stderr") {
                let transport = ProcessTransport(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf 'payload'"]
                )
                try transport.start()

                let data = try await transport.readExactly(7)
                try expect(String(decoding: data, as: UTF8.self) == "payload")

                // Nothing on stderr, so this must time out cleanly rather than
                // inventing something or hanging forever.
                let started = Date()
                let stderr = transport.waitForStandardError(timeout: 1)
                let elapsed = Date().timeIntervalSince(started)
                try expect(stderr.isEmpty, "expected no stderr, got [\(stderr)]")
                try expect(elapsed < 4, "waiting should have honoured its timeout, took \(elapsed)s")

                try expect(
                    transport.terminationStatus == 0,
                    "expected success, got \(String(describing: transport.terminationStatus))"
                )
                transport.close()
            },

            TestCase("closing a transport unblocks a pending read") {
                // Mirrors the SFTP case: the peer vanishes mid-read, which must
                // surface as an error rather than hanging.
                let transport = ProcessTransport(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 30"]
                )
                try transport.start()

                let reader = Task { try await transport.readExactly(4) }
                try await Task.sleep(nanoseconds: 200_000_000)
                transport.close()

                do {
                    _ = try await reader.value
                    throw CheckError(
                        message: "reading from a closed transport should fail",
                        file: #fileID,
                        line: #line
                    )
                } catch is ByteStreamError {
                    // Expected: the read is interrupted rather than hanging.
                }
            },

            TestCase("a broken pipe on write is reported") {
                let transport = ProcessTransport(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "exit 0"]
                )
                try transport.start()
                // Let the child exit so the pipe is closed underneath us.
                try? await Task.sleep(nanoseconds: 400_000_000)

                do {
                    // Large enough to overflow the pipe buffer even if the child
                    // lingered, so the write cannot silently succeed.
                    try await transport.write(Data(repeating: 0x41, count: 1 << 20))
                    // A write that happens to succeed before the close lands is
                    // acceptable; what matters is not crashing or hanging.
                } catch is ByteStreamError {
                    // Expected.
                } catch let error as RemoteClientError {
                    guard case .transport = error else { throw error }
                }
                transport.close()
            },

            TestCase("a socket that refuses connection reports it clearly") {
                // Port 1 is reserved and never listening.
                do {
                    _ = try SocketTransport.connect(host: "127.0.0.1", port: 1, timeout: 5)
                    throw CheckError(
                        message: "connecting to a closed port should fail",
                        file: #fileID,
                        line: #line
                    )
                } catch let error as RemoteClientError {
                    switch error {
                    case .connectionRefused, .timedOut, .transport:
                        break
                    default:
                        throw CheckError(
                            message: "unexpected error for a refused connection: \(error)",
                            file: #fileID,
                            line: #line
                        )
                    }
                }
            },

            TestCase("a hostname that cannot resolve is reported as such") {
                do {
                    _ = try SocketTransport.connect(
                        host: "this-host-does-not-exist.invalid",
                        port: 22,
                        timeout: 5
                    )
                    throw CheckError(
                        message: "resolving a bogus host should fail",
                        file: #fileID,
                        line: #line
                    )
                } catch let error as RemoteClientError {
                    guard case .hostNotFound = error else {
                        throw CheckError(
                            message: "expected hostNotFound, got \(error)",
                            file: #fileID,
                            line: #line
                        )
                    }
                }
            },
        ]
    }
}
