#!/bin/bash
# Creates the virtualenv used by the FTP integration tests.
#
# The tests run against a real FTP server (pyftpdlib) rather than a mock, which
# is what caught the single-control-connection serialisation bug. Without this
# venv the FTP tests skip themselves; SFTP tests use macOS's own sftp-server and
# always run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv-test"

echo "==> Creating $VENV"
python3 -m venv "$VENV"

echo "==> Installing pyftpdlib"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet pyftpdlib

if "$VENV/bin/python" -c "import pyftpdlib" 2>/dev/null; then
    echo "==> Ready. Run Scripts/test.sh"
else
    echo "    ! pyftpdlib did not import" >&2
    exit 1
fi
