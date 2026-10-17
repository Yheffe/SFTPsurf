#!/bin/bash
# Produces the screenshots that ship in the repository (docs/screenshots/).
#
# These are deliberately sanitised: everything shown is generated locally, so no
# real hostname, path or file name from anyone's machine ends up in the docs.
# Concretely it:
#   * points both panes at throwaway folders filled with generic deployment files
#   * redirects bookmarks and preferences to a scratch directory, so the sidebar
#     shows pretend connections and your own bookmarks are never touched
#   * serves the "remote" pane from a local pyftpdlib instance on a random port,
#     so no network access is needed and the address reads as a local demo
#   * uses only RFC 2606 reserved hostnames (example.com) in the sidebar
#
# Needs Screen Recording permission, because it uses `screencapture`.
#
# Usage:
#   Scripts/make-docs-screenshots.sh [output-dir]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/SFTPsurf.app"
BINARY="$APP/Contents/MacOS/SFTPsurf"
PYTHON="$ROOT/.venv-test/bin/python"
OUT="${1:-$ROOT/docs/screenshots}"
WINDOW_SIZE="1360x820"

mkdir -p "$OUT"
rm -f "$OUT"/*.png

if [[ ! -x "$BINARY" ]]; then
    echo "==> App not built; bundling first"
    "$ROOT/Scripts/bundle.sh" release >/dev/null || exit 1
fi

if [[ ! -x "$PYTHON" ]]; then
    echo "==> No test Python at $PYTHON" >&2
    echo "    Run Scripts/setup-test-deps.sh first." >&2
    exit 1
fi

SERVER_PID=""
# Deliberately a literal /tmp path: it shows up in the screenshots, and a
# resolved /var/folders path would look like a leak from a real machine.
DEMO_ROOT="/tmp/sftpsurf-docs-demo"
LOCAL_DEMO="$DEMO_ROOT/local"
REMOTE_DEMO="$DEMO_ROOT/remote"
SUPPORT_DIR=""

cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    [[ -n "$SUPPORT_DIR" ]] && rm -rf "$SUPPORT_DIR"
    # The demo tree is kept when the run failed, so the logs can be read.
    [[ "${KEEP_DEMO:-}" == "1" ]] || rm -rf "$DEMO_ROOT"
    # A windowless instance would swallow later launches.
    for pid in $(ps -Ao pid=,comm= | grep "SFTPsurf.app/Contents/MacOS/SFTPsurf" | awk '{print $1}'); do
        kill "$pid" 2>/dev/null
    done
}
trap cleanup EXIT

stop_app() {
    osascript -e 'tell application "SFTPsurf" to quit' >/dev/null 2>&1
    for _ in $(seq 1 12); do
        ps -Ao comm= | grep -q "SFTPsurf.app/Contents/MacOS/SFTPsurf" || return 0
        sleep 0.25
    done
    for pid in $(ps -Ao pid=,comm= | grep "SFTPsurf.app/Contents/MacOS/SFTPsurf" | awk '{print $1}'); do
        kill "$pid" 2>/dev/null
    done
    sleep 0.5
}

# --- Generic content for both panes ------------------------------------------
echo "==> Building a throwaway demo tree"
rm -rf "$DEMO_ROOT"
mkdir -p "$LOCAL_DEMO/site" "$LOCAL_DEMO/screenshots" "$REMOTE_DEMO"/{releases,shared,logs,backups}

dd if=/dev/zero of="$LOCAL_DEMO/index.html"        bs=1    count=12104 2>/dev/null
dd if=/dev/zero of="$LOCAL_DEMO/styles.css"        bs=1    count=4096  2>/dev/null
dd if=/dev/zero of="$LOCAL_DEMO/app.js"            bs=1    count=48213 2>/dev/null
dd if=/dev/zero of="$LOCAL_DEMO/notes.md"          bs=1    count=2140  2>/dev/null
dd if=/dev/zero of="$LOCAL_DEMO/archive.zip"       bs=1024 count=96    2>/dev/null
dd if=/dev/zero of="$LOCAL_DEMO/site.json"         bs=1    count=1024  2>/dev/null
dd if=/dev/zero of="$LOCAL_DEMO/screenshots/home.png" bs=1024 count=278 2>/dev/null

dd if=/dev/zero of="$REMOTE_DEMO/deploy.tar.gz"     bs=1024 count=1219 2>/dev/null
dd if=/dev/zero of="$REMOTE_DEMO/README.md"         bs=1    count=4318 2>/dev/null
dd if=/dev/zero of="$REMOTE_DEMO/docker-compose.yml" bs=1   count=2048 2>/dev/null
dd if=/dev/zero of="$REMOTE_DEMO/backups/site-2026-10-14.tar" bs=1024 count=8204 2>/dev/null
dd if=/dev/zero of="$REMOTE_DEMO/releases/v2.4.1.tar.gz"      bs=1024 count=1150 2>/dev/null

# --- Isolated app state, with pretend bookmarks -------------------------------
# Redirecting the support directory means the real bookmarks file is never read
# or written; the sidebar below shows only these placeholders.
SUPPORT_DIR="$(mktemp -d)"
# The support-directory override *is* the app-support folder, so bookmarks.json
# sits directly inside it rather than in a nested SFTPsurf directory.
/usr/bin/python3 - "$SUPPORT_DIR/bookmarks.json" <<'PY'
import json, sys, uuid

def bookmark(nickname, kind, host, username, auth="password"):
    # `privateKey` carries a path in Swift, so it needs one here; a malformed
    # entry makes the app quarantine the whole file and show no bookmarks.
    if auth == "privateKey":
        auth_method = {"privateKey": {"path": "~/.ssh/id_ed25519"}}
    else:
        auth_method = {auth: {}}

    return {
        "id": str(uuid.uuid4()).upper(),
        "nickname": nickname,
        "kind": kind,
        "host": host,
        "port": 22 if kind == "sftp" else 21,
        "username": username,
        "authMethod": auth_method,
        "initialPath": "",
        "sshOptions": [],
        "ftpPassive": True,
        "ftpUTF8": True,
    }

# example.com is reserved for documentation by RFC 2606, so nothing here can
# point at a real machine.
bookmarks = [
    bookmark("Acme Production", "sftp", "acme-prod.example.com", "deploy"),
    bookmark("Acme Staging", "sftp", "acme-staging.example.com", "deploy",
             auth="privateKey"),
    bookmark("Media Archive", "ftp", "archive.example.com", "guest"),
]
open(sys.argv[1], "w").write(json.dumps(bookmarks))
PY

# --- Local "server" ----------------------------------------------------------
"$PYTHON" "$ROOT/Scripts/test-ftp-server.py" \
    --root "$REMOTE_DEMO" --port 0 --user deploy --password demo \
    > "$DEMO_ROOT/server.log" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 60); do
    PORT="$(grep -o 'READY [0-9]*' "$DEMO_ROOT/server.log" 2>/dev/null | head -1 | awk '{print $2}' || true)"
    [[ -n "$PORT" ]] && break
    sleep 0.25
done
[[ -n "$PORT" ]] || { echo "    ! the demo FTP server did not start" >&2; exit 1; }
echo "==> Demo server on 127.0.0.1:$PORT"

# --- Capture -----------------------------------------------------------------
window_id_for() {
    swift "$ROOT/Scripts/window-info.swift" "$1" 2>/dev/null | awk '{print $1}'
}

capture() {
    local label="$1" hold="$2" demo="$3"
    local log="$DEMO_ROOT/launch.log"
    local config="$DEMO_ROOT/config.json"

    stop_app
    rm -f "$log"

    /usr/bin/python3 -c "
import json, sys
cfg = {
    'localDirectory': sys.argv[1],
    'supportDirectory': sys.argv[2],
    'windowSize': sys.argv[3],
    'holdSeconds': float(sys.argv[4]),
    'log': sys.argv[5],
    'appearance': 'light',
    'connect': {
        'kind': 'ftp', 'host': '127.0.0.1', 'port': int(sys.argv[6]),
        'username': 'deploy', 'password': 'demo', 'nickname': 'Acme Staging',
    },
}
if sys.argv[7] == 'yes':
    cfg['demoTransfers'] = True
open(sys.argv[8], 'w').write(json.dumps(cfg))
" "$LOCAL_DEMO" "$SUPPORT_DIR" "$WINDOW_SIZE" "$hold" "$log" "$PORT" "$demo" "$config"

    open -n "$APP" --args "$config"

    for _ in $(seq 1 60); do
        grep -q "connected to" "$log" 2>/dev/null && break
        grep -q "connect failed" "$log" 2>/dev/null && { sed 's/^/      /' "$log" >&2; return 1; }
        sleep 0.5
    done
    grep -q "connected to" "$log" 2>/dev/null || { echo "    ! never connected" >&2; return 1; }

    sleep "$( [[ "$demo" == "yes" ]] && echo 4 || echo 2 )"

    local pid
    pid=$(ps -Ao pid=,comm= | grep "[S]FTPsurf.app/Contents/MacOS" | awk '{print $1}' | head -1)
    local win
    win=$(window_id_for "$pid")
    [[ -n "$win" ]] || { echo "    ! could not locate the window" >&2; return 1; }

    screencapture -x -o -l "$win" "$OUT/$label.png" 2>/dev/null
    if [[ ! -s "$OUT/$label.png" ]]; then
        echo "    ! capture produced nothing" >&2
        return 1
    fi

    # A window that has not been redrawn yet would produce a duplicate of the
    # previous shot, which is worse than retrying.
    local digest
    digest="$(md5 -q "$OUT/$label.png")"
    if [[ -n "${PREVIOUS_DIGEST:-}" && "$digest" == "$PREVIOUS_DIGEST" ]]; then
        echo "    ! $label.png is identical to the previous shot; retrying" >&2
        return 2
    fi
    PREVIOUS_DIGEST="$digest"

    echo "  ✅ $label.png ($(( $(stat -f%z "$OUT/$label.png") / 1024 )) KB)"
    stop_app
}

# capture_with_retry wraps capture, treating "identical to the last shot" as a
# retryable failure.
capture_with_retry() {
    local label="$1" hold="$2" demo="$3" attempt rc
    for attempt in 1 2 3; do
        capture "$label" "$hold" "$demo"
        rc=$?
        [[ "$rc" == "0" ]] && return 0
        [[ "$rc" != "2" ]] && return "$rc"
        sleep 2
    done
    echo "    ! $label.png could not be captured distinctly" >&2
    return 1
}

echo "==> Capturing into $OUT"
PREVIOUS_DIGEST=""
failures=0
capture_with_retry "browsing"  20 no  || failures=$((failures + 1))
capture_with_retry "transfers" 30 yes || failures=$((failures + 1))
[[ "$failures" == "0" ]] || { echo "==> $failures capture(s) failed" >&2; exit 1; }

echo ""
echo "==> Done. These are what the README references."
ls -la "$OUT" | grep -E "\.png$"
