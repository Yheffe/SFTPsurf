import Foundation

/// One row in the local pane.
public struct LocalEntry: Identifiable, Hashable, Sendable {
    public let name: String
    public let url: URL
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let size: Int64
    public let modified: Date?

    public var id: String { url.path }

    public init(
        name: String,
        url: URL,
        isDirectory: Bool,
        isSymlink: Bool = false,
        size: Int64 = 0,
        modified: Date? = nil
    ) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
    }
}

/// Read and write access to the machine's own filesystem.
public enum LocalFileSystem {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    public static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Downloads")
    }

    public static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Desktop")
    }

    public static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Documents")
    }

    /// Volumes currently mounted under `/Volumes`, for the sidebar.
    public static func mountedVolumes() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Lists a directory. Symlinks are reported as links but are not followed,
    /// which matches how the remote pane behaves.
    public static func list(_ directory: URL, showHidden: Bool) throws -> [LocalEntry] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .nameKey,
        ]

        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options.union(.skipsSubdirectoryDescendants)
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var entries: [LocalEntry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // `enumerator` follows symlinks to directories; doing the same in the
            // browser would make them indistinguishable from real folders.
            let isDirectory = values.isDirectory ?? false
            entries.append(
                LocalEntry(
                    name: values.name ?? url.lastPathComponent,
                    url: url,
                    isDirectory: isDirectory,
                    isSymlink: values.isSymbolicLink ?? false,
                    size: Int64(values.fileSize ?? 0),
                    modified: values.contentModificationDate
                )
            )
        }

        return entries.sorted(by: sortByName)
    }

    /// Directories first, then a Finder-like natural ordering.
    public static func sortByName(_ lhs: LocalEntry, _ rhs: LocalEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// A non-colliding destination, appending " 2", " 3", … like Finder does.
    public static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let extensionPart = (name as NSString).pathExtension
        var counter = 2
        while counter < 10_000 {
            let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
            let candidateName = "\(base) \(counter)\(suffix)"
            candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
        return candidate
    }

    /// Creates a folder, avoiding collisions.
    @discardableResult
    public static func createFolder(named name: String, in directory: URL) throws -> URL {
        let destination = uniqueDestination(for: name, in: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    /// Moves a file or folder to the Trash, matching Finder's Delete behaviour.
    public static func moveToTrash(_ url: URL) throws {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }

    /// True when the path exists and is a directory, following symlinks.
    public static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
