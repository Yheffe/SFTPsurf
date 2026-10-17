import AppKit
import Foundation
import SwiftUI
import SFTPsurfCore
import SFTPsurfUI

/// Drives a scripted launch: optionally connect, capture, then quit.
@MainActor
enum ScriptedLaunch {
    /// Time allowed for layout (and any connection) before an ad-hoc capture.
    private static let settleDelay: TimeInterval = 1.5

    static func run(model: BrowserModel, options: LaunchOptions) async {
        let logger = Logger(path: options.log)
        logger.log("scripted launch started (set=\(options.captureSet ?? "-"))")

        // Pinned before anything is drawn, so documentation images are the same
        // regardless of the theme of whoever regenerates them.
        if let appearance = options.appearance {
            let name: NSAppearance.Name = appearance.lowercased() == "dark" ? .darkAqua : .aqua
            NSApplication.shared.appearance = NSAppearance(named: name)
        }

        if let path = options.localDirectory {
            model.navigateLocal(to: URL(fileURLWithPath: path))
        }

        guard let window = await browserWindow(logger: logger) else {
            // Never leave a headless instance running: it would swallow later launches.
            logger.log("giving up without a window; exiting")
            NSApplication.shared.terminate(nil)
            return
        }

        if let size = options.parsedWindowSize {
            window.setContentSize(size)
            window.center()
            // Let the layout settle at the new size before anything is captured.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Connect first, whichever way the credentials were supplied.
        if let bookmarkID = options.bookmarkID, let uuid = UUID(uuidString: bookmarkID) {
            await connectViaBookmark(model: model, id: uuid, logger: logger)
        } else if let request = options.connect {
            await connect(model: model, request: request, logger: logger)
        }

        // Then optionally put some work in flight for the queue to show.
        if options.demoTransfers {
            model.showTransfers = true
            if let scratch = await prepareDemoTransfers(model: model, logger: logger) {
                // Remove the scratch folder as soon as the transfers are done.
                // Waiting until after the hold would leave it behind if the app
                // is killed while the screenshot is being taken.
                await removeDemoScratch(model: model, scratch: scratch, logger: logger)
            }
        }

        // `holdSeconds` leaves the app on screen so an external screenshot tool
        // can capture the real window, glass sidebar and all.
        if let hold = options.holdSeconds {
            logger.log("holding open for \(hold)s")
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            logger.log("scripted launch finished")
            NSApplication.shared.terminate(nil)
            return
        }

        // `holdSeconds` leaves the app on screen so an external screenshot tool
        // can capture the real window, glass sidebar and all.
        if let hold = options.holdSeconds {
            logger.log("holding open for \(hold)s")
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            logger.log("scripted launch finished")
            NSApplication.shared.terminate(nil)
            return
        }

        if let directory = options.captureSet {
            await runSequence(
                model: model,
                window: window,
                directory: URL(fileURLWithPath: directory),
                options: options,
                logger: logger
            )
        } else if let path = options.capturePath {
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            capture(window: window, to: path, dumpingHierarchy: options.dumpHierarchy, logger: logger)
        }

        logger.log("scripted launch finished")
        NSApplication.shared.terminate(nil)
    }

    /// Runs some transfers for the screenshots, entirely inside a scratch folder
    /// it creates on the server.
    ///
    /// Earlier versions of this wrote straight into the home directory, which
    /// left stray files on the server. Everything now happens in one folder that
    /// `removeDemoScratch` deletes afterwards.
    private static func prepareDemoTransfers(
        model: BrowserModel,
        logger: Logger
    ) async -> (name: String, path: String)? {
        let name = "sftpsurf-demo-\(UUID().uuidString.prefix(8))"
        await model.createRemoteFolder(named: name)

        let path = RemotePath.join(model.homePath, name)
        // No attributes back means the folder did not appear, so there is
        // nothing to demonstrate.
        let created: RemoteEntry? = try? await model.client?.attributes(of: path)
        guard created != nil else {
            logger.log("demo: could not create \(path); skipping transfers")
            return nil
        }
        await model.navigateRemote(to: path)

        // Upload two real files (not directories, which would recurse).
        let localFiles = Array(model.localEntries.filter { !$0.isDirectory }.prefix(2))
        model.upload(entries: localFiles)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Then fetch them back, so the queue shows both directions.
        await model.reloadRemote()
        let uploaded = Array(model.remoteEntries.filter { !$0.isDirectory }.prefix(2))
        model.download(entries: uploaded)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let states = model.transfers.map { $0.state.displayName }
        logger.log("demo transfers: \(model.transfers.count) item(s) \(states)")
        return (name, path)
    }

    /// Deletes the scratch folder created by `prepareDemoTransfers`.
    private static func removeDemoScratch(
        model: BrowserModel,
        scratch: (name: String, path: String),
        logger: Logger
    ) async {
        // Step out of the folder first, otherwise the listing points at a
        // directory that is about to vanish.
        await model.navigateRemote(to: model.homePath)
        await model.deleteRemoteEntries([
            RemoteEntry(name: scratch.name, path: scratch.path, isDirectory: true)
        ])
        logger.log("demo: removed \(scratch.path)")
    }

    /// Connects with a saved bookmark, reading the password from the keychain —
    /// the same path the sidebar takes when a bookmark is clicked.
    private static func connectViaBookmark(model: BrowserModel, id: UUID, logger: Logger) async {
        let store = BookmarkStore(fileURL: AppPaths.bookmarksFile)
        guard let profile = store.bookmark(id: id) else {
            logger.log("no bookmark with id \(id.uuidString)")
            return
        }

        let password = KeychainStore().password(for: id)
        await model.connect(profile: profile, password: password)
        logSessionState(model: model, host: profile.host, logger: logger)
    }

    // MARK: - Capture sequence

    /// Captures every state in a single run. Relaunching between shots proved
    /// unreliable: SwiftUI does not always recreate the window in time.
    private static func runSequence(
        model: BrowserModel,
        window: NSWindow,
        directory: URL,
        options: LaunchOptions,
        logger: Logger
    ) async {
        func shot(_ name: String, hierarchy: Bool = false) {
            capture(
                window: window,
                to: directory.appendingPathComponent("\(name).png").path,
                dumpingHierarchy: hierarchy,
                logger: logger
            )
        }

        // 1. Nothing connected.
        try? await Task.sleep(nanoseconds: 900_000_000)
        shot("01-disconnected", hierarchy: true)

        // 2. A live session with real remote content.
        if let request = options.connect {
            await connect(model: model, request: request, logger: logger)
            try? await Task.sleep(nanoseconds: 900_000_000)
            shot("02-connected", hierarchy: true)

            // 3. The transfer queue with work in flight. Everything is
            // enqueued so some rows are queued or running when captured.
            model.showTransfers = true
            model.download(entries: model.remoteEntries)
            model.upload(entries: model.localEntries)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            logger.log(
                "before 03: remote=\(model.remoteEntries.count) local=\(model.localEntries.count) "
                    + "transfers=\(model.transfers.count) states=\(model.transfers.map(\.state))"
            )
            shot("03-transfers")
            logger.log("after 03: transfers=\(model.transfers.count)")
        }

        // 4. The connection editor, which is presented as a sheet.
        model.connectionSheet = BrowserModel.ConnectionSheetMode(
            profile: ConnectionProfile(
                nickname: "Production",
                kind: .sftp,
                host: "prod.example.com",
                username: "deploy",
                authMethod: .privateKey(path: "~/.ssh/id_ed25519"),
                initialPath: "/var/www",
                proxyJump: "deploy@bastion.example.com"
            ),
            isNew: false
        )
        try? await Task.sleep(nanoseconds: 900_000_000)
        if let sheet = sheetWindow() {
            capture(
                window: sheet,
                to: directory.appendingPathComponent("04-connection-sheet.png").path,
                dumpingHierarchy: false,
                logger: logger
            )
        } else {
            logger.log("no sheet window appeared")
        }
    }

    private static func connect(
        model: BrowserModel,
        request: LaunchOptions.ConnectionRequest,
        logger: Logger
    ) async {
        let profile = ConnectionProfile(
            nickname: request.displayName,
            kind: request.protocolKind,
            host: request.host,
            port: request.port,
            username: request.username,
            authMethod: .password
        )
        await model.connect(profile: profile, password: request.password)
        logSessionState(model: model, host: profile.host, logger: logger)
    }

    /// Reports how a connection attempt ended, so a script driving the app has
    /// something deterministic to wait on.
    private static func logSessionState(model: BrowserModel, host: String, logger: Logger) {
        switch model.session {
        case .connected:
            logger.log("connected to \(host); \(model.remoteEntries.count) remote entries")
        case .failed(let message):
            logger.log("connect failed: \(message)")
        case .connecting:
            logger.log("connect still in progress for \(host)")
        case .disconnected:
            logger.log("connect ended disconnected for \(host)")
        }
    }

    // MARK: - Window plumbing

    /// Waits for the browser window, since SwiftUI creates it slightly after the
    /// view's task starts.
    private static func browserWindow(logger: Logger) async -> NSWindow? {
        for attempt in 0..<40 {
            let candidates = NSApplication.shared.windows.filter { $0.contentView != nil && !$0.isSheet }
            if let best = candidates.max(by: { $0.frame.size.width < $1.frame.size.width }),
               best.isVisible {
                return best
            }
            if attempt == 10 {
                for window in candidates where !window.isVisible {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        logger.log("no browser window appeared (\(NSApplication.shared.windows.count) window(s))")
        return nil
    }

    private static func sheetWindow() -> NSWindow? {
        NSApplication.shared.windows
            .filter { $0.isVisible && $0.contentView != nil }
            .min(by: { $0.frame.size.width < $1.frame.size.width })
    }

    private static func capture(
        window: NSWindow,
        to path: String,
        dumpingHierarchy: Bool,
        logger: Logger
    ) {
        guard let view = window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            logger.log("could not allocate a bitmap for \(path)")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            logger.log("could not encode PNG for \(path)")
            return
        }

        let destination = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: destination)
            logger.log("captured \(destination.lastPathComponent) (\(png.count / 1024) KB)")

            if dumpingHierarchy {
                try describe(view, depth: 0).write(
                    to: destination.deletingPathExtension().appendingPathExtension("hierarchy.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        } catch {
            logger.log("could not write \(path): \(error)")
        }
    }

    /// A readable outline of the AppKit view tree, which is the quickest way to
    /// tell an empty pane apart from a capture artefact.
    private static func describe(_ view: NSView, depth: Int) -> String {
        var lines: [String] = []
        let indent = String(repeating: "  ", count: depth)
        let frame = view.frame
        lines.append(
            String(
                format: "%@%@ (%.0f,%.0f %.0fx%.0f)%@%@",
                indent,
                String(describing: type(of: view)),
                frame.origin.x, frame.origin.y, frame.width, frame.height,
                view.isHidden ? " hidden" : "",
                view.wantsLayer ? " layer" : ""
            )
        )
        for subview in view.subviews {
            lines.append(describe(subview, depth: depth + 1))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Echoes progress to both stdout and the log file, since `open` detaches
    /// the process's standard streams.
    struct Logger {
        let path: String?

        func log(_ message: String) {
            print(message)
            guard let path else { return }
            let url = URL(fileURLWithPath: path)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data((message + "\n").utf8))
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? Data((message + "\n").utf8).write(to: url)
            }
        }
    }
}
