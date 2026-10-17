import Foundation

// MARK: - Wire primitives

/// Big-endian writer for SFTP packets.
///
/// A packet is laid out as `length(4) | type(1) | payload`, where `length`
/// counts the type byte plus the payload but not itself. Callers reserve the
/// length with `beginPacket()`, write the type byte, then call `finish()`.
struct SFTPWriter {
    private(set) var bytes: [UInt8] = []
    private var beginCount = 0

    mutating func beginPacket() {
        beginCount += 1
        writeUInt32(0)
    }

    mutating func writeByte(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func writeUInt64(_ value: UInt64) {
        writeUInt32(UInt32((value >> 32) & 0xFFFF_FFFF))
        writeUInt32(UInt32(value & 0xFFFF_FFFF))
    }

    /// SFTP strings are a length prefix followed by raw bytes, with no NUL.
    mutating func writeString(_ data: Data) {
        writeUInt32(UInt32(data.count))
        bytes.append(contentsOf: data)
    }

    mutating func writeString(_ string: String) {
        writeString(Data(string.utf8))
    }

    mutating func writeAttributes(_ attributes: SFTPAttributes) {
        attributes.encode(into: &self)
    }

    /// Patches the reserved length field and returns the framed packet.
    mutating func finish() -> Data {
        precondition(beginCount == 1, "finish() expects exactly one beginPacket()")
        let length = UInt32(bytes.count - 4)
        bytes[0] = UInt8((length >> 24) & 0xFF)
        bytes[1] = UInt8((length >> 16) & 0xFF)
        bytes[2] = UInt8((length >> 8) & 0xFF)
        bytes[3] = UInt8(length & 0xFF)
        beginCount = 0
        return Data(bytes)
    }
}

/// Big-endian reader that refuses to read past the end of a packet.
struct SFTPReader {
    private let bytes: [UInt8]
    private var offset: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.offset = 0
    }

    var remaining: Int { bytes.count - offset }

    mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPError.malformedPacket("truncated byte") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPError.malformedPacket("truncated uint32") }
        let value = UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let high = try readUInt32()
        let low = try readUInt32()
        return UInt64(high) << 32 | UInt64(low)
    }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard length >= 0, remaining >= length else {
            throw SFTPError.malformedPacket("truncated string of \(length) bytes")
        }
        let slice = bytes[offset..<(offset + length)]
        offset += length
        return Data(slice)
    }

    mutating func readText() throws -> String {
        String(decoding: try readString(), as: UTF8.self)
    }

    mutating func readAttributes() throws -> SFTPAttributes {
        try SFTPAttributes(from: &self)
    }
}

// MARK: - Packet types

enum SFTPPacketType: UInt8 {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20

    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attributes = 105
    case extendedReply = 201
}

enum SFTPStatusCode: UInt32 {
    case ok = 0
    case eof = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case opUnsupported = 8
}

/// Open flags for `SSH_FXP_OPEN`.
struct SFTPOpenFlags: OptionSet {
    let rawValue: UInt32
    static let read = SFTPOpenFlags(rawValue: 0x0000_0001)
    static let write = SFTPOpenFlags(rawValue: 0x0000_0002)
    static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    static let create = SFTPOpenFlags(rawValue: 0x0000_0008)
    static let truncate = SFTPOpenFlags(rawValue: 0x0000_0010)
    static let exclusive = SFTPOpenFlags(rawValue: 0x0000_0020)
}

// MARK: - Attributes

struct SFTPAttributes {
    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var accessTime: UInt32?
    var modificationTime: UInt32?

    init(
        size: UInt64? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        permissions: UInt32? = nil,
        accessTime: UInt32? = nil,
        modificationTime: UInt32? = nil
    ) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    private static let flagSize: UInt32 = 0x0000_0001
    private static let flagUidGid: UInt32 = 0x0000_0002
    private static let flagPermissions: UInt32 = 0x0000_0004
    private static let flagACModTime: UInt32 = 0x0000_0008

    func encode(into writer: inout SFTPWriter) {
        var flags: UInt32 = 0
        if size != nil { flags |= Self.flagSize }
        if uid != nil || gid != nil { flags |= Self.flagUidGid }
        if permissions != nil { flags |= Self.flagPermissions }
        if accessTime != nil || modificationTime != nil { flags |= Self.flagACModTime }

        writer.writeUInt32(flags)
        if let size { writer.writeUInt64(size) }
        if flags & Self.flagUidGid != 0 {
            writer.writeUInt32(uid ?? 0)
            writer.writeUInt32(gid ?? 0)
        }
        if let permissions { writer.writeUInt32(permissions) }
        if flags & Self.flagACModTime != 0 {
            writer.writeUInt32(accessTime ?? 0)
            writer.writeUInt32(modificationTime ?? 0)
        }
        writer.writeUInt32(0) // extended count
    }

    init(from reader: inout SFTPReader) throws {
        let flags = try reader.readUInt32()
        if flags & Self.flagSize != 0 { size = try reader.readUInt64() }
        if flags & Self.flagUidGid != 0 {
            uid = try reader.readUInt32()
            gid = try reader.readUInt32()
        }
        if flags & Self.flagPermissions != 0 { permissions = try reader.readUInt32() }
        if flags & Self.flagACModTime != 0 {
            accessTime = try reader.readUInt32()
            modificationTime = try reader.readUInt32()
        }
        if flags & 0x8000_0000 != 0 {
            // Extended attributes; skip the advertised pairs.
            let count = try reader.readUInt32()
            for _ in 0..<count {
                _ = try reader.readString()
                _ = try reader.readString()
            }
        }
    }

    var modificationDate: Date? {
        guard let modificationTime else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(modificationTime))
    }
}

// MARK: - Responses

struct SFTPNameEntry {
    let filename: String
    let longName: String
    let attributes: SFTPAttributes
}

enum SFTPResponse {
    case status(UInt32, String)
    case handle(Data)
    case data(Data)
    case name([SFTPNameEntry])
    case attributes(SFTPAttributes)
}

enum SFTPError: LocalizedError {
    case malformedPacket(String)
    case protocolMismatch(UInt32)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .malformedPacket(let detail):
            return "The server sent a malformed SFTP packet (\(detail))."
        case .protocolMismatch(let version):
            return "The server only offered SFTP version \(version); this app needs version 3 or later."
        case .unexpectedResponse(let detail):
            return "Unexpected SFTP response: \(detail)."
        }
    }
}

extension SFTPResponse {
    /// Turns a status packet into a Swift error, or nil when it means success.
    static func error(fromStatus code: UInt32, message: String, path: String?) -> Error? {
        guard let status = SFTPStatusCode(rawValue: code) else {
            return RemoteClientError.server(
                message.isEmpty ? "Server reported SFTP status \(code)." : message
            )
        }
        switch status {
        case .ok, .eof:
            return nil
        case .noSuchFile:
            return RemoteClientError.pathNotFound(path ?? "the requested path")
        case .permissionDenied:
            return RemoteClientError.permissionDenied(path ?? "the requested path")
        case .opUnsupported:
            return RemoteClientError.unsupported("this operation")
        case .failure, .badMessage, .noConnection, .connectionLost:
            let detail = message.isEmpty ? "Operation failed on the server." : message
            return RemoteClientError.server(detail)
        }
    }
}
