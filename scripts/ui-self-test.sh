#!/usr/bin/env bash
# Renders popover + settings off-screen and writes PNGs + layout report to /tmp.
# Use this when Computer Use cannot attach to the menu-bar-only app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/script/signing.sh"
APP="$ROOT/dist/wire.app"
BINARY="$APP/Contents/MacOS/wire"
OUT="${WIRE_UI_SELF_TEST_DIR:-/tmp/wire-ui-self-test}"

echo "Building wire…"
find "$ROOT/.build" -path '*/release/ModuleCache' -type d -prune -exec rm -rf {} + 2>/dev/null || true
swift build --disable-sandbox -c release --package-path "$ROOT"

rm -rf "$APP" "$OUT"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/wire" "$APP/Contents/MacOS/wire"
chmod +x "$APP/Contents/MacOS/wire"
cp "$ROOT/Assets/wire.icns" "$APP/Contents/Resources/wire.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>wire</string>
  <key>CFBundleIdentifier</key><string>local.wire</string>
  <key>CFBundleName</key><string>wire</string>
  <key>CFBundleDisplayName</key><string>wire</string>
  <key>CFBundleIconFile</key><string>wire</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>wire needs microphone access to record your voice for transcription.</string>
</dict>
</plist>
PLIST
sign_app "$APP"

pkill -x wire 2>/dev/null || true
sleep 0.2

echo "Running UI self-test → $OUT"
WIRE_UI_SELF_TEST=1 WIRE_UI_SELF_TEST_DIR="$OUT" "$BINARY" &
PID=$!

for _ in $(seq 1 40); do
  if [[ -f "$OUT/report.txt" ]]; then
    break
  fi
  sleep 0.25
done

if kill -0 "$PID" 2>/dev/null; then
  wait "$PID" || true
fi
pkill -x wire 2>/dev/null || true

if [[ ! -f "$OUT/report.txt" ]]; then
  echo "UI self-test failed: no report at $OUT/report.txt" >&2
  exit 1
fi

echo "Report:"
cat "$OUT/report.txt"
echo
ls -la "$OUT"

if rg -q 'ShortcutLines=[2-9]' "$OUT/report.txt"; then
  echo "FAIL: shortcut title appears multiline" >&2
  exit 1
fi

echo "OK: artifacts in $OUT"
