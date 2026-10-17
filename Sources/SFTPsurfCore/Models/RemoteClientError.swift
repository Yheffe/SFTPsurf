import Foundation

public enum RemoteClientError: LocalizedError, Sendable {
    case notConnected
    case hostNotFound(String)
    case connectionRefused(String)
    case timedOut(String)
    case authenticationFailed(String)
    case hostKeyRejected(String)
    case server(String)
    case pathNotFound(String)
    case permissionDenied(String)
    case unsupported(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to a server."
        case .hostNotFound(let host):
            return "Could not find the server “\(host)”."
        case .connectionRefused(let detail):
            return "The server refused the connection. \(detail)"
        case .timedOut(let detail):
            return "The connection timed out. \(detail)"
        case .authenticationFailed(let detail):
            return detail.isEmpty ? "Authentication failed." : detail
        case .hostKeyRejected(let detail):
            return detail
        case .server(let message):
            return message
        case .pathNotFound(let path):
            return "“\(path)” does not exist on the server."
        case .permissionDenied(let path):
            return "You do not have permission to access “\(path)”."
        case .unsupported(let feature):
            return "The server does not support \(feature)."
        case .transport(let message):
            return message
        }
    }

    /// Human-readable hint shown under the error in the connect sheet.
    public var recoverySuggestion: String? {
        switch self {
        case .authenticationFailed:
            return "Check the username, password, or private key and try again."
        case .connectionRefused:
            return "Confirm the port is correct and that the server allows connections from this machine."
        case .hostKeyRejected:
            return "The server's host key changed or was rejected. Verify the fingerprint before trusting it."
        case .timedOut:
            return "The server may be unreachable, or a firewall may be blocking the port."
        default:
            return nil
        }
    }
}

/// Raised when a stream ends earlier than the peer promised.
public enum ByteStreamError: LocalizedError, Sendable {
    case endedUnexpectedly
    case closed
    case connectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .endedUnexpectedly: return "The connection closed unexpectedly."
        case .closed: return "The stream was closed."
        case .connectFailed(let message): return message
        }
    }
}
