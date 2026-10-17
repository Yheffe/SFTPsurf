#!/usr/bin/env python3
"""Throwaway FTP server for SFTPsurf's integration tests.

Prints `READY <port>` on stdout once it is listening (pass --port 0 to have the
kernel choose a free port), then serves until killed.
"""
import argparse
import logging
import sys

try:
    from pyftpdlib.authorizers import DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler
    from pyftpdlib.servers import FTPServer
except ImportError:  # pragma: no cover - reported to the caller as a skip
    print("MISSING pyftpdlib", file=sys.stderr)
    sys.exit(3)


def build_handler(enable_mlsd: bool):
    """Returns an FTPHandler subclass, optionally without MLSD/MLST.

    Dropping those commands lets the tests exercise the plain `LIST` parser,
    which is what older servers force on every client.
    """
    if enable_mlsd:
        return FTPHandler

    class ListOnlyHandler(FTPHandler):
        pass

    for command in ("MLSD", "MLST"):
        ListOnlyHandler.proto_cmds.pop(command, None)
    return ListOnlyHandler


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--root", required=True)
    parser.add_argument("--user", default="tester")
    parser.add_argument("--password", default="hunter2")
    parser.add_argument("--no-mlsd", action="store_true", help="serve LIST only")
    parser.add_argument("--verbose", action="store_true", help="keep pyftpdlib's logging")
    args = parser.parse_args()

    # The tests only care about the READY line on stdout, and a noisy stderr
    # would otherwise flood the parent's pipes.
    if not args.verbose:
        logging.disable(logging.CRITICAL)

    authorizer = DummyAuthorizer()
    authorizer.add_user(args.user, args.password, args.root, perm="elradfmwMT")

    handler = build_handler(enable_mlsd=not args.no_mlsd)
    handler.authorizer = authorizer
    # Keep passive data connections on a small, predictable port range.
    handler.passive_ports = range(60100, 60140)
    handler.masquerade_address = args.host

    server = FTPServer((args.host, args.port), handler)
    bound_port = server.socket.getsockname()[1]
    print(f"READY {bound_port}", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
