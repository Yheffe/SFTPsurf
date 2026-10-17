import Foundation
import SFTPsurfCore

/// Covers the transfer scheduler, the bookmark/preferences stores, the local
/// filesystem layer, and the FTP listing parsers.
enum QueueAndStoreTests {
    static var cases: [TestCase] {
        queueCases + localFileSystemCases + storeCases + parserCases
    }

    // MARK: - TransferQueue

    private static var queueCases: [TestCase] {
        [
            TestCase("transfer queue runs uploads and downloads to completion") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let recorder = UpdateRecorder()
                    let queue = TransferQueue(client: client, maxConcurrent: 2) { item in
                        recorder.record(item)
                    }

                    // Build a few files to move in both directions.
                    var uploads: [TransferRequest] = []
                    for index in 0..<5 {
                        let source = sandbox.appendingPathComponent("up-\(index).bin")
                        let payload = Data(repeating: UInt8(index), count: 40_000 + index * 1_000)
                        try payload.write(to: source)
                        uploads.append(
                            TransferRequest(
                                direction: .upload,
                                sourcePath: source.path,
                                destinationPath: sandbox.appendingPathComponent("remote-\(index).bin").path,
                                totalBytes: Int64(payload.count)
                            )
                        )
                    }

                    await queue.enqueue(uploads)
                    await queue.waitUntilIdle()

                    let afterUpload = await queue.snapshot()
                    try expect(afterUpload.count == 5, "expected 5 items, got \(afterUpload.count)")
                    for item in afterUpload {
                        guard case .completed = item.state else {
                            throw CheckError(
                                message: "upload \(item.request.displayName) ended as \(item.state)",
                                file: #fileID,
                                line: #line
                            )
                        }
                    }

                    // Now bring them back and compare bytes.
                    var downloads: [TransferRequest] = []
                    let destinationDirectory = try TestSupport.makeSandbox()
                    defer { try? FileManager.default.removeItem(at: destinationDirectory) }

                    for index in 0..<5 {
                        downloads.append(
                            TransferRequest(
                                direction: .download,
                                sourcePath: sandbox.appendingPathComponent("remote-\(index).bin").path,
                                destinationPath: destinationDirectory
                                    .appendingPathComponent("down-\(index).bin").path,
                                totalBytes: 0
                            )
                        )
                    }

                    await queue.enqueue(downloads)
                    await queue.waitUntilIdle()

                    for index in 0..<5 {
                        let original = try Data(
                            contentsOf: sandbox.appendingPathComponent("up-\(index).bin")
                        )
                        let roundTripped = try Data(
                            contentsOf: destinationDirectory.appendingPathComponent("down-\(index).bin")
                        )
                        try expect(
                            original == roundTripped,
                            "file \(index) came back as \(roundTripped.count) bytes, expected \(original.count)"
                        )
                    }

                    try expect(recorder.sawProgress, "progress updates should reach the observer")
                }
            },

            TestCase("transfer queue honours the concurrency limit") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let tracker = ConcurrencyTracker()
                    let queue = TransferQueue(client: client, maxConcurrent: 1) { item in
                        tracker.observe(item)
                    }

                    for index in 0..<4 {
                        let source = sandbox.appendingPathComponent("serial-\(index).bin")
                        try Data(repeating: 0x5A, count: 32_000).write(to: source)
                        await queue.enqueue(
                            TransferRequest(
                                direction: .upload,
                                sourcePath: source.path,
                                destinationPath: sandbox.appendingPathComponent("serial-remote-\(index).bin").path,
                                totalBytes: 32_000
                            )
                        )
                    }

                    await queue.waitUntilIdle()
                    try expect(
                        tracker.peakRunning <= 1,
                        "maxConcurrent 1 but saw \(tracker.peakRunning) running at once"
                    )
                    try expect(tracker.completed == 4, "expected 4 completions, got \(tracker.completed)")
                }
            },

            TestCase("a failed transfer is reported without stopping the queue") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    let recorder = UpdateRecorder()
                    let queue = TransferQueue(client: client, maxConcurrent: 1) { item in
                        recorder.record(item)
                    }

                    let good = sandbox.appendingPathComponent("good.bin")
                    try Data("hello".utf8).write(to: good)

                    await queue.enqueue([
                        // This one cannot succeed: the source does not exist.
                        TransferRequest(
                            direction: .upload,
                            sourcePath: sandbox.appendingPathComponent("missing.bin").path,
                            destinationPath: sandbox.appendingPathComponent("missing-remote.bin").path,
                            totalBytes: 10
                        ),
                        TransferRequest(
                            direction: .upload,
                            sourcePath: good.path,
                            destinationPath: sandbox.appendingPathComponent("good-remote.bin").path,
                            totalBytes: 5
                        ),
                    ])

                    await queue.waitUntilIdle()

                    let items = await queue.snapshot()
                    try expect(items.count == 2)

                    let failed = try require(items.first { $0.request.sourcePath.hasSuffix("missing.bin") })
                    if case .failed = failed.state {
                        // Expected.
                    } else {
                        throw CheckError(
                            message: "expected a failure, got \(failed.state)",
                            file: #fileID,
                            line: #line
                        )
                    }

                    // The queue must have carried on to the next item.
                    let succeeded = try require(items.first { $0.request.sourcePath.hasSuffix("good.bin") })
                    if case .completed = succeeded.state {
                        // Expected.
                    } else {
                        throw CheckError(
                            message: "a failed item blocked the queue: \(succeeded.state)",
                            file: #fileID,
                            line: #line
                        )
                    }
                }
            },

            TestCase("cancelling a queued transfer marks it cancelled") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, sandbox in
                    // One long-running item occupies the only slot, so the second
                    // is still queued when we cancel it.
                    let big = sandbox.appendingPathComponent("big.bin")
                    try Data(repeating: 0x11, count: 3 * 1024 * 1024).write(to: big)

                    let queue = TransferQueue(client: client, maxConcurrent: 1) { _ in }

                    let first = TransferRequest(
                        direction: .upload,
                        sourcePath: big.path,
                        destinationPath: sandbox.appendingPathComponent("big-remote.bin").path,
                        totalBytes: 3 * 1024 * 1024
                    )
                    let second = TransferRequest(
                        direction: .upload,
                        sourcePath: big.path,
                        destinationPath: sandbox.appendingPathComponent("second-remote.bin").path,
                        totalBytes: 3 * 1024 * 1024
                    )

                    await queue.enqueue([first, second])
                    await queue.cancel(second.id)
                    await queue.waitUntilIdle()

                    let items = await queue.snapshot()
                    let cancelled = try require(items.first { $0.id == second.id })
                    try expect(
                        cancelled.state == .cancelled,
                        "expected cancelled, got \(cancelled.state)"
                    )
                }
            },

            TestCase("waitUntilIdle returns immediately on an empty queue") {
                try await requireServer()
                try await TestSupport.withLocalSFTPSession { client, _ in
                    let queue = TransferQueue(client: client) { _ in }
                    let idle = await queue.isIdle
                    try expect(idle, "a fresh queue should be idle")
                    await queue.waitUntilIdle()
                }
            },
        ]
    }

    // MARK: - LocalFileSystem

    private static var localFileSystemCases: [TestCase] {
        [
            TestCase("local listing sorts directories first") {
                let sandbox = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: sandbox) }

                try Data("b".utf8).write(to: sandbox.appendingPathComponent("beta.txt"))
                try Data("a".utf8).write(to: sandbox.appendingPathComponent("alpha.txt"))
                try FileManager.default.createDirectory(
                    at: sandbox.appendingPathComponent("folder"),
                    withIntermediateDirectories: true
                )

                let entries = try LocalFileSystem.list(sandbox, showHidden: true)
                try expect(entries.map(\.name) == ["folder", "alpha.txt", "beta.txt"], "got \(entries.map(\.name))")
                try expect(entries.first?.isDirectory == true)

                let alpha = try require(entries.first { $0.name == "alpha.txt" })
                try expect(alpha.size == 1)
                try expect(alpha.modified != nil)
            },

            TestCase("local listing hides dotfiles unless asked") {
                let sandbox = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: sandbox) }

                try Data("x".utf8).write(to: sandbox.appendingPathComponent(".hidden"))
                try Data("y".utf8).write(to: sandbox.appendingPathComponent("visible"))

                let visibleOnly = try LocalFileSystem.list(sandbox, showHidden: false)
                try expect(visibleOnly.map(\.name) == ["visible"])

                let withHidden = try LocalFileSystem.list(sandbox, showHidden: true)
                try expect(Set(withHidden.map(\.name)) == ["visible", ".hidden"])
            },

            TestCase("uniqueDestination avoids collisions like Finder") {
                let sandbox = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: sandbox) }

                let first = LocalFileSystem.uniqueDestination(for: "report.txt", in: sandbox)
                try expect(first.lastPathComponent == "report.txt")
                try Data("1".utf8).write(to: first)

                let second = LocalFileSystem.uniqueDestination(for: "report.txt", in: sandbox)
                try expect(second.lastPathComponent == "report 2.txt", "got \(second.lastPathComponent)")
                try Data("2".utf8).write(to: second)

                let third = LocalFileSystem.uniqueDestination(for: "report.txt", in: sandbox)
                try expect(third.lastPathComponent == "report 3.txt")

                // Names without an extension should not gain a stray dot.
                let plain = LocalFileSystem.uniqueDestination(for: "notes", in: sandbox)
                try expect(plain.lastPathComponent == "notes")
                try Data("n".utf8).write(to: plain)
                let plainSecond = LocalFileSystem.uniqueDestination(for: "notes", in: sandbox)
                try expect(plainSecond.lastPathComponent == "notes 2", "got \(plainSecond.lastPathComponent)")
            },

            TestCase("createFolder picks a free name") {
                let sandbox = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: sandbox) }

                let created = try LocalFileSystem.createFolder(named: "untitled folder", in: sandbox)
                try expect(created.lastPathComponent == "untitled folder")

                let second = try LocalFileSystem.createFolder(named: "untitled folder", in: sandbox)
                try expect(second.lastPathComponent == "untitled folder 2")
                try expect(LocalFileSystem.isDirectory(second))
            },

            TestCase("isDirectory distinguishes files from folders") {
                let sandbox = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: sandbox) }

                let file = sandbox.appendingPathComponent("file")
                try Data("x".utf8).write(to: file)
                try FileManager.default.createDirectory(
                    at: sandbox.appendingPathComponent("dir"),
                    withIntermediateDirectories: true
                )

                try expect(LocalFileSystem.isDirectory(file) == false)
                try expect(LocalFileSystem.isDirectory(sandbox.appendingPathComponent("dir")))
                try expect(LocalFileSystem.isDirectory(sandbox.appendingPathComponent("absent")) == false)
            },

            TestCase("trash moves an item out of its folder") {
                let sandbox = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: sandbox) }

                let victim = sandbox.appendingPathComponent("to-delete.txt")
                try Data("bye".utf8).write(to: victim)
                try expect(FileManager.default.fileExists(atPath: victim.path))

                try LocalFileSystem.moveToTrash(victim)
                try expect(
                    FileManager.default.fileExists(atPath: victim.path) == false,
                    "the file should be gone from its original location"
                )
            },
        ]
    }

    // MARK: - Stores

    private static var storeCases: [TestCase] {
        [
            TestCase("bookmarks round trip through disk") {
                let directory = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("bookmarks.json")

                let store = BookmarkStore(fileURL: file)
                let profile = ConnectionProfile(
                    nickname: "Staging",
                    kind: .sftp,
                    host: "staging.example.com",
                    username: "deploy",
                    authMethod: .privateKey(path: "~/.ssh/id_ed25519")
                )
                store.add(profile)

                // A fresh instance must see what the previous one wrote.
                let reloaded = BookmarkStore(fileURL: file)
                let loaded = reloaded.all()
                try expect(loaded.count == 1, "expected 1 bookmark, got \(loaded.count)")
                try expect(loaded.first?.host == "staging.example.com")
                try expect(loaded.first?.authMethod == .privateKey(path: "~/.ssh/id_ed25519"))
            },

            TestCase("bookmark update and delete") {
                let directory = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("bookmarks.json")

                let store = BookmarkStore(fileURL: file)
                var profile = ConnectionProfile(nickname: "One", host: "one.example.com")
                store.add(profile)

                profile.nickname = "Renamed"
                try expect(store.update(profile), "update should find the existing bookmark")

                let other = ConnectionProfile(nickname: "Two", host: "two.example.com")
                store.add(other)
                try expect(store.all().count == 2)

                try expect(store.remove(id: profile.id))
                let remaining = store.all()
                try expect(remaining.count == 1)
                try expect(remaining.first?.nickname == "Two")

                try expect(store.remove(id: UUID()) == false, "removing an unknown id should report false")
            },

            TestCase("upsert adds then replaces") {
                let directory = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = BookmarkStore(fileURL: directory.appendingPathComponent("b.json"))

                var profile = ConnectionProfile(nickname: "First", host: "a.example.com")
                store.upsert(profile)
                try expect(store.all().count == 1)

                profile.nickname = "Second"
                store.upsert(profile)
                let all = store.all()
                try expect(all.count == 1, "upsert must not duplicate, got \(all.count)")
                try expect(all.first?.nickname == "Second")
            },

            TestCase("a corrupted bookmark file is quarantined rather than crashing") {
                let directory = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("bookmarks.json")
                try Data("{ this is not json".utf8).write(to: file)

                let store = BookmarkStore(fileURL: file)
                try expect(store.all().isEmpty, "a corrupt file should yield no bookmarks")

                let quarantined = directory.appendingPathComponent("bookmarks.corrupt.json")
                try expect(
                    FileManager.default.fileExists(atPath: quarantined.path),
                    "the corrupt file should be kept aside for inspection"
                )
            },

            TestCase("bookmarks order by most recently used") {
                let directory = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = BookmarkStore(fileURL: directory.appendingPathComponent("b.json"))

                let alpha = ConnectionProfile(nickname: "Alpha", host: "a")
                let beta = ConnectionProfile(nickname: "Beta", host: "b")
                store.add(alpha)
                store.add(beta)

                store.markUsed(id: alpha.id, at: Date())
                try expect(store.sortedForDisplay().first?.nickname == "Alpha")

                store.markUsed(id: beta.id, at: Date().addingTimeInterval(60))
                try expect(store.sortedForDisplay().first?.nickname == "Beta")
            },

            TestCase("preferences default and persist") {
                let directory = try TestSupport.makeSandbox()
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("preferences.json")

                let store = PreferencesStore(fileURL: file)
                let defaults = store.current()
                try expect(defaults.showHiddenFiles == false)
                try expect(defaults.maxConcurrentTransfers == 3)

                var changed = defaults
                changed.showHiddenFiles = true
                changed.maxConcurrentTransfers = 5
                store.save(changed)

                let reloaded = PreferencesStore(fileURL: file).current()
                try expect(reloaded.showHiddenFiles)
                try expect(reloaded.maxConcurrentTransfers == 5)
            },

            TestCase("keychain stores, replaces and removes a password") {
                // A unique id keeps this from touching any real bookmark entry.
                let id = UUID()
                let store = KeychainStore(service: "com.sftpsurf.SFTPsurf.selftest")
                defer { store.deletePassword(for: id) }

                try expect(store.password(for: id) == nil, "nothing should be stored yet")

                let saved = store.setPassword("hunter2", for: id)
                if !saved {
                    // Locked or restricted keychains would make this flaky in CI.
                    try skip("the keychain is not writable in this environment")
                }
                try expect(store.password(for: id) == "hunter2")
                try expect(store.hasPassword(for: id))

                store.setPassword("correct horse", for: id)
                try expect(store.password(for: id) == "correct horse", "setting again should overwrite")

                store.deletePassword(for: id)
                try expect(store.password(for: id) == nil)
                try expect(store.hasPassword(for: id) == false)
            },
        ]
    }

    // MARK: - FTP listing parsing

    private static var parserCases: [TestCase] {
        [
            TestCase("MLSD facts are parsed into entries") {
                let line = "type=file;size=1234;modify=20240112123456;unix.mode=0644;unix.owner=alice; report.txt"
                let entry = try require(FTPListingParser.parseMLSD(line, parent: "/docs"))

                try expect(entry.name == "report.txt", "got \(entry.name)")
                try expect(entry.path == "/docs/report.txt")
                try expect(entry.isDirectory == false)
                try expect(entry.size == 1234)
                try expect(entry.owner == "alice")
                try expect(entry.permissions.map { $0 & 0o777 } == 0o644)

                let expected = DateComponents(
                    calendar: Calendar(identifier: .gregorian),
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2024, month: 1, day: 12, hour: 12, minute: 34, second: 56
                ).date
                try expect(entry.modified == expected, "got \(String(describing: entry.modified))")
            },

            TestCase("MLSD directories and names with spaces") {
                let line = "type=dir;size=4096;modify=20240112123456;unix.mode=0755; My Documents"
                let entry = try require(FTPListingParser.parseMLSD(line, parent: "/"))

                try expect(entry.name == "My Documents", "got “\(entry.name)”")
                try expect(entry.isDirectory)
                try expect(entry.path == "/My Documents")
                try expect(
                    entry.permissions.map { $0 & 0o777 } == 0o755,
                    "mode was \(String(describing: entry.permissions.map { String($0, radix: 8) }))"
                )
                try expect(entry.permissions.map { $0 & 0o170000 } == RemoteEntry.directoryModeBit)
            },

            TestCase("MLSD skips the cdir and pdir pseudo-entries") {
                try expect(FTPListingParser.parseMLSD("type=cdir; /home", parent: "/") == nil)
                try expect(FTPListingParser.parseMLSD("type=pdir; /", parent: "/home") == nil)
            },

            TestCase("unix long listings are parsed") {
                let line = "-rw-r--r--   1 alice staff     2048 Jan 12 12:34 report.txt"
                let entry = try require(FTPListingParser.parseUnix(line, parent: "/docs"))

                try expect(entry.name == "report.txt")
                try expect(entry.isDirectory == false)
                try expect(entry.size == 2048)
                try expect(entry.owner == "alice")
                try expect(entry.group == "staff")
                try expect(entry.permissions.map { $0 & 0o777 } == 0o644)
                try expect(entry.modified != nil)
            },

            TestCase("unix directories, years and names with spaces") {
                let directory = try require(
                    FTPListingParser.parseUnix(
                        "drwxr-xr-x   2 root  wheel     4096 Mar  3  2021 backup archive",
                        parent: "/"
                    )
                )
                try expect(directory.name == "backup archive", "got “\(directory.name)”")
                try expect(directory.isDirectory)
                try expect(
                    directory.permissions.map { $0 & 0o777 } == 0o755,
                    "mode was \(String(describing: directory.permissions.map { String($0, radix: 8) }))"
                )

                let modified = try require(directory.modified, "no modification date was parsed")
                let components = Calendar(identifier: .gregorian)
                    .dateComponents(in: TimeZone(identifier: "UTC")!, from: modified)
                try expect(
                    components.year == 2021,
                    "parsed year=\(String(describing: components.year)) month=\(String(describing: components.month)) "
                        + "day=\(String(describing: components.day)) from \(modified)"
                )
                try expect(components.month == 3)
                try expect(components.day == 3)
            },

            TestCase("unix symlinks keep the link name, not the target") {
                let entry = try require(
                    FTPListingParser.parseUnix(
                        "lrwxrwxrwx   1 root  root        7 Jan 12 12:34 current -> releases/v2",
                        parent: "/"
                    )
                )
                try expect(entry.name == "current", "got “\(entry.name)”")
                try expect(entry.isSymlink)
                try expect(entry.isDirectory == false)
            },

            TestCase("unix parser ignores noise lines") {
                try expect(FTPListingParser.parseUnix("total 42", parent: "/") == nil)
                try expect(FTPListingParser.parseUnix("", parent: "/") == nil)
                try expect(FTPListingParser.parseUnix("some banner text", parent: "/") == nil)
            },

            TestCase("mode bits survive setuid and sticky flags") {
                let setuid = FTPListingParser.modeBits(type: "-", letters: "rwsr-xr-x")
                try expect(setuid & 0o4000 != 0, "setuid bit should be recognised")
                try expect(setuid & 0o100 != 0, "lowercase s also implies the owner execute bit")
                try expect(
                    setuid & 0o777 == 0o755,
                    "permission bits were \(String(setuid & 0o777, radix: 8))"
                )

                let setgidNoExec = FTPListingParser.modeBits(type: "-", letters: "rwSr-Sr-T")
                try expect(setgidNoExec & 0o2000 != 0, "uppercase S means setgid without execute")
                try expect(setgidNoExec & 0o010 == 0, "uppercase S must not imply execute")
                try expect(setgidNoExec & 0o1000 != 0, "uppercase T means sticky without execute")
                try expect(setgidNoExec & 0o001 == 0, "uppercase T must not imply execute")

                let sticky = FTPListingParser.modeBits(type: "d", letters: "rwxrwxrwt")
                try expect(sticky & 0o1000 != 0, "sticky bit should be recognised")
                try expect(sticky & 0o001 != 0, "lowercase t also implies the other execute bit")
                try expect(sticky & RemoteEntry.directoryModeBit != 0)
            },

            TestCase("FTP replies expose their status code and detail") {
                let reply = FTPReply(code: 227, lines: ["227 Entering Passive Mode (127,0,0,1,4,1)"])
                try expect(reply.code == 227)
                try expect(reply.isPositive)
                try expect(reply.detail.hasPrefix("Entering Passive Mode"), "got “\(reply.detail)”")

                let denied = FTPReply(code: 550, lines: ["550 Permission denied"])
                    .failure("deleting", path: "/x")
                guard let deniedError = denied as? RemoteClientError,
                      case .permissionDenied = deniedError else {
                    throw CheckError(
                        message: "550 Permission denied should map to permissionDenied, got \(denied)",
                        file: #fileID,
                        line: #line
                    )
                }

                let missing = FTPReply(code: 550, lines: ["550 No such file"])
                    .failure("listing", path: "/nope")
                guard let missingError = missing as? RemoteClientError,
                      case .pathNotFound = missingError else {
                    throw CheckError(
                        message: "550 No such file should map to pathNotFound, got \(missing)",
                        file: #fileID,
                        line: #line
                    )
                }
            },

            TestCase("PWD replies are parsed with and without quotes") {
                try expect(FTPClient.parseQuotedPath("\"/var/www\" is the current directory") == "/var/www")
                try expect(FTPClient.parseQuotedPath("/var/www") == "/var/www")
                try expect(FTPClient.parseQuotedPath("\"/\"") == "/")
                try expect(FTPClient.parseQuotedPath("no path here") == nil)
            },
        ]
    }

    private static func requireServer() async throws {
        if !TestSupport.systemSFTPServerAvailable {
            try skip("no /usr/libexec/sftp-server on this machine")
        }
    }
}

/// Collects queue updates, which arrive from arbitrary threads.
private final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sawRunning = false
    private var items: [UUID: TransferItem] = [:]

    func record(_ item: TransferItem) {
        lock.lock()
        if item.state == .running || item.bytesTransferred > 0 { sawRunning = true }
        items[item.id] = item
        lock.unlock()
    }

    var sawProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawRunning
    }
}

/// Tracks how many transfers were running at the same time.
private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    /// Ids currently running, so repeated progress reports are not double counted.
    private var active: Set<UUID> = []
    private var peak = 0
    private var finished = 0

    func observe(_ item: TransferItem) {
        lock.lock()
        defer { lock.unlock() }
        switch item.state {
        case .running:
            active.insert(item.id)
            peak = max(peak, active.count)
        case .completed, .failed, .cancelled:
            if active.remove(item.id) != nil { finished += 1 }
        case .queued:
            break
        }
    }

    var peakRunning: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    var completed: Int {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}
