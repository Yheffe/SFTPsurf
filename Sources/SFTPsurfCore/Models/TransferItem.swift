import Foundation

public enum TransferDirection: String, Codable, Sendable {
    case upload
    case download

    public var displayName: String { self == .upload ? "Upload" : "Download" }
}

public enum TransferState: Equatable, Sendable {
    case queued
    case running
    case completed
    case failed(String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Transferring"
        case .completed: return "Completed"
        case .failed(let message): return "Failed: \(message)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// An immutable description of one file movement.
public struct TransferRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let direction: TransferDirection
    public let sourcePath: String
    public let destinationPath: String
    /// Bytes expected, used for the progress bar. 0 when unknown.
    public let totalBytes: Int64

    public init(
        id: UUID = UUID(),
        direction: TransferDirection,
        sourcePath: String,
        destinationPath: String,
        totalBytes: Int64
    ) {
        self.id = id
        self.direction = direction
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.totalBytes = totalBytes
    }

    public var displayName: String {
        (destinationPath as NSString).lastPathComponent
    }
}

/// Live state for one row in the transfers window.
public struct TransferItem: Identifiable, Equatable, Sendable {
    public let request: TransferRequest
    public var state: TransferState
    public var bytesTransferred: Int64
    /// Kept separate from the request because a server that reports no size up
    /// front can still supply one once the transfer starts.
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    public var startedAt: Date?
    public var finishedAt: Date?

    public var id: UUID { request.id }

    public init(
        request: TransferRequest,
        state: TransferState = .queued,
        bytesTransferred: Int64 = 0,
        totalBytes: Int64? = nil,
        bytesPerSecond: Double = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.request = request
        self.state = state
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes ?? request.totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesTransferred) / Double(totalBytes))
    }

    public var isIndeterminate: Bool { totalBytes <= 0 }
}

/// Formats byte counts the way Finder does, for display in the UI.
public enum ByteFormatter {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    public static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0, bytesPerSecond.isFinite else { return "—" }
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }
}
