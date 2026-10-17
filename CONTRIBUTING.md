# Contributing to SFTPsurf

Thanks for taking a look. This is a small project, so the process is light.

## Getting set up

You need macOS 14 or later and the Swift toolchain. Xcode is **not** required —
Command Line Tools are enough, and everything in this repo is built and tested
with them:

```sh
xcode-select --install        # if you do not already have the tools
git clone <your fork>
cd SFTPsurf
swift build                   # compiles the libraries, the app and the tests
./Scripts/setup-test-deps.sh  # once: a venv with pyftpdlib for FTP tests
./Scripts/test.sh             # run the suite
```

To try the app without building a bundle:

```sh
swift run SFTPsurf
```

## Running the tests

```sh
./Scripts/test.sh
```

The suite exits non-zero on failure, so it works as a pre-commit hook or in CI.
It runs against real servers rather than mocks:

- **SFTP** is exercised against macOS's own `/usr/libexec/sftp-server`, which
  speaks the same wire protocol as a remote OpenSSH server. That covers the whole
  packet layer without needing a live `sshd`.
- **FTP** runs against a real `pyftpdlib` server on a random port, including a
  pass with `MLSD` disabled so the classic `LIST` parser is covered.

There is also an optional suite that runs over a genuine SSH connection, which is
the only way to cover the `ssh` invocation and a real server's quirks:

```sh
SFTPsurf_REAL_HOST=<bookmark-uuid> ./Scripts/test.sh
```

See the README for how to find a bookmark's id. That suite creates a scratch
folder on the server and removes it afterwards, including after a failure. Only
run it against a machine you are willing to have touched.

### A note on Swift concurrency

`Package.swift` pins `swiftLanguageMode(.v5)`. The code is `Sendable`-clean and
builds without warnings under Swift 6.2, but stays in language mode 5 so a
slightly older toolchain can still build it. If you move it to mode 6, please do
that as its own change with the warnings resolved, not mixed into a feature.

## Making changes

- **Keep the layers apart.** `SFTPsurfCore` is protocol and filesystem logic with
  no UI; `SFTPsurfUI` holds the views and the browser model; `SFTPsurf` is only
  the app entry point. Protocol code should not import SwiftUI.
- **Add a test when you fix a bug.** The interesting bugs in this project so far
  have all been found by testing against real servers: FTP transfers corrupting
  each other on a shared control connection, a `LIST` parser dropping execute
  bits, and SSH's stderr being discarded so every failure looked like a
  disconnect. Those all have regression tests now.
- **Match the surrounding style.** Comments explain *why*, not *what*. There is
  no formatter config; four-space indent, and keep lines under about 100 columns.
- **No new dependencies without discussing it first.** The project deliberately
  ships with zero third-party runtime dependencies, which is a large part of why
  it builds with Command Line Tools alone.

## Reporting bugs

Please include:

- macOS version and how you installed SFTPsurf (bundle, DMG, `swift run`)
- The protocol (SFTP or FTP), and the **server software** if you know it — OpenSSH,
  ProFTPD, vsftpd, IIS, a NAS, and so on
- What you did, what you expected, and what happened
- Any error message the app showed. If the app said "unexpectedly", it is worth
  running with `swift run SFTPsurf` from a terminal so `ssh`'s own messages appear
  on stderr

Please **do not** paste passwords, private keys, or full hostnames you would
rather not publish. A redacted error line is usually enough.

## Security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).

## Pull requests

Small and focused beats large and sweeping. In the description, say what changed,
why, and how you verified it — the commands you ran and what they printed. If you
changed anything user-visible, add a line to [CHANGELOG.md](CHANGELOG.md) under
`Unreleased`.

## License

By contributing, you agree your work is released under the [MIT License](LICENSE).
