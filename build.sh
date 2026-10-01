#!/bin/bash
# Builds MusicVisualizer.app. Requires only the Xcode Command Line Tools:
# the Metal shaders are compiled at runtime by the Metal framework itself.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="MusicVisualizer.app"
BIN="MusicVisualizer"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --disable-sandbox

BUILT="$(swift build -c "$CONFIG" --show-bin-path)/$BIN"

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT" "$APP/Contents/MacOS/$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Sources/MusicVisualizer/Render/Shaders.metal "$APP/Contents/Resources/Shaders.metal"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing…"
# Ad-hoc signature. macOS ties the audio-recording grant to this signature, so a
# rebuild can re-trigger the permission prompt once.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "✓ Built $(pwd)/$APP"
echo "  Run it with:  open $APP"
