import CoreGraphics
import Foundation
import SFTPsurfCore

/// Configuration for a scripted launch, used to drive the app from a script for
/// visual checks. Nothing here is needed for normal use.
///
/// The settings arrive as a single positional path to a JSON file rather than
/// as flags: AppKit hands any argument beginning with `-` to `NSUserDefaults`,
/// which silently derails launch (the app would come up with no window at all).
///
///     SFTPsurf /tmp/capture.json
public struct LaunchOptions: Decodable {
    /// Captures a whole sequence of states in one run, then quits.
    public var captureSet: String?
    /// A single capture point, kept for ad-hoc use.
    public var capturePath: String?
    /// Overrides the local pane's folder, so captures are reproducible.
    public var localDirectory: String?
    /// Redirects bookmarks and preferences to a scratch directory.
    public var supportDirectory: String?
    /// Forces a deterministic window size, as "1360x820".
    public var windowSize: String?
    /// Writes an AppKit view outline next to each PNG.
    public var dumpHierarchy: Bool
    /// Writes progress and diagnostics here, since `open` detaches stdout.
    public var log: String?
    /// Connects with explicit credentials.
    public var connect: ConnectionRequest?
    /// Connects using an existing bookmark plus its keychain password, so a
    /// scripted run never has to be handed a secret.
    public var bookmarkID: String?
    /// Keeps the app open for this many seconds instead of quitting, which lets
    /// an external screenshot tool capture the real window.
    public var holdSeconds: Double?
    /// Enqueues a couple of transfers after connecting, to show the queue busy.
    public var demoTransfers: Bool
    /// Forces "light" or "dark", so documentation images do not depend on the
    /// theme of whoever regenerates them.
    public var appearance: String?

    public struct ConnectionRequest: Decodable {
        public var kind: String
        public var host: String
        public var port: Int
        public var username: String
        public var password: String
        /// Shown as the window title. Falls back to the host.
        public var nickname: String?

        public var protocolKind: RemoteProtocolKind {
            RemoteProtocolKind(rawValue: kind) ?? .sftp
        }

        public var displayName: String {
            if let nickname, !nickname.isEmpty { return nickname }
            return host
        }

        public init(
            kind: String,
            host: String,
            port: Int,
            username: String,
            password: String,
            nickname: String? = nil
        ) {
            self.kind = kind
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.nickname = nickname
        }
    }

    public init(
        captureSet: String? = nil,
        capturePath: String? = nil,
        localDirectory: String? = nil,
        supportDirectory: String? = nil,
        windowSize: String? = nil,
        dumpHierarchy: Bool = false,
        log: String? = nil,
        connect: ConnectionRequest? = nil,
        bookmarkID: String? = nil,
        holdSeconds: Double? = nil,
        demoTransfers: Bool = false,
        appearance: String? = nil
    ) {
        self.captureSet = captureSet
        self.capturePath = capturePath
        self.localDirectory = localDirectory
        self.supportDirectory = supportDirectory
        self.windowSize = windowSize
        self.dumpHierarchy = dumpHierarchy
        self.log = log
        self.connect = connect
        self.bookmarkID = bookmarkID
        self.holdSeconds = holdSeconds
        self.demoTransfers = demoTransfers
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case captureSet, capturePath, localDirectory, supportDirectory, windowSize
        case dumpHierarchy, log, connect, bookmarkID, holdSeconds, demoTransfers
        case appearance
    }

    /// Decoded by hand rather than synthesised.
    ///
    /// Swift's generated `init(from:)` ignores property default values, so a
    /// single omitted key rejects the whole file. A config file has to tolerate
    /// that: you should be able to set only what you care about.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureSet = try container.decodeIfPresent(String.self, forKey: .captureSet)
        capturePath = try container.decodeIfPresent(String.self, forKey: .capturePath)
        localDirectory = try container.decodeIfPresent(String.self, forKey: .localDirectory)
        supportDirectory = try container.decodeIfPresent(String.self, forKey: .supportDirectory)
        windowSize = try container.decodeIfPresent(String.self, forKey: .windowSize)
        dumpHierarchy = try container.decodeIfPresent(Bool.self, forKey: .dumpHierarchy) ?? false
        log = try container.decodeIfPresent(String.self, forKey: .log)
        connect = try container.decodeIfPresent(ConnectionRequest.self, forKey: .connect)
        bookmarkID = try container.decodeIfPresent(String.self, forKey: .bookmarkID)
        holdSeconds = try container.decodeIfPresent(Double.self, forKey: .holdSeconds)
        demoTransfers = try container.decodeIfPresent(Bool.self, forKey: .demoTransfers) ?? false
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance)
    }

    /// Reads the configuration file named by the first positional argument.
    ///
    /// Returns an inactive configuration when there is no such file, which is
    /// what a normal launch looks like.
    public static func parse(_ arguments: [String] = CommandLine.arguments) -> LaunchOptions {
        guard arguments.count >= 2 else { return LaunchOptions() }
        let path = arguments[1]
        // Ignore anything that is not an absolute path so unrelated arguments
        // (including AppKit's own) can never trigger a scripted launch.
        guard path.hasPrefix("/") else { return LaunchOptions() }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            note("could not read \(path)", beside: path)
            return LaunchOptions()
        }

        do {
            return try JSONDecoder().decode(LaunchOptions.self, from: data)
        } catch {
            // Silent failure here is baffling to debug, and stderr is detached
            // when the app is launched with `open`, so leave a breadcrumb.
            note("could not decode \(path): \(error)", beside: path)
            return LaunchOptions()
        }
    }

    /// Writes a breadcrumb beside the config file, so a scripted launch that
    /// goes wrong can still be diagnosed even though `open` detaches stderr.
    private static func note(_ message: String, beside path: String) {
        try? (message + "\n").write(
            to: URL(fileURLWithPath: path + ".error"),
            atomically: true,
            encoding: .utf8
        )
    }

    public var isActive: Bool {
        capturePath != nil || captureSet != nil || connect != nil
            || localDirectory != nil || bookmarkID != nil
    }

    /// Parses "1360x820" into a size.
    public var parsedWindowSize: CGSize? {
        guard let windowSize else { return nil }
        let parts = windowSize.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Applies the support-directory override. Must run before the browser model
    /// is created, which is why the app calls it from its initializer.
    public func applySupportDirectoryOverride() {
        guard let supportDirectory else { return }
        AppPaths.overrideSupportDirectory = URL(fileURLWithPath: supportDirectory)
    }
}
