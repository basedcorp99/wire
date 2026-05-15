#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/script/signing.sh"
APP="$ROOT/dist/wire.app"
BINARY="$APP/Contents/MacOS/wire"

needs_build=0
if [[ ! -x "$BINARY" ]]; then
  needs_build=1
else
  while IFS= read -r file; do
    if [[ "$file" -nt "$BINARY" ]]; then
      needs_build=1
      break
    fi
  done < <(find "$ROOT/Sources" -type f -name '*.swift'; printf '%s\n' "$ROOT/Package.swift" "$ROOT/Assets/wire.icns")
fi

package_app() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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
}

if [[ "$needs_build" == "1" ]]; then
  echo "Building wire…"
  swift build -c release --package-path "$ROOT"
  package_app
else
  sign_app "$APP"
fi

open "$APP" || true
