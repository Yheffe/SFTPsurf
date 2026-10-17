import Foundation

/// A single entry (file, directory, or symlink) in a remote listing.
public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let size: Int64
    public let modified: Date?
    /// POSIX mode bits (e.g. 0o644), when the server reports them.
    public let permissions: UInt32?
    public let owner: String?
    public let group: String?

    public var id: String { path }

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        size: Int64 = 0,
        modified: Date? = nil,
        permissions: UInt32? = nil,
        owner: String? = nil,
        group: String? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.group = group
    }

    /// Recognises the directory bit in POSIX mode bits.
    public static let directoryModeBit: UInt32 = 0o040000
    public static let symlinkModeBit: UInt32 = 0o120000

    /// Renders mode bits as `drwxr-xr-x`, matching what `ls -l` shows.
    public var permissionString: String? {
        guard let permissions else { return nil }
        let type: Character
        switch permissions & 0o170000 {
        case RemoteEntry.directoryModeBit: type = "d"
        case RemoteEntry.symlinkModeBit: type = "l"
        default: type = "-"
        }
        let chars = Array("rwxrwxrwx")
        var result = String(type)
        for bit in 0..<9 {
            let mask = UInt32(1) << (8 - bit)
            result.append(permissions & mask != 0 ? chars[bit] : "-")
        }
        return result
    }
}

extension RemoteEntry {
    /// Comparison used by the browser. Directories always sort above files.
    public static func sortByName(_ lhs: RemoteEntry, _ rhs: RemoteEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
