# Changelog

Notable changes to SFTPsurf. This project uses [semantic versioning][semver].

[semver]: https://semver.org

## [Unreleased]

Nothing yet.

## [1.1.1] — 2026-10-17

A packaging fix. The application is unchanged from 1.1; the disk image it ships
in was wrong.

### Fixed

- **The released disk image opened as a plain folder.** The window's background
  picture and icon positions both live in `.DS_Store`, which only Finder can
  write — and a CI runner has no Automation permission to ask it. The published
  1.1 image therefore had the background image present but unreferenced, and the
  icons unplaced. It also had no custom volume icon, because Finder deletes
  `.VolumeIcon.icns` while applying a background picture and the build was
  copying it too early; that affected locally built images too. The view
  settings are now kept in the repository and applied whenever Finder cannot be
  asked, and the volume icon is written after the Finder step. Verification
  asserts both, so neither can regress quietly.

## [1.1] — 2026-10-17

The first release intended for other people. Substantial hardening after testing
against a real SFTP server for the first time.

### Added

- Drag-to-install disk image (`Scripts/make-dmg.sh`), which reads its version from
  `Info.plist` and verifies the finished image before reporting success.
- Real-server test suite, enabled with `SFTPsurf_REAL_HOST=<bookmark-uuid>`. Covers
  connect, upload, download, rename, permissions and deletion over a genuine SSH
  connection, verifying bytes come back identical. Everything happens inside a
  scratch folder that is removed afterwards.
- Tests for the subprocess transports, including stderr capture, stream
  separation, clean exits, unblocking on close, refused connections and
  unresolvable hostnames.
- Tests for the scripted-launch config parser.
- `Scripts/make-docs-screenshots.sh`, which generates the sanitised screenshots in
  `docs/` against a local server, with throwaway bookmarks and no reference to
  anyone's real machine.
- Explicit per-file progress, live throughput and per-transfer cancellation in the
  transfers panel.
- The local and remote columns now adapt to the pane width, dropping size, date
  and kind as space runs out instead of clipping.

### Fixed

- **FTP transfers running at the same time corrupted each other.** All FTP
  commands share one control connection, so overlapping transfers crossed their
  `PASV` replies and completion codes, producing "Connection refused" and "Data
  connection already open" failures. The client now takes exclusive use of the
  connection for the duration of each transfer.
- **`LIST` parsing dropped the execute bit** on every entry. The permission
  decoder mishandled the `s` and `t` slots, so a `drwxr-xr-x` directory reported
  `644` rather than `755`.
- **All SSH diagnostics were discarded.** The stderr reader in the subprocess
  transport was not retained, so it deallocated immediately and the child's stderr
  was never read. Every failure reported "the connection ended unexpectedly",
  including bad passwords, rejected host keys and unreachable hosts. These now
  surface the server's own message.
- **A handshake packet had its type byte consumed twice**, so the SFTP version
  exchange read a zero and rejected the connection.
- **Configuration files were rejected if any key was omitted.** Swift's
  synthesised `Decodable` ignores property defaults, so a config setting only
  `bookmarkID` failed to decode — silently, because `open` detaches stderr. It is
  now decoded field by field, and a failed read leaves a `.error` file beside the
  config.
- **The app could launch with no window at all** when started quickly after a
  previous instance exited. It now detects this and opens the browser itself.
- A failed upload or download no longer leaves a partial file behind locally.
- Dragging a folder onto the remote pane no longer overwrites existing entries;
  it picks a free name instead, matching Finder.
- Opening in the local pane no longer follows symlinked directories, which had
  made them indistinguishable from real folders.

### Changed

- Clicking a bookmark no longer discards the password on a failed attempt; the
  password sheet is offered again with the error message.
- Column headings use "Modified" rather than "Date Modified", so they fit narrow
  panes.

## [1.0] — 2026-10-16

Initial version: two-pane browser over SFTP (via `/usr/bin/ssh`) and FTP, with a
transfer queue, bookmarks, keychain-backed passwords, trust-on-first-use host key
pinning, and a self-contained test suite.
