import Foundation

/// Where SFTPsurf keeps its own state. Nothing here touches a user's dotfiles
/// except to *read* `~/.ssh/known_hosts` once, as a trust seed.
public enum AppPaths {
    /// Set before anything reads a path to redirect all app state elsewhere.
    /// Used by screenshot runs so they never touch real bookmarks.
    public static var overrideSupportDirectory: URL?

    public static var applicationSupport: URL {
        if let overrideSupportDirectory {
            try? FileManager.default.createDirectory(
                at: overrideSupportDirectory,
                withIntermediateDirectories: true
            )
            return overrideSupportDirectory
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("SFTPsurf", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static var bookmarksFile: URL {
        applicationSupport.appendingPathComponent("bookmarks.json")
    }

    public static var preferencesFile: URL {
        applicationSupport.appendingPathComponent("preferences.json")
    }

    public static var knownHostsFile: URL {
        applicationSupport.appendingPathComponent("known_hosts")
    }

    /// OpenSSH's own known-hosts file, used only as a starting point.
    public static var userKnownHostsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/known_hosts")
    }

    public static var sshExecutable: URL {
        URL(fileURLWithPath: "/usr/bin/ssh")
    }

    /// The revision-controlled copy of the local SFTP server, handy for tests.
    public static var systemSFTPServer: URL {
        URL(fileURLWithPath: "/usr/libexec/sftp-server")
    }
}
