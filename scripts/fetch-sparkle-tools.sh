#!/bin/bash
# Télécharge et vérifie les outils de Sparkle (sign_update, generate_keys) : signature du flux de mise à jour.
#
#   scripts/fetch-sparkle-tools.sh [DOSSIER]     (défaut : .build/sparkle-tools)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/vendor.lock
OUT="${1:-.build/sparkle-tools}"
mkdir -p "$OUT/bin" "$OUT/src"
ARCHIVE="$OUT/src/Sparkle-$SPARKLE_VERSION.tar.xz"
if ! { [ -f "$ARCHIVE" ] && [ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" = "$SPARKLE_SHA256" ]; }; then
  rm -f "$ARCHIVE"
  try=0
  until curl -fsSL -m 600 -o "$ARCHIVE.part" "$SPARKLE_URL"; do
    try=$((try + 1)); rm -f "$ARCHIVE.part"
    [ "$try" -ge 6 ] && { echo "Téléchargement impossible : $SPARKLE_URL" >&2; exit 1; }
    sleep $((try * 10))
  done
  actual="$(shasum -a 256 "$ARCHIVE.part" | cut -d' ' -f1)"
  [ "$actual" = "$SPARKLE_SHA256" ] || { rm -f "$ARCHIVE.part"; echo "Empreinte inattendue pour $SPARKLE_URL : $actual" >&2; exit 1; }
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xJf "$ARCHIVE" -C "$WORK" ./bin/sign_update ./bin/generate_keys
cp "$WORK/bin/sign_update" "$WORK/bin/generate_keys" "$OUT/bin/"
echo "Outils de Sparkle $SPARKLE_VERSION : $OUT/bin"
