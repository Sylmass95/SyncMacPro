#!/bin/bash
# Construit build/SyncMacPro-<VERSION>.dmg : app universelle, rsync et rclone embarqués, signature ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
# Clé publique de mise à jour (voir README) : vérifiée avant toute construction, l'app ne s'assemble pas sans elle.
KEY_FILE="${SPARKLE_PUBLIC_KEY_FILE:-scripts/sparkle-public-key.txt}"
if [ -z "${SPARKLE_PUBLIC_KEY:-}" ] && [ ! -s "$KEY_FILE" ]; then
  echo "Clé publique de mise à jour absente ($KEY_FILE) : voir README, « Clé de mise à jour »." >&2; exit 1
fi
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
cp .build/vendor/src/rsync-*.tar.gz "$OUT/"   # source de rsync (GPL), publiée avec le DMG
ln -s /Applications "$OUT/stage/Applications"
cp scripts/dmg-readme.txt "$OUT/stage/Lisez-moi - Read me.txt"
hdiutil create -volname "SyncMacPro $VERSION" -srcfolder "$OUT/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/stage"
shasum -a 256 "$DMG"
echo "DMG prêt : $DMG"
