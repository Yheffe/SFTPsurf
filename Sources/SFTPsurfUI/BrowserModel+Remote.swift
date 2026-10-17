import AppKit
import Foundation
import SwiftUI
import SFTPsurfCore

// MARK: - Session lifecycle

extension BrowserModel {
    public func savePreferences() {
        preferences.lastSortColumn = sortColumn.rawValue
        preferences.lastSortAscending = sortAscending
        preferencesStore.save(preferences)
    }

    public func reloadBookmarks() {
        bookmarks = bookmarkStore.sortedForDisplay()
    }

    public func setShowHiddenFiles(_ value: Bool) {
        preferences.showHiddenFiles = value
        savePreferences()
        refreshLocal()
        Task { await reloadRemote() }
    }

    private func makeClient(for profile: ConnectionProfile) -> any RemoteFileClient {
        switch profile.kind {
        case .sftp:
            return SFTPClient(displayName: profile.displayName)
        case .ftp:
            return FTPClient(displayName: profile.displayName)
        }
    }

    /// Starts a connection, prompting for a password first when one is needed.
    public func beginConnect(to profile: ConnectionProfile) {
        switch profile.authMethod {
        case .password:
            if let stored = keychain.password(for: profile.id) {
                Task { await connect(profile: profile, password: stored) }
            } else {
                passwordPrompt = PasswordPrompt(
                    profile: profile,
                    saveInKeychain: preferences.savePasswordsInKeychain
                )
            }
        case .privateKey, .agentAndDefaults:
            Task { await connect(profile: profile, password: nil) }
        }
    }

    public func submitPasswordPrompt() {
        guard var prompt = passwordPrompt else { return }
        prompt.message = nil
        if prompt.password.isEmpty {
            passwordPrompt = prompt
            passwordPrompt?.message = "Enter a password to continue."
            return
        }
        passwordPrompt = nil
        let profile = prompt.profile
        if prompt.saveInKeychain {
            keychain.setPassword(prompt.password, for: profile.id)
        }
        Task {
            await connect(profile: profile, password: prompt.password, isRetry: true)
        }
    }

    public func connect(
        profile: ConnectionProfile,
        password: String?,
        isRetry: Bool = false
    ) async {
        await disconnect(silently: true)

        session = .connecting
        busyMessage = "Connecting to \(profile.host)…"
        isBusy = true
        activeProfile = profile

        let client = makeClient(for: profile)
        do {
            try await client.connect(
                profile: profile,
                credential: Credential(password: password ?? keychain.password(for: profile.id))
            )

            self.client = client
            let home = (try? await client.homePath()) ?? "/"
            homePath = home

            transferQueue = TransferQueue(
                client: client,
                maxConcurrent: preferences.maxConcurrentTransfers,
                onUpdate: { [weak self] item in
                    Task { @MainActor in self?.apply(update: item) }
                }
            )

            session = .connected
            isBusy = false
            busyMessage = ""

            // Prefer the bookmark's start folder, then the server's home.
            let initial = profile.initialPath.isEmpty ? home : profile.initialPath
            remotePath = RemotePath.normalize(initial)

            bookmarkStore.markUsed(id: profile.id)
            reloadBookmarks()

            await reloadRemote(recordHistory: false)
        } catch {
            self.client = nil
            transferQueue = nil
            session = .failed(error.localizedDescription)
            isBusy = false
            busyMessage = ""

            reportConnectionFailure(error, profile: profile)
        }
    }

    private func reportConnectionFailure(_ error: Error, profile: ConnectionProfile) {
        let described = (error as? RemoteClientError)

        // Offer the password sheet again rather than making the user reopen it.
        if case .authenticationFailed = described {
            if case .password = profile.authMethod {
                keychain.deletePassword(for: profile.id)
                passwordPrompt = PasswordPrompt(
                    profile: profile,
                    saveInKeychain: preferences.savePasswordsInKeychain,
                    message: described?.errorDescription
                )
                return
            }
        }

        var message = error.localizedDescription
        if let suggestion = described?.recoverySuggestion {
            message += "\n\n\(suggestion)"
        }
        alert = AlertPayload(title: "Could not connect to \(profile.host)", message: message)
    }

    public func disconnect(silently: Bool = false) async {
        if let queue = transferQueue { await queue.cancelAll() }
        if let client { await client.disconnect() }
        client = nil
        transferQueue = nil
        session = .disconnected
        remoteEntries = []
        remoteSelection.removeAll()
        remotePath = ""
        remotePathField = ""
        remoteBack.removeAll()
        remoteForward.removeAll()
        activeProfile = nil
        if !silently { homePath = "/" }
    }
}

// MARK: - Remote navigation

extension BrowserModel {
    public func reloadRemote(recordHistory: Bool = true) async {
        guard let client, session.isConnected else { return }
        let target = remotePath.isEmpty ? homePath : remotePath
        isBusy = true
        busyMessage = "Loading \(target)…"
        defer {
            isBusy = false
            busyMessage = ""
        }

        do {
            let entries = try await client.list(target)
            remotePath = target
            remotePathField = target
            remoteEntries = entries
            remoteSelection = remoteSelection.filter { id in entries.contains { $0.id == id } }
        } catch {
            alert = AlertPayload(
                title: "Could not open \(target)",
                message: error.localizedDescription
            )
        }
    }

    public func navigateRemote(to path: String, recordHistory: Bool = true) async {
        guard session.isConnected else { return }
        let normalized = RemotePath.normalize(path)
        guard normalized != remotePath || remoteEntries.isEmpty else { return }

        if recordHistory {
            remoteBack.append(remotePath)
            remoteForward.removeAll()
        }
        remotePath = normalized
        await reloadRemote(recordHistory: false)
    }

    public func goUpRemote() async {
        if let parent = remoteParent { await navigateRemote(to: parent) }
    }

    public func goBackRemote() async {
        guard let previous = remoteBack.popLast() else { return }
        remoteForward.append(remotePath)
        remotePath = previous
        await reloadRemote(recordHistory: false)
    }

    public func goForwardRemote() async {
        guard let next = remoteForward.popLast() else { return }
        remoteBack.append(remotePath)
        remotePath = next
        await reloadRemote(recordHistory: false)
    }

    /// Double-click behaviour: descend into folders, download files.
    public func openRemoteSelection() {
        let selected = selectedRemoteEntries
        guard !selected.isEmpty else { return }

        if selected.count == 1, let entry = selected.first, entry.isDirectory {
            Task { await navigateRemote(to: entry.path) }
            return
        }
        download(entries: selected, thenOpen: true)
    }

    public func createRemoteFolder(named name: String) async {
        guard let client, session.isConnected else { return }
        let target = RemotePath.join(remotePath, name)
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.createDirectory(target)
            await reloadRemote()
            remoteSelection = [target]
        } catch {
            alert = AlertPayload(title: "Could not create folder", message: error.localizedDescription)
        }
    }

    public func renameRemote(_ entry: RemoteEntry, to newName: String) async {
        guard let client, session.isConnected else { return }
        let target = RemotePath.join(RemotePath.parent(of: entry.path) ?? remotePath, newName)
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.rename(entry.path, to: target)
            await reloadRemote()
            remoteSelection = [target]
        } catch {
            alert = AlertPayload(
                title: "Could not rename \(entry.name)",
                message: error.localizedDescription
            )
        }
    }

    public func renameLocal(_ url: URL, to newName: String) {
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            refreshLocal()
            localSelection = [target.path]
        } catch {
            alert = AlertPayload(title: "Could not rename item", message: error.localizedDescription)
        }
    }

    public func deleteRemoteEntries(_ entries: [RemoteEntry]) async {
        guard let client, session.isConnected, !entries.isEmpty else { return }
        isBusy = true
        busyMessage = "Deleting…"
        defer {
            isBusy = false
            busyMessage = ""
        }

        var failures: [String] = []
        for entry in entries {
            do {
                if entry.isDirectory {
                    try await removeRemoteDirectoryRecursively(client: client, path: entry.path)
                } else {
                    try await client.removeFile(entry.path)
                }
            } catch {
                failures.append("\(entry.name): \(error.localizedDescription)")
            }
        }

        await reloadRemote()
        if !failures.isEmpty {
            alert = AlertPayload(
                title: "Some items could not be deleted",
                message: failures.joined(separator: "\n")
            )
        }
    }

    /// SFTP and FTP both refuse to remove a non-empty directory, so empty it first.
    private func removeRemoteDirectoryRecursively(
        client: any RemoteFileClient,
        path: String
    ) async throws {
        let children = try await client.list(path)
        for child in children {
            if child.isDirectory {
                try await removeRemoteDirectoryRecursively(client: client, path: child.path)
            } else {
                try await client.removeFile(child.path)
            }
        }
        try await client.removeDirectory(path)
    }
}

// MARK: - Transfers

extension BrowserModel {
    public var hasTransferActivity: Bool {
        transfers.contains { !$0.state.isFinished }
    }

    public func apply(update item: TransferItem) {
        if let index = transfers.firstIndex(where: { $0.id == item.id }) {
            transfers[index] = item
        } else {
            transfers.append(item)
        }
        if !item.state.isFinished { showTransfers = true }
    }

    public func clearFinishedTransfers() {
        transfers.removeAll { $0.state.isFinished }
    }

    public func cancelTransfer(_ id: UUID) {
        guard let queue = transferQueue else { return }
        Task { await queue.cancel(id) }
    }

    public func cancelAllTransfers() {
        guard let queue = transferQueue else { return }
        Task { await queue.cancelAll() }
    }

    public func download(entries: [RemoteEntry], thenOpen: Bool = false) {
        guard let client, let queue = transferQueue, session.isConnected else { return }
        let destination = localDirectory
        let showHidden = preferences.showHiddenFiles

        Task {
            var requests: [TransferRequest] = []
            for entry in entries {
                requests += await Self.collectDownloads(
                    client: client,
                    entry: entry,
                    into: destination,
                    showHidden: showHidden
                )
            }
            await queue.enqueue(requests)

            if thenOpen, requests.count == 1, let only = requests.first {
                // Opening a freshly downloaded file is the expected behaviour on
                // double-click, and the transfer has to finish first.
                await queue.waitUntilIdle()
                NSWorkspace.shared.open(URL(fileURLWithPath: only.destinationPath))
            }
            refreshLocal()
        }
    }

    private static func collectDownloads(
        client: any RemoteFileClient,
        entry: RemoteEntry,
        into directory: URL,
        showHidden: Bool
    ) async -> [TransferRequest] {
        if !entry.isDirectory {
            let destination = LocalFileSystem.uniqueDestination(for: entry.name, in: directory)
            return [
                TransferRequest(
                    direction: .download,
                    sourcePath: entry.path,
                    destinationPath: destination.path,
                    totalBytes: entry.size
                )
            ]
        }

        let target = LocalFileSystem.uniqueDestination(for: entry.name, in: directory)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        guard let children = try? await client.list(entry.path) else { return [] }
        var requests: [TransferRequest] = []
        for child in children {
            requests += await collectDownloads(
                client: client,
                entry: child,
                into: target,
                showHidden: showHidden
            )
        }
        return requests
    }

    /// Downloads items identified only by their remote path, which is what a
    /// drag from the remote pane onto the local pane provides.
    public func downloadRemotePaths(_ paths: [String]) {
        let entries = paths.map { path -> RemoteEntry in
            remoteEntries.first { $0.path == path }
                ?? RemoteEntry(
                    name: RemotePath.lastComponent(of: path),
                    path: path,
                    isDirectory: false
                )
        }
        download(entries: entries)
    }

    public func upload(entries: [LocalEntry]) {
        guard let client, let queue = transferQueue, session.isConnected else { return }
        let remoteDirectory = remotePath
        let showHidden = preferences.showHiddenFiles

        Task {
            var requests: [TransferRequest] = []
            for entry in entries {
                requests += await Self.collectUploads(
                    client: client,
                    url: entry.url,
                    name: entry.name,
                    into: remoteDirectory,
                    showHidden: showHidden
                )
            }
            await queue.enqueue(requests)
        }
    }

    private static func collectUploads(
        client: any RemoteFileClient,
        url: URL,
        name: String,
        into remoteDirectory: String,
        showHidden: Bool
    ) async -> [TransferRequest] {
        guard LocalFileSystem.isDirectory(url) else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let destination = await uniqueRemotePath(
                client: client,
                desired: RemotePath.join(remoteDirectory, name)
            )
            return [
                TransferRequest(
                    direction: .upload,
                    sourcePath: url.path,
                    destinationPath: destination,
                    totalBytes: size
                )
            ]
        }

        let desired = RemotePath.join(remoteDirectory, name)
        let target = await uniqueRemotePath(client: client, desired: desired)
        do {
            try await client.createDirectory(target)
        } catch {
            return []
        }

        var requests: [TransferRequest] = []
        let children = (try? LocalFileSystem.list(url, showHidden: showHidden)) ?? []
        for child in children.sorted(by: LocalFileSystem.sortByName) {
            requests += await collectUploads(
                client: client,
                url: child.url,
                name: child.name,
                into: target,
                showHidden: showHidden
            )
        }
        return requests
    }

    /// Picks a name that is not already taken on the server.
    private static func uniqueRemotePath(
        client: any RemoteFileClient,
        desired: String
    ) async -> String {
        // No attributes means nothing is there, so the name is free.
        let existing: RemoteEntry? = try? await client.attributes(of: desired)
        guard existing != nil else { return desired }
        let directory = RemotePath.parent(of: desired) ?? "/"
        let name = RemotePath.lastComponent(of: desired)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while counter < 10_000 {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let path = RemotePath.join(directory, candidate)
            if (try? await client.attributes(of: path)) == nil { return path }
            counter += 1
        }
        return desired
    }

    /// Drag-and-drop inside the remote pane, implemented as a server-side move.
    public func moveRemote(paths: [String], into destinationDirectory: String) async {
        guard let client, session.isConnected, !paths.isEmpty else { return }
        isBusy = true
        busyMessage = "Moving…"
        defer {
            isBusy = false
            busyMessage = ""
        }

        var failures: [String] = []
        for path in paths {
            let name = RemotePath.lastComponent(of: path)
            guard let parent = RemotePath.parent(of: path) else { continue }
            let desired = RemotePath.join(destinationDirectory, name)
            // Dropping an item back where it came from is a no-op, not an error.
            if RemotePath.normalize(parent) == RemotePath.normalize(destinationDirectory) { continue }

            do {
                let target = await Self.uniqueRemotePath(client: client, desired: desired)
                try await client.rename(path, to: target)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }

        await reloadRemote()
        if !failures.isEmpty {
            alert = AlertPayload(title: "Some items could not be moved", message: failures.joined(separator: "\n"))
        }
    }
}
