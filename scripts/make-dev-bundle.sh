#!/bin/bash
# Assemble SyncMacPro.app (signature ad hoc) : l'outil ctl comme exécutable principal,
# l'agent et son plist. SMAppService n'accepte d'enregistrer l'agent que depuis ce bundle.
#
#   scripts/make-dev-bundle.sh [DOSSIER]        (défaut : ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$HOME/Applications}"
APP="$OUT/SyncMacPro.app"
LABEL="com.sylvain.syncmacpro.agent"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/syncmacpro-ctl" "$BIN/syncmacpro-agent" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sylvain.syncmacpro</string>
  <key>CFBundleName</key><string>SyncMacPro</string>
  <key>CFBundleExecutable</key><string>syncmacpro-ctl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
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

codesign --force --sign - "$APP/Contents/MacOS/syncmacpro-agent"
codesign --force --sign - "$APP/Contents/MacOS/syncmacpro-ctl"
codesign --force --sign - "$APP"

echo "Bundle prêt : $APP"
echo "Installer l'agent : \"$APP/Contents/MacOS/syncmacpro-ctl\" agent install"
