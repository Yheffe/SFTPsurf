import Foundation

/// One complete FTP reply: a status code plus every line the server sent.
///
/// Replies are either a single `NNN text` line or a `NNN-…` block terminated by
/// a line beginning with the same code and a space.
public struct FTPReply {
    public let code: Int
    public let lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    public var message: String {
        lines.joined(separator: " ")
    }

    /// The reply text with the leading status code removed, for cleaner errors.
    public var detail: String {
        let cleaned = lines.map { line -> String in
            guard line.count > 3 else { return line }
            let codePart = line.prefix(3)
            guard Int(codePart) != nil else { return line }
            var rest = line.dropFirst(3)
            if rest.hasPrefix("-") || rest.hasPrefix(" ") { rest = rest.dropFirst() }
            return String(rest)
        }
        return cleaned.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var isPositive: Bool { (200...299).contains(code) }
    /// A preliminary reply (1xx): the server expects a follow-up.
    public var isPreliminary: Bool { (100...199).contains(code) }

    /// Turns an unexpected reply into an error with the server's own wording.
    public func failure(_ context: String, path: String? = nil) -> Error {
        let text = detail.isEmpty ? "Server replied \(code)." : detail
        switch code {
        case 530:
            return RemoteClientError.authenticationFailed(text)
        case 550:
            let lowered = text.lowercased()
            if lowered.contains("permission") || lowered.contains("denied") {
                return RemoteClientError.permissionDenied(path ?? text)
            }
            return path.map { RemoteClientError.pathNotFound($0) } ?? RemoteClientError.server(text)
        case 552, 553:
            return RemoteClientError.server(text)
        case 500, 502, 504:
            return RemoteClientError.unsupported(context)
        default:
            return RemoteClientError.server(text)
        }
    }
}

public enum FTPReplyParser {
    private static let lineLimit = 500

    /// Reads one full reply, consuming continuation lines.
    public static func readReply(from stream: ByteStream) async throws -> FTPReply {
        var lines: [String] = []
        let first = try await readCleanLine(from: stream)
        lines.append(first)

        guard let code = statusCode(of: first) else {
            throw RemoteClientError.server("Unrecognised FTP reply: \(first)")
        }

        // "NNN-" opens a multi-line block that ends with "NNN " (note the space).
        let isMultiline = first.count > 3 && first[first.index(first.startIndex, offsetBy: 3)] == "-"
        guard isMultiline else { return FTPReply(code: code, lines: lines) }

        while lines.count < lineLimit {
            let line = try await readCleanLine(from: stream)
            lines.append(line)
            if line.count >= 4,
               let lineCode = statusCode(of: line),
               lineCode == code,
               line[line.index(line.startIndex, offsetBy: 3)] == " " {
                break
            }
        }
        return FTPReply(code: code, lines: lines)
    }

    /// Reads a line and strips the trailing CRLF.
    public static func readCleanLine(from stream: ByteStream) async throws -> String {
        let raw = try await stream.readLine(maxLength: 64 * 1024)
        var text = String(decoding: raw, as: UTF8.self)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    public static func statusCode(of line: String) -> Int? {
        guard line.count >= 3 else { return nil }
        return Int(line.prefix(3))
    }
}
