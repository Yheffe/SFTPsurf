# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Instead, use
GitHub's [private vulnerability reporting][advisory] on this repository, or
contact the maintainer directly if that is unavailable.

Please include what you did, what happened, and what you think the impact is. A
minimal reproduction helps enormously. You should get a reply within a few days.
Credit is offered in the release notes unless you would rather stay anonymous.

[advisory]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability

## How SFTPsurf handles credentials

This is a file transfer client, so it touches secrets by design. It is worth
being explicit about what it does, because it shapes what counts as a
vulnerability here.

**Passwords** live in the login keychain, stored per bookmark id rather than per
host, so two bookmarks for the same server can hold different credentials. Items
use `kSecAttrAccessibleAfterFirstUnlock`. Nothing is written to disk in plain
text. Passwords are never placed on a command line.

**Private keys** are never read, parsed, or copied by SFTPsurf. They are handled
entirely by `/usr/bin/ssh`, so the same rules apply as when you use `ssh`
directly: whatever OpenSSH can read works, including `ssh-agent` and hardware
tokens, and passphrase-protected keys stay protected.

**Password authentication over SSH** needs `ssh` to be handed a password without
a terminal, and OpenSSH's only supported mechanism for that is `SSH_ASKPASS`. So
SFTPsurf writes the password to a `0600` file inside a `0700` directory created
with `mkdtemp`, points `SSH_ASKPASS` at a small script that cats it, and deletes
the directory as soon as the handshake completes. The window is short but the
secret does touch the filesystem. This is inherent to driving `ssh` as a
subprocess; if that trade-off is unacceptable to you, use key authentication.

**Host keys** are pinned trust-on-first-use in SFTPsurf's own
`known_hosts` under Application Support, seeded once from `~/.ssh/known_hosts`.
A changed key is a hard failure, not a prompt to accept. This means an existing
`accept-new` policy cannot be silently downgraded by the app.

**FTP** sends credentials in clear text, because the protocol does. That is a
property of FTP, not a bug. Use SFTP unless you specifically need FTP.

**Nothing is sent anywhere else.** There is no telemetry, no analytics, no
update check, and no network traffic beyond the server you ask it to connect to.

## What is in scope

- Bypassing host key verification, or the app treating a changed key as trusted
- A credential leaking outside the keychain, such as into a log, a temp file that
  is not cleaned up, a crash report, or a command line visible in `ps`
- Path traversal in remote path handling, where a crafted listing or path escapes
  the directory the user is browsing
- Memory-safety issues in the socket or process transport layers
- Command or argument injection into the `ssh` invocation via a bookmark field

## What is out of scope

- FTP sending credentials unencrypted, and FTPS not being supported
- Anyone with read access to your login keychain being able to read its secrets —
  that is the keychain's threat model
- The app being ad-hoc signed rather than notarised, and Gatekeeper warning about
  it. Release artefacts are built locally; see the README
- Vulnerabilities in OpenSSH itself or in `sftp-server`. Report those upstream
- Anything requiring an attacker to already have code execution as your user

## Supported versions

The latest release is supported. This is a small project, so there are no
backports to older tags; fixes land on `main` and go out in the next release.
