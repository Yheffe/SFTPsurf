#!/bin/bash
# Captures real screenshots of the app on screen.
#
# Unlike Scripts/capture-ui.sh (where the app rasterises itself), this uses
# macOS `screencapture`, so the result is exactly what you see — including the
# translucent sidebar. That requires Screen Recording permission for whichever
# app runs this script.
#
# Usage:
#   Scripts/screenshot.sh <bookmark-uuid> [output-dir]
#
# Find a bookmark's uuid with:
#   python3 -c "import json,pathlib;print(*[b['id'] for b in json.loads((pathlib.Path.home()/'Library/Application Support/SFTPsurf/bookmarks.json').read_text())], sep='\n')"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/SFTPsurf.app"
BINARY="$APP/Contents/MacOS/SFTPsurf"
BOOKMARK="${1:-}"
OUT="${2:-$ROOT/build/screenshots-real}"

if [[ -z "$BOOKMARK" ]]; then
    echo "usage: $0 <bookmark-uuid> [output-dir]" >&2
    exit 2
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/.launch.log "$OUT"/.config.json

if [[ ! -x "$BINARY" ]]; then
    echo "==> App not built; bundling first"
    "$ROOT/Scripts/bundle.sh" release >/dev/null || exit 1
fi

LOCAL_SAMPLE="$(mktemp -d)"
mkdir -p "$LOCAL_SAMPLE"/{screenshots,notes}
dd if=/dev/zero of="$LOCAL_SAMPLE/report.pdf"   bs=1024 count=420 2>/dev/null
dd if=/dev/zero of="$LOCAL_SAMPLE/notes/todo.md" bs=1   count=3100 2>/dev/null
dd if=/dev/zero of="$LOCAL_SAMPLE/screenshots/home.png" bs=1024 count=260 2>/dev/null
dd if=/dev/zero of="$LOCAL_SAMPLE/archive.zip"  bs=1024 count=88 2>/dev/null

APP_PID=""
cleanup() {
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
    [[ -n "$LOCAL_SAMPLE" ]] && rm -rf "$LOCAL_SAMPLE"
    sleep 0.5
    # Belt and braces: a windowless instance would swallow later launches.
    for pid in $(ps -Ao pid=,comm= | grep "SFTPsurf.app/Contents/MacOS/SFTPsurf" | awk '{print $1}'); do
        kill "$pid" 2>/dev/null
    done
}
trap cleanup EXIT

stop_app() {
    # Ask nicely first so the app can finish any scripted cleanup.
    osascript -e 'tell application "SFTPsurf" to quit' >/dev/null 2>&1
    for _ in $(seq 1 12); do
        ps -Ao comm= | grep -q "SFTPsurf.app/Contents/MacOS/SFTPsurf" || return 0
        sleep 0.25
    done
    for pid in $(ps -Ao pid=,comm= | grep "SFTPsurf.app/Contents/MacOS/SFTPsurf" | awk '{print $1}'); do
        kill "$pid" 2>/dev/null
    done
    for _ in $(seq 1 40); do
        ps -Ao comm= | grep -q "SFTPsurf.app/Contents/MacOS/SFTPsurf" || return 0
        sleep 0.25
    done
}

# Reports the on-screen window id and bounds for a pid, as "id x y w h".
window_geometry() {
    swift "$ROOT/Scripts/window-info.swift" "$1" 2>/dev/null
}

capture_window() {
    local label="$1" hold="$2" demo="$3"
    local log="$OUT/.launch.log"
    local config="$OUT/.config.json"

    stop_app
    rm -f "$log"
    /usr/bin/python3 -c "
import json, sys
cfg = {'bookmarkID': sys.argv[1], 'holdSeconds': float(sys.argv[2]),
       'log': sys.argv[4], 'localDirectory': sys.argv[6]}
if sys.argv[3] == 'yes':
    cfg['demoTransfers'] = True
    cfg['windowSize'] = '1360x820'
open(sys.argv[5], 'w').write(json.dumps(cfg))
" "$BOOKMARK" "$hold" "$demo" "$log" "$config" "$LOCAL_SAMPLE"

    open -n "$APP" --args "$config"
    APP_PID=$(ps -Ao pid=,comm= | grep "[S]FTPsurf.app/Contents/MacOS" | awk '{print $1}' | head -1)

    # Wait for the connection to actually complete.
    for _ in $(seq 1 60); do
        grep -q "connected to" "$log" 2>/dev/null && break
        grep -qE "connect failed" "$log" 2>/dev/null && break
        sleep 0.5
    done
    if ! grep -q "connected to" "$log" 2>/dev/null; then
        echo "    ! never connected:" >&2
        sed 's/^/      /' "$log" >&2
        return 1
    fi

    # Let the list settle and any demo transfers start.
    sleep "$( [[ "$demo" == "yes" ]] && echo 4 || echo 2 )"

    local pid
    pid=$(ps -Ao pid=,comm= | grep "[S]FTPsurf.app/Contents/MacOS" | awk '{print $1}' | head -1)
    local geometry
    geometry=$(window_geometry "$pid")
    if [[ -z "$geometry" ]]; then
        echo "    ! could not locate the window for pid $pid" >&2
        return 1
    fi
    read -r win_id x y w h <<<"$geometry"
    echo "    window $win_id at ${w%.*}x${h%.*}"

    # -l captures the window itself, so no desktop or other windows intrude.
    if ! screencapture -x -o -l "$win_id" "$OUT/$label.png" 2>/dev/null; then
        # Fall back to a rect capture if the window id form is unavailable.
        screencapture -x -R "${x%.*},${y%.*},${w%.*},${h%.*}" "$OUT/$label.png"
    fi

    if [[ -s "$OUT/$label.png" ]]; then
        echo "  ✅ $label.png ($(( $(stat -f%z "$OUT/$label.png") / 1024 )) KB)"
    else
        echo "    ! capture produced no file" >&2
        return 1
    fi

    grep -E "connected to" "$log" | sed 's/^/    /'
    stop_app
}

echo "==> Capturing with macOS screencapture into $OUT"
capture_window "01-browsing"  20 no
capture_window "02-transfers" 30 yes

echo ""
echo "==> Screenshots in $OUT"
ls -la "$OUT" | grep -E "\.png$"
