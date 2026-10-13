#!/bin/bash
# Bundle de développement (architecture de la machine) : même assemblage que la version publiée ; rsync et rclone
# sont embarqués s'ils sont déjà préparés (scripts/fetch-vendor.sh). SMAppService n'accepte d'enregistrer l'agent que depuis ce bundle.
#
#   scripts/make-dev-bundle.sh [DOSSIER]        (défaut : ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$HOME/Applications}"
APP="$OUT/SyncMacPro.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

# Un agent resté enregistré avec l'ancienne signature ne démarre plus après une reconstruction du bundle
# (launchd : « Launch Constraint Violation ») : on le désenregistre avant de remplacer le bundle.
if [ -x "$APP/Contents/MacOS/syncmacpro-ctl" ]; then
  "$APP/Contents/MacOS/syncmacpro-ctl" agent uninstall >/dev/null 2>&1 || true
fi
VENDOR=""
[ -x .build/vendor/bin/rsync ] && [ -x .build/vendor/bin/rclone ] && VENDOR=.build/vendor
scripts/assemble-app.sh "$BIN" "$APP" "$(tr -d '[:space:]' < VERSION)" "$(git rev-list --count HEAD)" $VENDOR

echo "Bundle prêt : $APP"
echo "Ouvrir l'app : open \"$APP\""
echo "Installer l'agent : \"$APP/Contents/MacOS/syncmacpro-ctl\" agent install   (ou Réglages › Agent dans l'app)"
