import AppKit
import Foundation
import SwiftUI
import SFTPsurfCore

/// Everything the window needs: both panes, the session, bookmarks and the
/// transfer queue.
@MainActor
public final class BrowserModel: ObservableObject {
    // MARK: - Local pane

    @Published public var localDirectory: URL
    @Published public var localEntries: [LocalEntry] = []
    @Published public var localSelection: Set<String> = []
    @Published public var localPathField: String = ""
    public var localBack: [URL] = []
    public var localForward: [URL] = []

    // MARK: - Remote pane

    @Published public var remotePath: String = ""
    @Published public var remoteEntries: [RemoteEntry] = []
    @Published public var remoteSelection: Set<String> = []
    @Published public var remotePathField: String = ""
    public var remoteBack: [String] = []
    public var remoteForward: [String] = []

    // MARK: - Session

    @Published public var session: SessionState = .disconnected
    @Published public var activeProfile: ConnectionProfile?
    @Published public var homePath: String = "/"
    @Published public var isBusy = false
    @Published public var busyMessage = ""

    // MARK: - Bookmarks and preferences

    @Published public var bookmarks: [ConnectionProfile] = []
    @Published public var preferences: Preferences
    @Published public var filterText = ""
    @Published public var sortColumn: SortColumn = .name
    @Published public var sortAscending = true

    // MARK: - Transfers

    @Published public var transfers: [TransferItem] = []
    @Published public var showTransfers = false

    // MARK: - Presentation

    @Published public var alert: AlertPayload?
    @Published public var connectionSheet: ConnectionSheetMode?
    @Published public var passwordPrompt: PasswordPrompt?
    @Published public var pendingDeletion: PendingDeletion?
    @Published public var pendingRename: RenamePrompt?
    @Published public var pendingNewFolder: NewFolderPrompt?

    public struct ConnectionSheetMode: Identifiable {
        public let id = UUID()
        public var profile: ConnectionProfile
        public var isNew: Bool

        public init(profile: ConnectionProfile, isNew: Bool) {
            self.profile = profile
            self.isNew = isNew
        }
    }

    public struct PasswordPrompt: Identifiable {
        public let id = UUID()
        public let profile: ConnectionProfile
        public var password: String = ""
        public var saveInKeychain = true
        public var message: String?

        public init(
            profile: ConnectionProfile,
            password: String = "",
            saveInKeychain: Bool = true,
            message: String? = nil
        ) {
            self.profile = profile
            self.password = password
            self.saveInKeychain = saveInKeychain
            self.message = message
        }
    }

    /// A destructive action awaiting confirmation.
    public struct PendingDeletion: Identifiable {
        public enum Target {
            case local([LocalEntry])
            case remote([RemoteEntry])
        }

        public let id = UUID()
        public let target: Target

        public init(target: Target) {
            self.target = target
        }

        public var names: [String] {
            switch target {
            case .local(let entries): return entries.map(\.name)
            case .remote(let entries): return entries.map(\.name)
            }
        }
    }

    public struct RenamePrompt: Identifiable {
        public enum Target {
            case local(URL)
            case remote(RemoteEntry)
        }

        public let id = UUID()
        public let target: Target
        public let originalName: String
        public var newName: String

        public init(target: Target, originalName: String, newName: String) {
            self.target = target
            self.originalName = originalName
            self.newName = newName
        }
    }

    public struct NewFolderPrompt: Identifiable {
        public enum Target {
            case local
            case remote
        }

        public let id = UUID()
        public let target: Target
        public var name = "untitled folder"

        public init(target: Target, name: String = "untitled folder") {
            self.target = target
            self.name = name
        }
    }

    // MARK: - Collaborators

    public var client: (any RemoteFileClient)?
    public var transferQueue: TransferQueue?
    public let bookmarkStore: BookmarkStore
    public let preferencesStore: PreferencesStore
    public let keychain: KeychainStore

    public init(
        bookmarkStore: BookmarkStore = BookmarkStore(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        keychain: KeychainStore = .shared
    ) {
        self.bookmarkStore = bookmarkStore
        self.preferencesStore = preferencesStore
        self.keychain = keychain

        let stored = preferencesStore.current()
        self.preferences = stored
        self.sortColumn = SortColumn(rawValue: stored.lastSortColumn) ?? .name
        self.sortAscending = stored.lastSortAscending

        let savedLocal = URL(fileURLWithPath: stored.lastLocalDirectory)
        let start = LocalFileSystem.isDirectory(savedLocal) ? savedLocal : LocalFileSystem.home
        self.localDirectory = start
        self.localPathField = start.path

        self.bookmarks = bookmarkStore.sortedForDisplay()

        refreshLocal()
    }

    // MARK: - Derived listings

    public var displayedRemoteEntries: [RemoteEntry] {
        // Servers list dotfiles whether or not the user wants to see them, so
        // hide them here to match the local pane.
        var visible = preferences.showHiddenFiles
            ? remoteEntries
            : remoteEntries.filter { !$0.name.hasPrefix(".") }
        if !filterText.isEmpty {
            visible = visible.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        }
        return sorted(visible)
    }

    public var displayedLocalEntries: [LocalEntry] {
        let filtered = filterText.isEmpty
            ? localEntries
            : localEntries.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        return sorted(filtered)
    }

    private func sorted(_ entries: [RemoteEntry]) -> [RemoteEntry] {
        let result = entries.sorted { lhs, rhs in
            // Directories stay above files regardless of the sort column.
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch sortColumn {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                return lhs.size < rhs.size
            case .modified:
                return (lhs.modified ?? .distantPast) < (rhs.modified ?? .distantPast)
            case .kind:
                return (lhs.name as NSString).pathExtension
                    .localizedStandardCompare((rhs.name as NSString).pathExtension) == .orderedAscending
            }
        }
        return sortAscending ? result : result.reversed()
    }

    private func sorted(_ entries: [LocalEntry]) -> [LocalEntry] {
        let result = entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch sortColumn {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                return lhs.size < rhs.size
            case .modified:
                return (lhs.modified ?? .distantPast) < (rhs.modified ?? .distantPast)
            case .kind:
                return (lhs.name as NSString).pathExtension
                    .localizedStandardCompare((rhs.name as NSString).pathExtension) == .orderedAscending
            }
        }
        return sortAscending ? result : result.reversed()
    }

    public var selectedLocalEntry: LocalEntry? {
        guard localSelection.count == 1, let id = localSelection.first else { return nil }
        return localEntries.first { $0.id == id }
    }

    public var selectedRemoteEntry: RemoteEntry? {
        guard remoteSelection.count == 1, let id = remoteSelection.first else { return nil }
        return remoteEntries.first { $0.id == id }
    }

    public var selectedLocalEntries: [LocalEntry] {
        localEntries.filter { localSelection.contains($0.id) }
    }

    public var selectedRemoteEntries: [RemoteEntry] {
        remoteEntries.filter { remoteSelection.contains($0.id) }
    }

    public var canGoBackLocal: Bool { !localBack.isEmpty }
    public var canGoForwardLocal: Bool { !localForward.isEmpty }
    public var canGoBackRemote: Bool { !remoteBack.isEmpty }
    public var canGoForwardRemote: Bool { !remoteForward.isEmpty }

    public var localParent: URL? {
        let parent = localDirectory.deletingLastPathComponent()
        return parent.path == localDirectory.path ? nil : parent
    }

    public var remoteParent: String? { RemotePath.parent(of: remotePath) }
}

// MARK: - Local pane

extension BrowserModel {
    public func refreshLocal() {
        do {
            localEntries = try LocalFileSystem.list(
                localDirectory,
                showHidden: preferences.showHiddenFiles
            )
            localSelection = localSelection.filter { id in localEntries.contains { $0.id == id } }
            localPathField = localDirectory.path
        } catch {
            localEntries = []
            alert = AlertPayload(
                title: "Cannot open folder",
                message: "“\(localDirectory.lastPathComponent)” could not be read. \(error.localizedDescription)"
            )
        }
    }

    public func navigateLocal(to url: URL, recordHistory: Bool = true) {
        let standardized = url.standardizedFileURL
        guard LocalFileSystem.isDirectory(standardized) else {
            alert = AlertPayload(
                title: "Not a folder",
                message: "“\(standardized.lastPathComponent)” is a file."
            )
            return
        }
        if recordHistory, standardized != localDirectory {
            localBack.append(localDirectory)
            localForward.removeAll()
        }
        localDirectory = standardized
        localSelection.removeAll()
        preferences.lastLocalDirectory = standardized.path
        savePreferences()
        refreshLocal()
    }

    public func goUpLocal() {
        if let parent = localParent { navigateLocal(to: parent) }
    }

    public func goBackLocal() {
        guard let previous = localBack.popLast() else { return }
        localForward.append(localDirectory)
        navigateLocal(to: previous, recordHistory: false)
    }

    public func goForwardLocal() {
        guard let next = localForward.popLast() else { return }
        localBack.append(localDirectory)
        navigateLocal(to: next, recordHistory: false)
    }

    public func openLocalSelection() {
        for entry in selectedLocalEntries where entry.isDirectory {
            navigateLocal(to: entry.url)
            return
        }
        revealInFinder(selectedLocalEntries)
    }

    public func revealInFinder(_ entries: [LocalEntry]) {
        let urls = entries.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    public func openLocalExternally(_ entries: [LocalEntry]) {
        for url in entries.map(\.url) {
            NSWorkspace.shared.open(url)
        }
    }

    public func createLocalFolder() {
        pendingNewFolder = NewFolderPrompt(target: .local, name: "untitled folder")
    }

    /// Moves the given local entries to the Trash.
    public func trashLocalEntries(_ entries: [LocalEntry]) {
        var failures: [String] = []
        for entry in entries {
            do {
                try LocalFileSystem.moveToTrash(entry.url)
            } catch {
                failures.append("\(entry.name): \(error.localizedDescription)")
            }
        }
        refreshLocal()
        if !failures.isEmpty {
            alert = AlertPayload(
                title: "Some items could not be deleted",
                message: failures.joined(separator: "\n")
            )
        }
    }

    // MARK: - Confirmation helpers

    public func requestLocalTrash(_ entries: [LocalEntry]) {
        guard !entries.isEmpty else { return }
        if preferences.confirmBeforeDelete {
            pendingDeletion = PendingDeletion(target: .local(entries))
        } else {
            trashLocalEntries(entries)
        }
    }

    public func requestRemoteDeletion(_ entries: [RemoteEntry]) {
        guard !entries.isEmpty else { return }
        if preferences.confirmBeforeDelete {
            pendingDeletion = PendingDeletion(target: .remote(entries))
        } else {
            Task { await deleteRemoteEntries(entries) }
        }
    }

    /// Completes whatever the confirmation dialog was waiting on.
    public func confirmPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        switch pending.target {
        case .local(let entries):
            trashLocalEntries(entries)
        case .remote(let entries):
            Task { await deleteRemoteEntries(entries) }
        }
    }

    public func confirmPendingRename() {
        guard let pending = pendingRename else { return }
        pendingRename = nil
        let trimmed = pending.newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != pending.originalName else { return }

        switch pending.target {
        case .local(let url):
            renameLocal(url, to: trimmed)
        case .remote(let entry):
            Task { await renameRemote(entry, to: trimmed) }
        }
    }

    public func confirmPendingNewFolder() {
        guard let pending = pendingNewFolder else { return }
        pendingNewFolder = nil
        let trimmed = pending.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch pending.target {
        case .local:
            do {
                let created = try LocalFileSystem.createFolder(named: trimmed, in: localDirectory)
                refreshLocal()
                localSelection = [created.path]
            } catch {
                alert = AlertPayload(title: "Could not create folder", message: error.localizedDescription)
            }
        case .remote:
            Task { await createRemoteFolder(named: trimmed) }
        }
    }
}
