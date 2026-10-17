import AppKit
import SwiftUI
import SFTPsurfCore
import SFTPsurfUI

/// The app's single browser model.
///
/// It lives at file scope so the AppKit delegate can reach it: the delegate has
/// to drive the scripted launch, and SwiftUI's `@StateObject` is not visible
/// from there.
@MainActor
let browserModel = BrowserModel()

@main
struct SFTPsurfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // A dropped connection must surface as an error, not a fatal signal.
        Bootstrap.configureProcess()
        // Runs before `browserModel` is created, so screenshots use scratch state.
        LaunchOptions.parse().applySupportDirectoryOverride()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(browserModel)
        }
        .commands {
            BrowserCommands(model: browserModel)
        }

        Settings {
            PreferencesView(model: browserModel)
                .environmentObject(browserModel)
        }
    }
}

/// Guards against a launch that produces no window at all.
///
/// SwiftUI has been observed finishing its launch without creating the
/// `WindowGroup` window — reproducible when the app is relaunched quickly after
/// a previous instance exits. Rather than leaving the user staring at nothing,
/// host the browser in a window of our own.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var fallbackWindow: NSWindow?

    /// Two panes plus a sidebar need room, so a freshly opened window is grown
    /// to this. The view's own minimum stays smaller so the layout still works
    /// on a small display.
    private static let preferredContentSize = NSSize(width: 1180, height: 760)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.parse()
        let isScripted = options.isActive

        // SwiftUI normally creates the WindowGroup window right after this; if
        // it does not, open one ourselves.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            if self.openWindowIfNoneExists() == nil, !isScripted {
                // A scripted run sets its own window size, so only a normal
                // launch gets the default.
                self.applyPreferredSize()
            }
        }

        // Screenshot runs are driven from here rather than a view's `task`,
        // which does not run dependably during scripted launches.
        guard isScripted else { return }
        Task { @MainActor in
            await ScriptedLaunch.run(model: browserModel, options: options)
        }
    }

    /// Grows a window that opened at the layout's minimum size.
    private func applyPreferredSize() {
        let windows = NSApplication.shared.windows.filter { $0.contentView != nil && !$0.isSheet }
        guard let window = windows.max(by: { $0.frame.size.width < $1.frame.size.width }) else {
            return
        }
        let current = window.contentLayoutRect.size
        guard current.width < 1000 || current.height < 640 else { return }
        window.setContentSize(Self.preferredContentSize)
        window.center()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Returns the window it created, or nil if one already existed.
    @discardableResult
    private func openWindowIfNoneExists() -> NSWindow? {
        let hasWindow = NSApplication.shared.windows.contains { $0.contentView != nil && !$0.isSheet }
        guard !hasWindow else { return nil }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.preferredContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SFTPsurf"
        window.contentView = NSHostingView(
            rootView: ContentView().environmentObject(browserModel)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        fallbackWindow = window
        return window
    }
}

/// Menu bar commands, so every action is reachable without the toolbar.
struct BrowserCommands: Commands {
    @ObservedObject var model: BrowserModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                model.connectionSheet = BrowserModel.ConnectionSheetMode(
                    profile: ConnectionProfile(),
                    isNew: true
                )
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Remote Folder…") {
                model.pendingNewFolder = BrowserModel.NewFolderPrompt(target: .remote)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!model.session.isConnected)

            Button("New Local Folder…") {
                model.pendingNewFolder = BrowserModel.NewFolderPrompt(target: .local)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button("Connect") {
                if let profile = model.activeProfile {
                    model.beginConnect(to: profile)
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model.session.isConnected || model.activeProfile == nil)

            Button("Disconnect") {
                Task { await model.disconnect() }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(!model.session.isConnected)

            Divider()

            Button("Refresh") {
                model.refreshLocal()
                Task { await model.reloadRemote() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Upload Selection") {
                model.upload(entries: model.selectedLocalEntries)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(model.localSelection.isEmpty || !model.session.isConnected)

            Button("Download Selection") {
                model.download(entries: model.selectedRemoteEntries)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.remoteSelection.isEmpty || !model.session.isConnected)

            Button("Delete Remote Selection") {
                model.requestRemoteDeletion(model.selectedRemoteEntries)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.remoteSelection.isEmpty || !model.session.isConnected)
        }

        CommandGroup(after: .sidebar) {
            Button("Show Transfer Queue") {
                model.showTransfers.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("Cancel All Transfers") {
                model.cancelAllTransfers()
            }
            .disabled(!model.hasTransferActivity)
        }
    }
}
