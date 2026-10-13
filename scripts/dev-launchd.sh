#!/bin/bash
# Agent de développement sans bundle : launchctl déclare le service Mach (un processus lancé à la main ne le peut pas).
# Données dans ~/Library/Application Support/SyncMacPro-dev, service « com.sylvain.syncmacpro.agent.dev ».
#
#   scripts/dev-launchd.sh install | uninstall | status
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.sylvain.syncmacpro.agent.dev"
DATA="$HOME/Library/Application Support/SyncMacPro-dev"
PLIST="$DATA/$LABEL.plist"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
  install)
    swift build
    mkdir -p "$DATA"
    cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$PWD/.build/debug/syncmacpro-agent</string>
    <string>--state-dir</string><string>$DATA</string>
    <string>--mach-service</string><string>$LABEL</string>
    <string>--startup-hold</string><string>0</string>
  </array>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardErrorPath</key><string>$DATA/agent.log</string>
</dict></plist>
XML
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "Agent de développement lancé. Essayer :"
    echo "  .build/debug/syncmacpro-ctl status --service $LABEL --state-dir \"$DATA\""
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Agent de développement retiré (les données restent dans $DATA)."
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | head -12 || echo "non installé"
    ;;
  *)
    echo "Usage : $0 install | uninstall | status" >&2
    exit 64
    ;;
esac
