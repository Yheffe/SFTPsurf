import SwiftUI
import SFTPsurfCore

/// The local half of the window: navigation strip plus a listing.
struct LocalPaneView: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var pathFieldFocused: Bool

    @State private var paneWidth: CGFloat = 0

    private var plan: ColumnPlan {
        paneWidth > 0 ? ColumnLayout().plan(for: paneWidth) : .widest
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationStrip
            ListingHeader(
                plan: plan,
                sortColumn: $model.sortColumn,
                sortAscending: $model.sortAscending,
                onChange: { model.savePreferences() }
            )
            listing
        }
        .measuringWidth { paneWidth = $0 }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var navigationStrip: some View {
        HStack(spacing: 6) {
            Button {
                model.goBackLocal()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canGoBackLocal)
            .help("Back")

            Button {
                model.goForwardLocal()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!model.canGoForwardLocal)
            .help("Forward")

            Button {
                model.goUpLocal()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(model.localParent == nil)
            .help("Enclosing folder")

            PathField(
                placeholder: "Local path",
                text: $model.localPathField,
                onSubmit: {
                    let candidate = URL(fileURLWithPath: (model.localPathField as NSString).expandingTildeInPath)
                    model.navigateLocal(to: candidate)
                }
            )
            .focused($pathFieldFocused)
            .frame(minWidth: 120)

            Button {
                model.refreshLocal()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload this folder")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var listing: some View {
        Group {
            if model.localEntries.isEmpty {
                PaneMessage(
                    symbol: "folder",
                    title: "This folder is empty",
                    subtitle: model.filterText.isEmpty
                        ? nil
                        : "No items match “\(model.filterText)”."
                )
            } else {
                List(selection: $model.localSelection) {
                    ForEach(model.displayedLocalEntries) { entry in
                        EntryRow(
                            plan: plan,
                            name: entry.name,
                            isDirectory: entry.isDirectory,
                            isSymlink: entry.isSymlink,
                            size: entry.size,
                            modified: entry.modified,
                            detail: nil
                        )
                        .tag(entry.id)
                        .draggable(entry.url)
                        .onTapGesture(count: 2) {
                            if entry.isDirectory {
                                model.navigateLocal(to: entry.url)
                            } else {
                                NSWorkspace.shared.open(entry.url)
                            }
                        }
                        .contextMenu {
                            localContextMenu(for: entry)
                        }
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
        // Dropping remote items here downloads them.
        .dropDestination(for: RemoteDragPayload.self) { payloads, _ in
            let paths = payloads.flatMap(\.paths)
            guard !paths.isEmpty else { return false }
            model.downloadRemotePaths(paths)
            return true
        }
    }

    @ViewBuilder
    private func localContextMenu(for entry: LocalEntry) -> some View {
        Button("Open") {
            if entry.isDirectory {
                model.navigateLocal(to: entry.url)
            } else {
                NSWorkspace.shared.open(entry.url)
            }
        }
        Button("Reveal in Finder") {
            model.revealInFinder([entry])
        }

        Divider()

        Button("Upload to “\(model.activeProfile?.displayName ?? "server")”") {
            model.upload(entries: [entry])
        }
        .disabled(!model.session.isConnected)

        Divider()

        Button("Rename…") {
            model.pendingRename = .init(
                target: .local(entry.url),
                originalName: entry.name,
                newName: entry.name
            )
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.path, forType: .string)
        }

        Divider()

        Button("Move to Trash") {
            model.requestLocalTrash([entry])
        }
    }
}

/// The remote half of the window.
struct RemotePaneView: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var pathFieldFocused: Bool

    @State private var paneWidth: CGFloat = 0

    private var plan: ColumnPlan {
        paneWidth > 0 ? ColumnLayout().plan(for: paneWidth) : .widest
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationStrip
            content
        }
        .measuringWidth { paneWidth = $0 }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var navigationStrip: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.goBackRemote() }
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canGoBackRemote)
            .help("Back")

            Button {
                Task { await model.goForwardRemote() }
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!model.canGoForwardRemote)
            .help("Forward")

            Button {
                Task { await model.goUpRemote() }
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(model.remoteParent == nil || !model.session.isConnected)
            .help("Parent folder")

            PathField(
                placeholder: "Remote path",
                text: $model.remotePathField,
                onSubmit: {
                    Task { await model.navigateRemote(to: model.remotePathField) }
                }
            )
            .focused($pathFieldFocused)
            .frame(minWidth: 120)

            if !model.session.isConnected {
                Button {
                    model.connectionSheet = .init(profile: ConnectionProfile(), isNew: true)
                } label: {
                    Image(systemName: "bolt.horizontal.circle")
                }
                .help("Connect to a server")
            }

            Button {
                Task { await model.reloadRemote() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!model.session.isConnected)
            .help("Reload this folder")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var content: some View {
        switch model.session {
        case .disconnected:
            PaneMessage(
                symbol: "network",
                title: "Not connected",
                subtitle: "Choose a bookmark from the sidebar, or add a new connection.",
                action: (
                    title: "New Connection…",
                    run: { model.connectionSheet = .init(profile: ConnectionProfile(), isNew: true) }
                )
            )

        case .connecting:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(model.busyMessage.isEmpty ? "Connecting…" : model.busyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            PaneMessage(
                symbol: "exclamationmark.triangle",
                title: "Could not connect",
                subtitle: message,
                action: (
                    title: "Try Again",
                    run: {
                        if let profile = model.activeProfile { model.beginConnect(to: profile) }
                    }
                )
            )

        case .connected:
            ListingHeader(
                plan: plan,
                sortColumn: $model.sortColumn,
                sortAscending: $model.sortAscending,
                onChange: { model.savePreferences() }
            )
            listing
        }
    }

    private var listing: some View {
        Group {
            if model.remoteEntries.isEmpty {
                PaneMessage(
                    symbol: "folder",
                    title: "This folder is empty",
                    subtitle: model.filterText.isEmpty
                        ? nil
                        : "No items match “\(model.filterText)”."
                )
            } else {
                List(selection: $model.remoteSelection) {
                    ForEach(model.displayedRemoteEntries) { entry in
                        EntryRow(
                            plan: plan,
                            name: entry.name,
                            isDirectory: entry.isDirectory,
                            isSymlink: entry.isSymlink,
                            size: entry.size,
                            modified: entry.modified,
                            detail: entry.permissionString
                        )
                        .tag(entry.id)
                        .draggable(RemoteDragPayload(paths: [entry.path]))
                        .onTapGesture(count: 2) {
                            if entry.isDirectory {
                                Task { await model.navigateRemote(to: entry.path) }
                            } else {
                                model.download(entries: [entry], thenOpen: true)
                            }
                        }
                        .contextMenu {
                            remoteContextMenu(for: entry)
                        }
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
        // Dropping Finder files here uploads them.
        .dropDestination(for: URL.self) { urls, _ in
            let entries = urls.map { url in
                LocalEntry(
                    name: url.lastPathComponent,
                    url: url,
                    isDirectory: LocalFileSystem.isDirectory(url)
                )
            }
            guard !entries.isEmpty else { return false }
            model.upload(entries: entries)
            return true
        }
        // Dropping remote items moves them within the server.
        .dropDestination(for: RemoteDragPayload.self) { payloads, _ in
            let paths = payloads.flatMap(\.paths)
            guard !paths.isEmpty else { return false }
            Task { await model.moveRemote(paths: paths, into: model.remotePath) }
            return true
        }
    }

    @ViewBuilder
    private func remoteContextMenu(for entry: RemoteEntry) -> some View {
        Button("Open") {
            if entry.isDirectory {
                Task { await model.navigateRemote(to: entry.path) }
            } else {
                model.download(entries: [entry], thenOpen: true)
            }
        }

        Divider()

        Button("Download to “\(model.localDirectory.lastPathComponent)”") {
            model.download(entries: [entry])
        }

        Divider()

        Button("Rename…") {
            model.pendingRename = .init(
                target: .remote(entry),
                originalName: entry.name,
                newName: entry.name
            )
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }

        Divider()

        Button("Delete", role: .destructive) {
            model.requestRemoteDeletion([entry])
        }
    }
}
