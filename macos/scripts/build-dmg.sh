#!/bin/bash
# Builds a local, ad-hoc-signed release DMG for manual testing — the same
# steps as .github/workflows/native-release.yml, without pushing a tag or
# publishing anything. Mirrors the workflow so a local DMG behaves like the
# one CI would produce (sandboxed Release build, universal binary, same
# volume layout). xcodebuild's own preBuildScripts phase invokes
# build-ffi.sh with CONFIGURATION=Release, which builds both arm64 and
# x86_64 slices on its own — no separate FFI build step needed here.
#
# Output: Markive_local.dmg in the repo root.
set -euo pipefail
cd "$(dirname "$0")/../.."

xcodegen generate --spec macos/project.yml --project macos

xcodebuild -project macos/Markive.xcodeproj -scheme Markive \
    -configuration Release -derivedDataPath macos/DerivedData \
    CODE_SIGN_IDENTITY=- build

app=macos/DerivedData/Build/Products/Release/Markive.app
lipo -archs "$app/Contents/MacOS/Markive"
codesign -d --entitlements - "$app" | grep -q "com.apple.security.app-sandbox"

staging=$(mktemp -d)
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
cp macos/Resources/AppIcon.icns "$staging/.VolumeIcon.icns"
SetFile -a C "$staging"

dmg="Markive_local.dmg"
hdiutil create -volname "Markive" -srcfolder "$staging" -ov -format UDZO "$dmg"
rm -rf "$staging"

echo "Built $dmg"
echo "Quarantine won't be set locally, but if you copy it elsewhere first: xattr -dr com.apple.quarantine $dmg"
