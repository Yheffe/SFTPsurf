import Foundation
import SFTPsurfCore
import SFTPsurfUI

/// Covers the scripted-launch config file.
///
/// These exist because a config with one omitted key used to fail the whole
/// decode silently — the app would start with nothing to do and no explanation.
enum LaunchOptionsTests {
    static var cases: [TestCase] {
        [
            TestCase("a minimal config is accepted") {
                // The regression: only the bookmark is set, everything else is
                // omitted.
                let options = try decode(#"{"bookmarkID": "ABC-123"}"#)
                try expect(options.isActive, "a config with a bookmark should be active")
                try expect(options.bookmarkID == "ABC-123")
                try expect(options.dumpHierarchy == false, "omitted booleans default to false")
                try expect(options.demoTransfers == false)
                try expect(options.captureSet == nil)
                try expect(options.holdSeconds == nil)
            },

            TestCase("a full config round trips") {
                let options = try decode(
                    """
                    {
                      "captureSet": "/tmp/shots",
                      "localDirectory": "/tmp/local",
                      "supportDirectory": "/tmp/support",
                      "windowSize": "1360x820",
                      "dumpHierarchy": true,
                      "log": "/tmp/run.log",
                      "bookmarkID": "ABC-123",
                      "holdSeconds": 12.5,
                      "demoTransfers": true,
                      "connect": {
                        "kind": "ftp", "host": "127.0.0.1",
                        "port": 2121, "username": "u", "password": "p"
                      }
                    }
                    """
                )
                try expect(options.captureSet == "/tmp/shots")
                try expect(options.localDirectory == "/tmp/local")
                try expect(options.supportDirectory == "/tmp/support")
                try expect(options.dumpHierarchy)
                try expect(options.log == "/tmp/run.log")
                try expect(options.bookmarkID == "ABC-123")
                try expect(options.holdSeconds == 12.5)
                try expect(options.demoTransfers)
                try expect(options.connect?.port == 2121)
                try expect(options.connect?.protocolKind == .ftp)

                let size = try require(options.parsedWindowSize)
                try expect(size.width == 1360 && size.height == 820, "got \(size)")
            },

            TestCase("an unknown protocol falls back to SFTP") {
                let options = try decode(
                    #"{"connect": {"kind": "gopher", "host": "h", "port": 1, "username": "u", "password": "p"}}"#
                )
                try expect(options.connect?.protocolKind == .sftp)
            },

            TestCase("an empty config is inactive") {
                let options = try decode("{}")
                try expect(options.isActive == false, "an empty config should do nothing")
            },

            TestCase("a malformed config is rejected without crashing") {
                let directory = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("bad.json")
                try Data("{ not json at all".utf8).write(to: file)

                let options = LaunchOptions.parse(["SFTPsurf", file.path])
                try expect(options.isActive == false, "a malformed config should be ignored")

                // The breadcrumb is what makes this diagnosable from a script.
                let breadcrumb = directory.appendingPathComponent("bad.json.error")
                try expect(
                    FileManager.default.fileExists(atPath: breadcrumb.path),
                    "a failed decode should leave a breadcrumb beside the config"
                )
            },

            TestCase("a missing config file is ignored") {
                let options = LaunchOptions.parse(["SFTPsurf", "/tmp/definitely-not-here-\(UUID().uuidString).json"])
                try expect(options.isActive == false)
            },

            TestCase("dash-prefixed arguments never trigger a scripted launch") {
                // AppKit hands these to NSUserDefaults; treating one as a config
                // path would be a surprising way to break a normal launch.
                for argument in ["-NSDocumentRevisionsDebugMode", "--capture-set", "YES"] {
                    let options = LaunchOptions.parse(["SFTPsurf", argument])
                    try expect(options.isActive == false, "\(argument) should not be treated as a config")
                }
            },

            TestCase("no extra argument at all is a normal launch") {
                let options = LaunchOptions.parse(["SFTPsurf"])
                try expect(options.isActive == false)
                try expect(options.dumpHierarchy == false)
            },

            TestCase("window size strings are parsed defensively") {
                try expect(try decode(#"{"windowSize": "1360X820"}"#).parsedWindowSize?.width == 1360)
                try expect(try decode(#"{"windowSize": "nonsense"}"#).parsedWindowSize == nil)
                try expect(try decode(#"{"windowSize": "100"}"#).parsedWindowSize == nil)
                try expect(try decode("{}").parsedWindowSize == nil)
            },

            TestCase("a connection nickname becomes the display name") {
                let named = try decode(
                    #"{"connect": {"kind": "ftp", "host": "127.0.0.1", "port": 21, "username": "u", "password": "p", "nickname": "Acme Staging"}}"#
                )
                try expect(named.connect?.displayName == "Acme Staging")

                // Without one it falls back to the host, so the window is never blank.
                let unnamed = try decode(
                    #"{"connect": {"kind": "ftp", "host": "127.0.0.1", "port": 21, "username": "u", "password": "p"}}"#
                )
                try expect(unnamed.connect?.displayName == "127.0.0.1")

                // An empty string is treated as absent rather than shown.
                let blank = try decode(
                    #"{"connect": {"kind": "ftp", "host": "h", "port": 1, "username": "u", "password": "p", "nickname": ""}}"#
                )
                try expect(blank.connect?.displayName == "h")
            },

            TestCase("appearance is optional and round trips") {
                try expect(try decode("{}").appearance == nil)
                try expect(try decode(#"{"appearance": "light"}"#).appearance == "light")
                try expect(try decode(#"{"appearance": "dark"}"#).appearance == "dark")
            },
        ]
    }

    private static func decode(_ json: String) throws -> LaunchOptions {
        do {
            return try JSONDecoder().decode(LaunchOptions.self, from: Data(json.utf8))
        } catch {
            throw CheckError(
                message: "decoding \(json) failed: \(error)",
                file: #fileID,
                line: #line
            )
        }
    }
}
