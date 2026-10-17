import Foundation
import SFTPsurfCore

/// Covers path handling, which every listing and transfer depends on.
enum RemotePathTests {
    static var cases: [TestCase] {
        [
            TestCase("join handles trailing and missing separators") {
                try expect(RemotePath.join("/var", "log") == "/var/log")
                try expect(RemotePath.join("/var/", "log") == "/var/log")
                try expect(RemotePath.join("/", "etc") == "/etc")
                try expect(RemotePath.join("", "etc") == "/etc")
            },

            TestCase("normalize collapses redundant separators") {
                try expect(RemotePath.normalize("/a//b///c") == "/a/b/c")
                try expect(RemotePath.normalize("/a/b/") == "/a/b")
                try expect(RemotePath.normalize("/") == "/")
                try expect(RemotePath.normalize("") == "/")
            },

            TestCase("parent walks up and stops at the root") {
                try expect(RemotePath.parent(of: "/a/b/c") == "/a/b")
                try expect(RemotePath.parent(of: "/a") == "/")
                try expect(RemotePath.parent(of: "/") == nil)
            },

            TestCase("lastComponent returns the trailing element") {
                try expect(RemotePath.lastComponent(of: "/a/b/c.txt") == "c.txt")
                try expect(RemotePath.lastComponent(of: "/a/b/") == "b")
                try expect(RemotePath.lastComponent(of: "/") == "")
            },

            TestCase("resolve applies dot and dotdot segments") {
                try expect(RemotePath.resolve(".", relativeTo: "/home/me") == "/home/me")
                try expect(RemotePath.resolve("..", relativeTo: "/home/me") == "/home")
                try expect(RemotePath.resolve("../../etc", relativeTo: "/home/me/docs") == "/home/etc")
                try expect(RemotePath.resolve("../..", relativeTo: "/") == "/")
                try expect(RemotePath.resolve("/abs/path", relativeTo: "/ignored") == "/abs/path")
            },

            TestCase("isDescendant guards against path traversal") {
                try expect(RemotePath.isDescendant("/home/me/photos", of: "/home/me"))
                try expect(RemotePath.isDescendant("/home/me", of: "/home/me"))
                try expect(RemotePath.isDescendant("/home/other", of: "/home/me") == false)
                // A sibling whose name merely shares a prefix must not match.
                try expect(RemotePath.isDescendant("/home/melon", of: "/home/me") == false)
            },
        ]
    }
}

/// The permission string is what the browser shows, so it needs to be right.
enum RemoteEntryTests {
    static var cases: [TestCase] {
        [
            TestCase("permissionString renders mode bits like ls") {
                let directory = RemoteEntry(
                    name: "d", path: "/d", isDirectory: true, permissions: 0o040755
                )
                try expect(directory.permissionString == "drwxr-xr-x")

                let file = RemoteEntry(name: "f", path: "/f", isDirectory: false, permissions: 0o100644)
                try expect(file.permissionString == "-rw-r--r--")

                let link = RemoteEntry(
                    name: "l", path: "/l", isDirectory: false, isSymlink: true, permissions: 0o120777
                )
                try expect(link.permissionString == "lrwxrwxrwx")
            },

            TestCase("permissionString is nil without mode bits") {
                let entry = RemoteEntry(name: "f", path: "/f", isDirectory: false)
                try expect(entry.permissionString == nil)
            },

            TestCase("directories sort above files") {
                let entries = [
                    RemoteEntry(name: "b.txt", path: "/b.txt", isDirectory: false),
                    RemoteEntry(name: "folder", path: "/folder", isDirectory: true),
                    RemoteEntry(name: "a.txt", path: "/a.txt", isDirectory: false),
                ]
                let sorted = entries.sorted(by: RemoteEntry.sortByName)
                try expect(sorted.map(\.name) == ["folder", "a.txt", "b.txt"])
            },

            TestCase("natural ordering handles numbered names") {
                let entries = [
                    RemoteEntry(name: "file10.txt", path: "/file10.txt", isDirectory: false),
                    RemoteEntry(name: "file2.txt", path: "/file2.txt", isDirectory: false),
                ]
                let sorted = entries.sorted(by: RemoteEntry.sortByName)
                try expect(sorted.map(\.name) == ["file2.txt", "file10.txt"])
            },
        ]
    }
}

/// Locks down the profile model, including the FTP auth restriction.
enum ConnectionProfileTests {
    static var cases: [TestCase] {
        [
            TestCase("effectivePort falls back to the protocol default") {
                let sftp = ConnectionProfile(kind: .sftp, host: "example.com")
                try expect(sftp.effectivePort == 22)

                let ftp = ConnectionProfile(kind: .ftp, host: "example.com")
                try expect(ftp.effectivePort == 21)

                let custom = ConnectionProfile(kind: .sftp, host: "example.com", port: 2222)
                try expect(custom.effectivePort == 2222)
            },

            TestCase("displayName prefers the nickname") {
                let named = ConnectionProfile(nickname: "Staging", host: "10.0.0.1", username: "deploy")
                try expect(named.displayName == "Staging")

                let unnamed = ConnectionProfile(host: "10.0.0.1", username: "deploy")
                try expect(unnamed.displayName == "deploy@10.0.0.1")
            },

            TestCase("sanitized forces password auth for FTP") {
                let stripped = AuthMethod.sanitized(.privateKey(path: "/key"), for: .ftp)
                try expect(stripped == .password)

                let kept = AuthMethod.sanitized(.privateKey(path: "/key"), for: .sftp)
                try expect(kept == .privateKey(path: "/key"))
            },

            TestCase("profiles survive a JSON round trip") {
                let original = ConnectionProfile(
                    nickname: "Prod",
                    kind: .sftp,
                    host: "prod.example.com",
                    port: 2222,
                    username: "deploy",
                    authMethod: .privateKey(path: "~/.ssh/id_ed25519"),
                    initialPath: "/var/www",
                    proxyJump: "bastion.example.com",
                    sshOptions: ["-o", "Compression=yes"]
                )

                let data = try JSONEncoder().encode(original)
                let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
                try expect(decoded == original, "a saved profile must reload identically")
            },
        ]
    }
}

/// Formatting helpers used throughout the UI.
enum FormattingTests {
    static var cases: [TestCase] {
        [
            TestCase("byte formatting is human readable") {
                try expect(ByteFormatter.string(0) == "0 bytes", "got \(ByteFormatter.string(0))")
                try expect(ByteFormatter.string(1024) == "1 KB", "got \(ByteFormatter.string(1024))")
                try expect(ByteFormatter.string(5 * 1024 * 1024) == "5.2 MB")
            },

            TestCase("rate formatting copes with zero and non-finite input") {
                try expect(ByteFormatter.rate(0) == "—")
                try expect(ByteFormatter.rate(.infinity) == "—")
                try expect(ByteFormatter.rate(2048).hasSuffix("/s"))
            },

            TestCase("transfer fraction is clamped") {
                var item = TransferItem(
                    request: TransferRequest(
                        direction: .upload,
                        sourcePath: "/local/a",
                        destinationPath: "/remote/a",
                        totalBytes: 100
                    )
                )
                try expect(item.fractionCompleted == 0)

                item.bytesTransferred = 50
                try expect(item.fractionCompleted == 0.5)

                // A server that reports more bytes than expected must not overflow the bar.
                item.bytesTransferred = 250
                try expect(item.fractionCompleted == 1.0)
            },

            TestCase("zero-length transfers report no progress rather than dividing by zero") {
                let item = TransferItem(
                    request: TransferRequest(
                        direction: .upload,
                        sourcePath: "/local/a",
                        destinationPath: "/remote/a",
                        totalBytes: 0
                    )
                )
                try expect(item.fractionCompleted == 0)
            },
        ]
    }
}

/// Error messages are user-facing, so they need to stay meaningful.
enum ErrorPresentationTests {
    static var cases: [TestCase] {
        [
            TestCase("every error has a description") {
                let errors: [RemoteClientError] = [
                    .notConnected,
                    .hostNotFound("example.com"),
                    .connectionRefused("nope"),
                    .timedOut("slow"),
                    .authenticationFailed("Permission denied"),
                    .hostKeyRejected("key changed"),
                    .server("boom"),
                    .pathNotFound("/etc/missing"),
                    .permissionDenied("/root"),
                    .unsupported("this"),
                    .transport("broken"),
                ]
                for error in errors {
                    let described = error.errorDescription ?? ""
                    try expect(!described.isEmpty, "\(error) needs a user-facing description")
                }
            },

            TestCase("actionable errors carry a recovery suggestion") {
                try expect(RemoteClientError.authenticationFailed("x").recoverySuggestion != nil)
                try expect(RemoteClientError.hostKeyRejected("x").recoverySuggestion != nil)
                try expect(RemoteClientError.notConnected.recoverySuggestion == nil)
            },

            TestCase("errors interpolate their subject") {
                try expect(
                    RemoteClientError.pathNotFound("/tmp/x").errorDescription?.contains("/tmp/x") == true
                )
                try expect(
                    RemoteClientError.hostNotFound("nowhere.invalid").errorDescription?
                        .contains("nowhere.invalid") == true
                )
            },
        ]
    }
}
