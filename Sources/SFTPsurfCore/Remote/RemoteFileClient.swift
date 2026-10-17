import Foundation

/// Reports `(bytesTransferred, totalBytes)` as a transfer proceeds.
public typealias TransferProgressHandler = @Sendable (Int64, Int64) -> Void

/// The operations the browser needs from a remote server, regardless of protocol.
public protocol RemoteFileClient: Sendable {
    /// Opens the session and performs any handshake (login, subsystem, version).
    func connect(profile: ConnectionProfile, credential: Credential) async throws
    /// The directory a session should open in, as reported by the server.
    func homePath() async throws -> String

    func list(_ path: String) async throws -> [RemoteEntry]
    func attributes(of path: String) async throws -> RemoteEntry?

    func createDirectory(_ path: String) async throws
    func removeFile(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    func setPermissions(_ path: String, mode: UInt32) async throws

    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws
    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws

    func readFile(_ path: String, limit: Int) async throws -> Data

    func disconnect() async
}

public enum TransferTuning {
    public static let chunkSize = 32 * 1024
}
