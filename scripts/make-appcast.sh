#!/bin/bash
# Flux de mise à jour (Sparkle) pour un DMG publié : une entrée, signée (archive et flux), puis vérifiée.
#
#   scripts/make-appcast.sh DMG FICHIER_CLÉ_PRIVÉE SORTIE.xml
#
# FICHIER_CLÉ_PRIVÉE : clé EdDSA de l'auteur (base64), jamais versionnée (secret SPARKLE_ED_PRIVATE_KEY à la publication).
# SPARKLE_TOOLS : dossier de sign_update (défaut .build/sparkle-tools/bin, voir fetch-sparkle-tools.sh).
# APPCAST_DOWNLOAD_PREFIX : adresse du DMG (défaut : la release GitHub de la version ; autre valeur pour un essai local).
set -euo pipefail
DMG="$1"; KEY="$2"; OUT="$3"
TOOLS="${SPARKLE_TOOLS:-$(cd "$(dirname "$0")/.." && pwd)/.build/sparkle-tools/bin}"
SIGN="$TOOLS/sign_update"
[ -s "$KEY" ] || { echo "Clé privée de mise à jour absente ou vide : $KEY" >&2; exit 1; }
[ -x "$SIGN" ] || { echo "sign_update introuvable ($SIGN) : lancez scripts/fetch-sparkle-tools.sh" >&2; exit 1; }
[ -f "$DMG" ] || { echo "DMG introuvable : $DMG" >&2; exit 1; }

# Version et build lus dans l'app du DMG : ceux que Sparkle comparera à l'app installée.
MOUNT="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$MOUNT" "$DMG" >/dev/null
APP="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "Aucune app dans $DMG" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
BUILD="$(plist CFBundleVersion)"
VERSION="$(plist CFBundleShortVersionString)"
MINIMUM="$(plist LSMinimumSystemVersion 2>/dev/null || echo 14.0)"
hdiutil detach "$MOUNT" -quiet

NAME="$(basename "$DMG")"
PREFIX="${APPCAST_DOWNLOAD_PREFIX:-https://github.com/Sylmass95/SyncMacPro/releases/download/v$VERSION/}"
LENGTH="$(stat -f%z "$DMG")"
SIGNATURE="$("$SIGN" --ed-key-file "$KEY" -p "$DMG")"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SyncMacPro</title>
    <item>
      <title>SyncMacPro $VERSION</title>
      <pubDate>$DATE</pubDate>
      <link>https://github.com/Sylmass95/SyncMacPro/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <enclosure url="$PREFIX$NAME" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
# Flux signé (SURequireSignedFeed), puis tout est revérifié avec la même clé avant d'être publié.
"$SIGN" --ed-key-file "$KEY" "$OUT" >/dev/null
"$SIGN" --verify --ed-key-file "$KEY" "$OUT" >/dev/null || { echo "Flux : vérification impossible" >&2; exit 1; }
"$SIGN" --verify --ed-key-file "$KEY" "$DMG" "$SIGNATURE" >/dev/null || { echo "DMG : vérification impossible" >&2; exit 1; }
echo "Flux de mise à jour : $OUT (SyncMacPro $VERSION, build $BUILD)"
