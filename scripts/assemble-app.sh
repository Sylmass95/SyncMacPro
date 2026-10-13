#!/bin/bash
# Assemble SyncMacPro.app à partir des exécutables compilés, puis la signe (ad hoc), de l'intérieur vers l'extérieur.
#
#   scripts/assemble-app.sh DOSSIER_BIN APP VERSION BUILD [DOSSIER_VENDOR]
#
# DOSSIER_VENDOR (sortie de fetch-vendor.sh) : rsync et rclone embarqués dans Contents/Resources/bin, avec leurs licences.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$1"; APP="$2"; VERSION="$3"; BUILD="$4"; VENDOR="${5:-}"
# Le dossier est supprimé puis recréé : on refuse tout chemin qui ne désigne pas une app.
case "$APP" in
  *.app) ;;
  *) echo "Chemin d'app attendu (…/SyncMacPro.app), reçu : « $APP »" >&2; exit 2 ;;
esac
LABEL="com.sylvain.syncmacpro.agent"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents" "$APP/Contents/Resources/Licenses"
cp "$BIN/SyncMacPro" "$BIN/syncmacpro-ctl" "$BIN/syncmacpro-agent" "$APP/Contents/MacOS/"
# Ressources de l'interface (chaînes fr / en) : SwiftPM les place dans des « .bundle » à côté des exécutables.
for resources in "$BIN"/*.bundle; do
  case "$resources" in *Tests.bundle) continue ;; esac   # ressources des tests : pas dans l'app
  [ -e "$resources" ] && cp -R "$resources" "$APP/Contents/Resources/"
done
cp THIRD_PARTY_NOTICES.md LICENSE "$APP/Contents/Resources/Licenses/"

if [ -n "$VENDOR" ]; then
  mkdir -p "$APP/Contents/Resources/bin"
  cp "$VENDOR/bin/rsync" "$VENDOR/bin/rclone" "$APP/Contents/Resources/bin/"
  cp "$VENDOR"/licenses/* "$APP/Contents/Resources/Licenses/"
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sylvain.syncmacpro</string>
  <key>CFBundleName</key><string>SyncMacPro</string>
  <key>CFBundleDisplayName</key><string>SyncMacPro</string>
  <key>CFBundleExecutable</key><string>SyncMacPro</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© Sylvain Masson — licence MIT. rsync (GPL v3) et rclone (MIT) embarqués.</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string><string>en</string></array>
</dict></plist>
PLIST

cat > "$APP/Contents/Library/LaunchAgents/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>BundleProgram</key><string>Contents/MacOS/syncmacpro-agent</string>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <!-- Relance l'agent après un plantage ou un SIGKILL ; une sortie réussie (SIGTERM, désinstallation) ne le relance pas. -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PLIST

# Signature ad hoc, de l'intérieur vers l'extérieur (une signature englobante exige des signatures internes valides).
if [ -d "$APP/Contents/Resources/bin" ]; then
  for tool in "$APP"/Contents/Resources/bin/*; do codesign --force --sign - "$tool"; done
fi
# L'exécutable principal en dernier : sa signature couvre les autres programmes de Contents/MacOS.
for exe in syncmacpro-agent syncmacpro-ctl SyncMacPro; do codesign --force --sign - "$APP/Contents/MacOS/$exe"; done
codesign --force --sign - "$APP"
echo "App assemblée : $APP ($VERSION, construction $BUILD)"
