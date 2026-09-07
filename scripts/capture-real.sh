#!/bin/bash
# Captures the documentation images from the running application.
#
# The images this replaces were rendered offscreen from invented data. Neither
# half of that could show the window as it actually is — see Capture.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-docs}"
CONTROL="${TMPDIR:-/tmp}/wattson-capture.json"
PAGES=(overview cpu gpu memory sensors battery disk network inference processes history away events)

[ -x scripts/.winid ] || swiftc -O scripts/winid.swift -o scripts/.winid
[ -x scripts/.parkmouse ] || swiftc -O scripts/parkmouse.swift -o scripts/.parkmouse

echo "==> building"
./scripts/build-app.sh >/dev/null

pkill -x Wattson 2>/dev/null || true
while pgrep -x Wattson >/dev/null; do sleep 1; done

echo '{"page":"overview","appearance":"dark","language":"en"}' > "$CONTROL"
WATTSON_CAPTURE_CONTROL="$CONTROL" ./dist/Wattson.app/Contents/MacOS/Wattson &
APP=$!
trap 'kill $APP 2>/dev/null || true' EXIT

echo "==> waiting for the engine to collect real readings"
sleep 45

ID=""
for _ in $(seq 30); do
    ID=$(./scripts/.winid Wattson 2>/dev/null || true)
    [ -n "$ID" ] && break
    sleep 2
done
[ -n "$ID" ] || { echo "main window never appeared" >&2; exit 1; }

mkdir -p "$OUT"
for variant in "dark en" "light zh"; do
    set -- $variant
    APPEARANCE=$1 LANGUAGE=$2
    for page in "${PAGES[@]}"; do
        printf '{"page":"%s","appearance":"%s","language":"%s"}\n' \
            "$page" "$APPEARANCE" "$LANGUAGE" > "$CONTROL"
        ./scripts/.parkmouse
        sleep 1.2
        caffeinate -u -t 1 &
        screencapture -x -o -l "$ID" "$OUT/$page-$APPEARANCE-$LANGUAGE.png"
        printf '  %s-%s-%s\n' "$page" "$APPEARANCE" "$LANGUAGE"
    done
done
echo "==> wrote $(ls "$OUT"/*.png | wc -l | tr -d ' ') images to $OUT"
