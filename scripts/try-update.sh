#!/bin/bash
# Essai réel des mises à jour automatiques, de bout en bout, sans toucher à SyncMacPro installé :
# une app d'essai (update-probe : vrai UpdateModel et vrai pilote Sparkle, identifiant com.sylvain.syncmacpro.updateprobe,
# aucun agent) passe de la version 1 à la version 2 par un DMG et un flux produits par make-appcast.sh, servis en local ;
# puis une version 3 dont le DMG est modifié après signature doit être refusée.
#
#   scripts/try-update.sh [DOSSIER_DE_TRAVAIL]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
PORT=8767
ID=com.sylvain.syncmacpro.updateprobe
LOG="$WORK/probe.log"

scripts/fetch-sparkle-tools.sh >/dev/null
swift build --package-path Tools/update-probe --product update-probe >/dev/null
BIN="$(swift build --package-path Tools/update-probe --show-bin-path)"

# Clé d'essai jetable (jamais celle de l'auteur).
cat > "$WORK/cle.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try! key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
PUBLIC="$(swift "$WORK/cle.swift" "$WORK/cle.txt" 2>/dev/null)"

bundle() {   # VERSION DOSSIER_APP
  local version="$1" app="$2"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
  cp "$BIN/update-probe" "$app/Contents/MacOS/"
  cp -R "$BIN/Sparkle.framework" "$app/Contents/Frameworks/"
  rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
  install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/update-probe"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>UpdateProbe</string>
  <key>CFBundleExecutable</key><string>update-probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.$version.0</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>ProbeLog</key><string>$LOG</string>
  <key>SUFeedURL</key><string>http://127.0.0.1:$PORT/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$PUBLIC</string>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
  codesign --force --deep --sign - "$app/Contents/Frameworks/Sparkle.framework" 2>/dev/null
  codesign --force --sign - "$app" 2>/dev/null
}

release() {   # VERSION : DMG comme celui de make-release.sh (app + raccourci Applications), puis flux signé
  local version="$1" stage="$WORK/stage$1"
  rm -rf "$stage"; mkdir -p "$stage"
  bundle "$version" "$stage/UpdateProbe.app"
  ln -s /Applications "$stage/Applications"
  rm -f "$WORK/feed/"*.dmg
  hdiutil create -volname "UpdateProbe $version" -srcfolder "$stage" -ov -format UDZO "$WORK/feed/UpdateProbe-$version.dmg" >/dev/null
  APPCAST_DOWNLOAD_PREFIX="http://127.0.0.1:$PORT/" scripts/make-appcast.sh "$WORK/feed/UpdateProbe-$version.dmg" "$WORK/cle.txt" "$WORK/feed/appcast.xml" >/dev/null
}

installed() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$WORK/apps/UpdateProbe.app/Contents/Info.plist"; }

run_until() {   # MOTIF : lance l'app installée et attend la ligne MOTIF du journal (2 min au plus)
  open -n "$WORK/apps/UpdateProbe.app"
  for _ in $(seq 1 120); do grep -q "$1" "$LOG" 2>/dev/null && return 0; sleep 1; done
  return 1
}

cleanup() {
  pkill -f "http.server $PORT" 2>/dev/null || true
  pkill -f "$WORK/apps/UpdateProbe.app" 2>/dev/null || true
  defaults delete "$ID" >/dev/null 2>&1 || true
  defaults delete update-probe >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID"
}
trap cleanup EXIT
cleanup
mkdir -p "$WORK/feed" "$WORK/apps"; : > "$LOG"
bundle 1 "$WORK/apps/UpdateProbe.app"
release 2
(cd "$WORK/feed" && exec python3 -I -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
sleep 1

echo "== 1 → 2 : mise à jour et relance"
run_until "v2 fin" || { cat "$LOG"; echo "ÉCHEC : la version 2 n'a pas tourné" >&2; exit 1; }
[ "$(installed)" = 2 ] || { cat "$LOG"; echo "ÉCHEC : version installée $(installed)" >&2; exit 1; }
grep -E "v1 (état|pilote)|v2 lancée" "$LOG"

echo "== 2 → 3 falsifiée : refus"
release 3
printf 'falsifié' >> "$WORK/feed/UpdateProbe-3.dmg"
: > "$LOG"
run_until "v2 fin" || { cat "$LOG"; echo "ÉCHEC : l'essai n'a pas fini" >&2; exit 1; }
grep -q "état failed" "$LOG" || { cat "$LOG"; echo "ÉCHEC : la version falsifiée n'a pas été refusée" >&2; exit 1; }
[ "$(installed)" = 2 ] || { cat "$LOG"; echo "ÉCHEC : version falsifiée installée" >&2; exit 1; }
grep -E "état" "$LOG" | cut -c1-200
echo "Essai réussi : mise à jour 1 → 2 installée et relancée, version 3 falsifiée refusée."
