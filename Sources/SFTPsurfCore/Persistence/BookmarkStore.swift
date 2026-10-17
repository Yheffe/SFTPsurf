import Foundation

/// The saved connection list, persisted as JSON in Application Support.
public final class BookmarkStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var cached: [ConnectionProfile] = []
    private var loaded = false

    public init(fileURL: URL = AppPaths.bookmarksFile) {
        self.fileURL = fileURL
    }

    /// Reading is lazy so the app can start without touching the disk.
    public func all() -> [ConnectionProfile] {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            cached = Self.read(from: fileURL)
            loaded = true
        }
        return cached
    }

    public func bookmark(id: UUID) -> ConnectionProfile? {
        all().first { $0.id == id }
    }

    @discardableResult
    public func add(_ profile: ConnectionProfile) -> ConnectionProfile {
        lock.lock()
        if !loaded {
            cached = Self.read(from: fileURL)
            loaded = true
        }
        cached.append(profile)
        let snapshot = cached
        lock.unlock()
        Self.write(snapshot, to: fileURL)
        return profile
    }

    @discardableResult
    public func update(_ profile: ConnectionProfile) -> Bool {
        lock.lock()
        if !loaded {
            cached = Self.read(from: fileURL)
            loaded = true
        }
        guard let index = cached.firstIndex(where: { $0.id == profile.id }) else {
            lock.unlock()
            return false
        }
        cached[index] = profile
        let snapshot = cached
        lock.unlock()
        Self.write(snapshot, to: fileURL)
        return true
    }

    /// Adds the profile if it is new, otherwise replaces the existing entry.
    public func upsert(_ profile: ConnectionProfile) {
        if !update(profile) { add(profile) }
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        lock.lock()
        if !loaded {
            cached = Self.read(from: fileURL)
            loaded = true
        }
        let originalCount = cached.count
        cached.removeAll { $0.id == id }
        let removed = cached.count != originalCount
        let snapshot = cached
        lock.unlock()
        if removed { Self.write(snapshot, to: fileURL) }
        return removed
    }

    /// Records that a bookmark was opened, so the sidebar can order by recency.
    public func markUsed(id: UUID, at date: Date = Date()) {
        lock.lock()
        if !loaded {
            cached = Self.read(from: fileURL)
            loaded = true
        }
        guard let index = cached.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        cached[index].lastUsedAt = date
        let snapshot = cached
        lock.unlock()
        Self.write(snapshot, to: fileURL)
    }

    /// Bookmarks ordered for display: most recently used first, then alphabetical.
    public func sortedForDisplay() -> [ConnectionProfile] {
        all().sorted { lhs, rhs in
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    // MARK: - Disk

    private static func read(from url: URL) -> [ConnectionProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([ConnectionProfile].self, from: data)
        } catch {
            // A corrupted or older file should not stop the app from starting.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    private static func write(_ profiles: [ConnectionProfile], to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic so a crash mid-write cannot truncate the bookmark list.
            try data.write(to: url, options: [.atomic])
        } catch {
            // Losing a bookmark is not worth crashing over; the UI still works.
        }
    }
}

/// Small set of user preferences that survive relaunches.
public struct Preferences: Codable, Sendable, Equatable {
    public var showHiddenFiles: Bool
    public var confirmBeforeDelete: Bool
    public var savePasswordsInKeychain: Bool
    public var maxConcurrentTransfers: Int
    public var lastLocalDirectory: String
    public var lastSortColumn: String
    public var lastSortAscending: Bool

    public init(
        showHiddenFiles: Bool = false,
        confirmBeforeDelete: Bool = true,
        savePasswordsInKeychain: Bool = true,
        maxConcurrentTransfers: Int = 3,
        lastLocalDirectory: String = NSHomeDirectory(),
        lastSortColumn: String = "name",
        lastSortAscending: Bool = true
    ) {
        self.showHiddenFiles = showHiddenFiles
        self.confirmBeforeDelete = confirmBeforeDelete
        self.savePasswordsInKeychain = savePasswordsInKeychain
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.lastLocalDirectory = lastLocalDirectory
        self.lastSortColumn = lastSortColumn
        self.lastSortAscending = lastSortAscending
    }
}

/// Loads and saves `Preferences`.
public final class PreferencesStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var cached: Preferences?

    public init(fileURL: URL = AppPaths.preferencesFile) {
        self.fileURL = fileURL
    }

    public func current() -> Preferences {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded: Preferences
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
            loaded = decoded
        } else {
            loaded = Preferences()
        }
        cached = loaded
        return loaded
    }

    public func save(_ preferences: Preferences) {
        lock.lock()
        cached = preferences
        let url = fileURL
        lock.unlock()

        guard let data = try? JSONEncoder().encode(preferences) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }
}
