#!/bin/bash
# Builds and launches Markive as a .app bundle. `swift run` starts an unbundled
# binary, and macOS denies its self-activation unless the terminal is still
# frontmost at launch — the window then opens buried with no Dock bounce.
# A bundle started via `open` always activates.
set -euo pipefail
cd "$(dirname "$0")"

swift build

app=.build/debug/Markive.app
mkdir -p "$app/Contents/MacOS"

# Wait for a previous instance to fully exit — `open` on a dying instance
# routes to it instead of launching the new binary.
if pkill -f "Markive.app/Contents/MacOS/Markive" 2>/dev/null; then
    while pgrep -f "Markive.app/Contents/MacOS/Markive" >/dev/null; do sleep 0.1; done
fi
cp .build/debug/Markive "$app/Contents/MacOS/Markive"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>codes.darius.markive-prototype</string>
	<key>CFBundleName</key>
	<string>Markive</string>
	<key>CFBundleExecutable</key>
	<string>Markive</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

open "$app"
