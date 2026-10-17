import SwiftUI
import SFTPsurfCore

public struct ContentView: View {
    @EnvironmentObject private var model: BrowserModel

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 320)
        } detail: {
            VStack(spacing: 0) {
                HSplitView {
                    LocalPaneView(model: model)
                        .frame(minWidth: 320)
                    RemotePaneView(model: model)
                        .frame(minWidth: 320)
                }
                .frame(maxHeight: .infinity)

                if model.showTransfers {
                    Divider()
                    TransfersPanel(model: model)
                        .frame(height: 150)
                }

                Divider()
                StatusBarView(model: model)
            }
            .navigationTitle(model.activeProfile?.displayName ?? "SFTPsurf")
            .navigationSubtitle(model.session.isConnected ? model.remotePath : "")
            .toolbar { toolbar }
        }
        .frame(minWidth: 900, idealWidth: 1180, minHeight: 520, idealHeight: 760)
        .sheet(item: $model.connectionSheet) { mode in
            ConnectionSheet(model: model, mode: mode)
        }
        .sheet(item: $model.passwordPrompt) { prompt in
            PasswordPromptSheet(model: model, prompt: prompt)
        }
        .sheet(item: $model.pendingRename) { prompt in
            RenameSheet(model: model, prompt: prompt)
        }
        .sheet(item: $model.pendingNewFolder) { prompt in
            NewFolderSheet(model: model, prompt: prompt)
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: presence(of: \.alert),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { payload in
            Text(payload.message)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: presence(of: \.pendingDeletion),
            presenting: model.pendingDeletion
        ) { _ in
            Button("Delete", role: .destructive) { model.confirmPendingDeletion() }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(deletionMessage(for: pending))
        }
    }

    /// Bridges an optional model property to the `isPresented` binding SwiftUI wants.
    private func presence<T>(
        of keyPath: ReferenceWritableKeyPath<BrowserModel, T?>
    ) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] != nil },
            set: { shown in if !shown { model[keyPath: keyPath] = nil } }
        )
    }

    private var deletionTitle: String {
        guard let pending = model.pendingDeletion else { return "Delete" }
        return pending.names.count == 1
            ? "Delete “\(pending.names[0])”?"
            : "Delete \(pending.names.count) items?"
    }

    private func deletionMessage(for pending: BrowserModel.PendingDeletion) -> String {
        switch pending.target {
        case .local:
            return "The selected items will be moved to the Trash."
        case .remote:
            return "Folders are deleted with everything inside them. This cannot be undone."
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.connectionSheet = BrowserModel.ConnectionSheetMode(
                    profile: ConnectionProfile(),
                    isNew: true
                )
            } label: {
                Label("New Connection", systemImage: "plus")
            }
            .help("Add a new connection")
        }

        ToolbarItemGroup {
            Button {
                Task {
                    if model.session.isConnected {
                        await model.disconnect()
                    } else if let profile = model.activeProfile {
                        model.beginConnect(to: profile)
                    } else {
                        model.connectionSheet = BrowserModel.ConnectionSheetMode(
                            profile: ConnectionProfile(),
                            isNew: true
                        )
                    }
                }
            } label: {
                Label(
                    model.session.isConnected ? "Disconnect" : "Connect",
                    systemImage: model.session.isConnected
                        ? "bolt.slash"
                        : "bolt.horizontal"
                )
            }
            .help(model.session.isConnected ? "Disconnect" : "Connect")

            Button {
                model.pendingNewFolder = BrowserModel.NewFolderPrompt(target: .remote)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!model.session.isConnected)
            .help("Create a folder on the server")

            Button {
                model.download(entries: model.selectedRemoteEntries)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(model.remoteSelection.isEmpty || !model.session.isConnected)
            .help("Download the selection")

            Button {
                model.upload(entries: model.selectedLocalEntries)
            } label: {
                Label("Upload", systemImage: "arrow.up.circle")
            }
            .disabled(model.localSelection.isEmpty || !model.session.isConnected)
            .help("Upload the selection")

            Button {
                model.requestRemoteDeletion(model.selectedRemoteEntries)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.remoteSelection.isEmpty || !model.session.isConnected)
            .help("Delete the selection on the server")

            Button {
                model.showTransfers.toggle()
            } label: {
                Label(
                    "Transfers",
                    systemImage: model.hasTransferActivity
                        ? "arrow.up.arrow.down.circle.fill"
                        : "arrow.up.arrow.down.circle"
                )
            }
            .help("Show or hide the transfer queue")
        }

        ToolbarItem(placement: .automatic) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Filter", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .frame(width: 130)
                if !model.filterText.isEmpty {
                    Button {
                        model.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Bookmarks and local places.
struct SidebarView: View {
    @ObservedObject var model: BrowserModel

    private var favourites: [(String, String, URL)] {
        [
            ("Home", "house", LocalFileSystem.home),
            ("Desktop", "menubar.dock.rectangle", LocalFileSystem.desktop),
            ("Documents", "doc", LocalFileSystem.documents),
            ("Downloads", "arrow.down.circle", LocalFileSystem.downloads),
        ]
    }

    public var body: some View {
        List {
            Section("Bookmarks") {
                if model.bookmarks.isEmpty {
                    Text("No saved connections yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(model.bookmarks) { bookmark in
                        BookmarkRow(model: model, bookmark: bookmark)
                    }
                }
            }

            Section("Places") {
                ForEach(favourites, id: \.2) { _, symbol, url in
                    Label {
                        Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                    } icon: {
                        Image(systemName: symbol)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.navigateLocal(to: url) }
                }

                ForEach(LocalFileSystem.mountedVolumes(), id: \.self) { volume in
                    Label(volume.lastPathComponent, systemImage: "externaldrive")
                        .contentShape(Rectangle())
                        .onTapGesture { model.navigateLocal(to: volume) }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct BookmarkRow: View {
    @ObservedObject var model: BrowserModel
    let bookmark: ConnectionProfile

    private var isActive: Bool {
        model.activeProfile?.id == bookmark.id && model.session.isConnected
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: bookmark.kind == .sftp ? "lock.shield" : "network")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.displayName)
                    .lineLimit(1)
                Text(bookmark.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isActive {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.beginConnect(to: bookmark) }
        .contextMenu {
            Button("Connect") { model.beginConnect(to: bookmark) }
            Button("Edit…") {
                model.connectionSheet = BrowserModel.ConnectionSheetMode(
                    profile: bookmark,
                    isNew: false
                )
            }
            Divider()
            Button("Forget Saved Password") {
                model.keychain.deletePassword(for: bookmark.id)
            }
            .disabled(!model.keychain.hasPassword(for: bookmark.id))
            Divider()
            Button("Delete Bookmark", role: .destructive) {
                model.bookmarkStore.remove(id: bookmark.id)
                model.reloadBookmarks()
            }
        }
    }
}

/// The strip along the bottom of the window.
struct StatusBarView: View {
    @ObservedObject var model: BrowserModel

    public init(model: BrowserModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)

                Text(model.busyMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if model.hasTransferActivity {
                Button {
                    model.showTransfers = true
                } label: {
                    Text("Transfers in progress")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
            }

            Text("\(model.displayedLocalEntries.count) local · \(model.displayedRemoteEntries.count) remote")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var statusColor: Color {
        switch model.session {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch model.session {
        case .connected:
            guard let profile = model.activeProfile else { return "Connected" }
            return "Connected to \(profile.host) as \(profile.username.isEmpty ? "guest" : profile.username)"
        case .connecting:
            return "Connecting…"
        case .disconnected:
            return "Not connected"
        case .failed(let message):
            return "Connection failed — \(message)"
        }
    }
}

/// The transfer queue, shown as a panel under the panes.
struct TransfersPanel: View {
    @ObservedObject var model: BrowserModel

    public init(model: BrowserModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Clear Finished") { model.clearFinishedTransfers() }
                    .controlSize(.small)
                    .disabled(!model.transfers.contains { $0.state.isFinished })

                Button("Cancel All") { model.cancelAllTransfers() }
                    .controlSize(.small)
                    .disabled(!model.hasTransferActivity)

                Button {
                    model.showTransfers = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide the transfer panel")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Divider()

            if model.transfers.isEmpty {
                PaneMessage(
                    symbol: "arrow.up.arrow.down",
                    title: "No transfers yet",
                    subtitle: "Uploads and downloads appear here."
                )
            } else {
                List {
                    ForEach(model.transfers) { item in
                        TransferRow(item: item) {
                            model.cancelTransfer(item.id)
                        }
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 26)
            }
        }
        .background(.bar)
    }
}

private struct TransferRow: View {
    let item: TransferItem
    let onCancel: () -> Void

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.request.direction == .upload ? "arrow.up" : "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.request.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 140, alignment: .leading)

            if item.state == .running || item.state == .queued {
                ProgressView(value: item.isIndeterminate ? nil : item.fractionCompleted)
                    .progressViewStyle(.linear)
                    .frame(minWidth: 80)
            } else {
                Text(item.state.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
            }

            Text(progressText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 120, alignment: .trailing)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(item.state.isFinished)
            .help("Cancel this transfer")
        }
        .padding(.vertical, 1)
    }

    private var subtitle: String {
        let destination = item.request.direction == .upload
            ? item.request.destinationPath
            : (item.request.destinationPath as NSString).deletingLastPathComponent
        return "\(item.request.direction.displayName) → \(destination)"
    }

    private var progressText: String {
        let done = ByteFormatter.string(item.bytesTransferred)
        if item.isIndeterminate { return done }
        let total = ByteFormatter.string(item.totalBytes)
        if item.state == .running, item.bytesPerSecond > 0 {
            return "\(done) / \(total)  \(ByteFormatter.rate(item.bytesPerSecond))"
        }
        return "\(done) / \(total)"
    }

    private var stateColor: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .secondary
        }
    }
}
