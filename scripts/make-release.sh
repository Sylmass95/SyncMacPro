#!/bin/bash
# Construit build/SyncMacPro-<VERSION>.dmg : app universelle, rsync et rclone embarqués, signature ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT=build
APP="$OUT/stage/SyncMacPro.app"
DMG="$OUT/SyncMacPro-$VERSION.dmg"

scripts/fetch-vendor.sh .build/vendor
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
rm -rf "$OUT/stage" "$DMG"; mkdir -p "$OUT/stage"
scripts/assemble-app.sh "$BIN" "$APP" "$VERSION" "$BUILD_NUMBER" .build/vendor
for exe in "$APP"/Contents/MacOS/* "$APP"/Contents/Resources/bin/*; do
  lipo "$exe" -verify_arch arm64 x86_64 || { echo "$exe n'est pas universel" >&2; exit 1; }
done
codesign --verify --deep --strict "$APP"
ln -s /Applications "$OUT/stage/Applications"
cp scripts/dmg-readme.txt "$OUT/stage/Lisez-moi - Read me.txt"
hdiutil create -volname "SyncMacPro $VERSION" -srcfolder "$OUT/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/stage"
shasum -a 256 "$DMG"
echo "DMG prêt : $DMG"
