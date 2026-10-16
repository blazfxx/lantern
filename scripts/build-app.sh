#!/bin/bash
# Builds a self-contained Lantern.app (arm64) into dist/.
#   scripts/build-app.sh            -> dist/Lantern.app
#   scripts/build-app.sh --zip      -> also dist/Lantern-<version>-macos-arm64.zip
#   scripts/build-app.sh --dmg      -> also dist/Lantern-<version>-macos-arm64.dmg
# Requires: Xcode command line tools, CMake, Ninja, and `brew install capstone cpp-httplib nlohmann-json`.
# The analysis engine comes from the engine/ submodule (git submodule update --init).
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP=0; DMG=0
for a in "$@"; do case "$a" in --zip) ZIP=1;; --dmg) DMG=1;; *) echo "unknown option $a"; exit 2;; esac; done
[ -f engine/CMakeLists.txt ] || { echo "engine/ is empty — run: git submodule update --init"; exit 1; }

VERSION=$(tr -d '[:space:]' < VERSION)
DIST=dist
# Build + sign in a scratch dir: synced folders (iCloud Desktop/Documents) keep attaching Finder metadata,
# which makes codesign fail with "detritus not allowed".
STAGE=$(mktemp -d); APP="$STAGE/Lantern.app"; mkdir -p "$DIST"
echo "==> Lantern $VERSION"

echo "==> engine (static Capstone)"
cmake -S engine -B build-engine -G Ninja -DCMAKE_BUILD_TYPE=Release -DEREBUS_STATIC_CAPSTONE=ON >/dev/null
cmake --build build-engine --target erebus

echo "==> app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
swiftc -O app/Sources/*.swift -o "$APP/Contents/MacOS/Lantern" -framework Cocoa
cp build-engine/erebus "$APP/Contents/Resources/bin/erebus"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
sed "s/@VERSION@/$VERSION/g" app/Info.plist.in > "$APP/Contents/Info.plist"

echo "==> icon"
ICONSET=$(mktemp -d)/AppIcon.iconset
swift app/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc sign"
xattr -cr "$APP"
codesign --force --sign - "$APP/Contents/Resources/bin/erebus"
xattr -cr "$APP"; find "$APP" -name .DS_Store -delete
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "signature ok"

NAME="Lantern-$VERSION-macos-arm64"
if [ $ZIP = 1 ]; then rm -f "$DIST/$NAME.zip"; ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"; echo "==> $DIST/$NAME.zip"; fi
if [ $DMG = 1 ]; then
  DMGDIR=$(mktemp -d); cp -R "$APP" "$DMGDIR/"; ln -s /Applications "$DMGDIR/Applications"
  rm -f "$DIST/$NAME.dmg"; hdiutil create -quiet -volname "Lantern" -srcfolder "$DMGDIR" -ov -format UDZO "$DIST/$NAME.dmg"; echo "==> $DIST/$NAME.dmg"
fi
rm -rf "$DIST/Lantern.app"; ditto --noextattr --noqtn "$APP" "$DIST/Lantern.app"
echo "==> done: $DIST/Lantern.app"
