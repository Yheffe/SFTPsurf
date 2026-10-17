#!/bin/bash
# Captures screenshots of the running app.
#
# The app renders its own window, so this needs no Screen Recording permission.
# It boots the bundled Python FTP server so the connected shot shows real remote
# content, and points the local pane at a throwaway folder so captures never
# include the user's own files.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/screenshots}"
APP="$ROOT/dist/SFTPsurf.app"
BINARY="$APP/Contents/MacOS/SFTPsurf"
PYTHON="$ROOT/.venv-test/bin/python"
WINDOW_SIZE="${WINDOW_SIZE:-1360x820}"

mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/*.txt

if [[ ! -x "$BINARY" ]]; then
    echo "==> App not built; bundling first"
    "$ROOT/Scripts/bundle.sh" release >/dev/null || exit 1
fi

SERVER_PID=""
LOCAL_SAMPLE=""
SUPPORT_DIR=""
SERVER_ROOT=""

cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    [[ -n "$LOCAL_SAMPLE" ]] && rm -rf "$LOCAL_SAMPLE"
    [[ -n "$SUPPORT_DIR" ]] && rm -rf "$SUPPORT_DIR"
    [[ -n "$SERVER_ROOT" ]] && rm -rf "$SERVER_ROOT"
}
trap cleanup EXIT

app_running() {
    ps -Ao comm= 2>/dev/null | grep -q "SFTPsurf.app/Contents/MacOS/SFTPsurf"
}

quit_app() {
    osascript -e 'tell application "SFTPsurf" to quit' >/dev/null 2>&1
    # LaunchServices will not start a fresh instance until the old one is gone,
    # so wait rather than guessing at a sleep.
    for _ in $(seq 1 40); do
        app_running || return 0
        sleep 0.25
    done
    echo "    ! a previous instance is still running" >&2
    return 1
}

# LaunchServices is what lets SwiftUI create the WindowGroup, so the app is
# started with `open`. It writes its own diagnostics to the log file because
# `open` detaches the process's standard streams.
#
# A windowless instance would swallow every later launch, so lingering
# processes are cleared out first and the whole sequence is retried.
app_pids() {
    ps -Ao pid=,comm= 2>/dev/null | grep "SFTPsurf.app/Contents/MacOS/SFTPsurf" | awk '{print $1}'
}

stop_app() {
    local pids
    pids="$(app_pids)"
    [[ -z "$pids" ]] && return 0
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    for _ in $(seq 1 40); do
        [[ -z "$(app_pids)" ]] && return 0
        sleep 0.25
    done
    for pid in $(app_pids); do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 0.5
}

run_capture() {
    local log="$OUT/.launch.log"
    local config="$OUT/.capture-config.json"

    for attempt in 1 2 3; do
        rm -f "$log" "$config" "$OUT"/[0-9][0-9]-*.png "$OUT"/[0-9][0-9]-*.txt
        stop_app
        sleep 1

        python3 -c '
import json, sys
capture_set, local_dir, support_dir, window_size, log, port, destination = sys.argv[1:8]
config = {
    "captureSet": capture_set,
    "localDirectory": local_dir,
    "supportDirectory": support_dir,
    "windowSize": window_size,
    "dumpHierarchy": True,
    "log": log,
}
if port != "-":
    config["connect"] = {
        "kind": "ftp", "host": "127.0.0.1", "port": int(port),
        "username": "tester", "password": "hunter2",
    }
open(destination, "w").write(json.dumps(config))
' "$OUT" "$LOCAL_SAMPLE" "$SUPPORT_DIR" "$WINDOW_SIZE" "$log" "$1" "$config"

        open -n "$APP" --args "$config"

        for _ in $(seq 1 90); do
            [[ -f "$OUT/04-connection-sheet.png" ]] && { sleep 0.5; stop_app; return 0; }
            sleep 0.5
        done

        echo "    ! attempt $attempt did not finish" >&2
        [[ -s "$log" ]] && sed 's/^/      /' "$log" >&2
        stop_app
        sleep 1
    done
    return 1
}

# A throwaway folder for the left pane, sized to exercise the byte formatter.
LOCAL_SAMPLE="$(mktemp -d)"
SUPPORT_DIR="$(mktemp -d)"
mkdir -p "$LOCAL_SAMPLE"/{website,screenshots,node_modules}
dd if=/dev/zero of="$LOCAL_SAMPLE/annual-report.pdf"    bs=1024 count=83   2>/dev/null
dd if=/dev/zero of="$LOCAL_SAMPLE/promo-video.mp4"     bs=1024 count=2355 2>/dev/null
dd if=/dev/zero of="$LOCAL_SAMPLE/index.html"          bs=1    count=12004 2>/dev/null
dd if=/dev/zero of="$LOCAL_SAMPLE/archive.zip"         bs=1024 count=95   2>/dev/null
dd if=/dev/zero of="$LOCAL_SAMPLE/notes.md"            bs=1    count=2140 2>/dev/null
dd if=/dev/zero of="$LOCAL_SAMPLE/screenshots/home.png" bs=1024 count=412 2>/dev/null
dd if=/dev/zero of="$LOCAL_SAMPLE/website/app.js"      bs=1    count=48213 2>/dev/null

# --- A live FTP session ------------------------------------------------------------
if [[ ! -x "$PYTHON" ]]; then
    echo "==> No test Python at $PYTHON" >&2
    echo "    (run Scripts/setup-test-deps.sh to enable the connected screenshots)" >&2
    exit 1
fi

SERVER_ROOT="$(mktemp -d)"
mkdir -p "$SERVER_ROOT"/{releases,shared,logs,backups}
dd if=/dev/zero of="$SERVER_ROOT/deploy.tar.gz"               bs=1024 count=1219 2>/dev/null
dd if=/dev/zero of="$SERVER_ROOT/dump.sql"                    bs=1024 count=215  2>/dev/null
dd if=/dev/zero of="$SERVER_ROOT/README.md"                   bs=1    count=4318 2>/dev/null
dd if=/dev/zero of="$SERVER_ROOT/.env"                        bs=1    count=66   2>/dev/null
dd if=/dev/zero of="$SERVER_ROOT/backups/site-2026-10-14.tar" bs=1024 count=8204 2>/dev/null

"$PYTHON" "$ROOT/Scripts/test-ftp-server.py" \
    --root "$SERVER_ROOT" --port 0 > "$SERVER_ROOT/.server.log" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 60); do
    PORT="$(grep -o 'READY [0-9]*' "$SERVER_ROOT/.server.log" 2>/dev/null | head -1 | awk '{print $2}' || true)"
    [[ -n "$PORT" ]] && break
    sleep 0.25
done

if [[ -z "$PORT" ]]; then
    echo "    ! FTP server did not start:" >&2
    cat "$SERVER_ROOT/.server.log" >&2
    exit 1
fi

# --- Capture -----------------------------------------------------------------------
echo "==> Capturing against 127.0.0.1:$PORT"
run_capture "$PORT" || true

echo ""
echo "==> Screenshots in $OUT"
ls -la "$OUT" | grep -E "\.png$"
