#!/bin/bash
# Télécharge, vérifie et prépare rsync (compilé, universel) et rclone (officiel, universel).
#
#   scripts/fetch-vendor.sh [DOSSIER]     (défaut : .build/vendor)
#
# Seules les archives sont gardées d'une fois sur l'autre (src/, revérifiées à chaque fois) : bin/ est toujours
# reconstruit à partir d'elles, un binaire en cache n'est jamais réutilisé tel quel.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/vendor.lock
OUT="${1:-.build/vendor}"
mkdir -p "$OUT/bin" "$OUT/licenses" "$OUT/src" "$OUT/work"
OUT="$(cd "$OUT" && pwd)"

download() {   # URL FICHIER EMPREINTE
  local url="$1" file="$2" sum="$3" try=0
  if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sum" ]; then return 0; fi
  rm -f "$file"
  until curl -fsSL -m 600 -o "$file.part" "$url"; do
    try=$((try + 1)); rm -f "$file.part"
    [ "$try" -ge 6 ] && { echo "Téléchargement impossible : $url" >&2; exit 1; }
    echo "  nouvel essai ($try) : $url" >&2; sleep $((try * 10))
  done
  local actual; actual="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
  if [ "$actual" != "$sum" ]; then
    rm -f "$file.part"
    echo "Empreinte inattendue pour $url : $actual (attendu $sum)" >&2; exit 1
  fi
  mv "$file.part" "$file"
}

echo "==> rsync $RSYNC_VERSION"
TGZ="$OUT/src/rsync-$RSYNC_VERSION.tar.gz"
download "$RSYNC_URL" "$TGZ" "$RSYNC_SHA256"
rm -f "$OUT/bin/rsync" "$OUT/bin/rclone"
{
  rm -rf "$OUT/work/rsync"; mkdir -p "$OUT/work/rsync"
  tar -xzf "$TGZ" -C "$OUT/work/rsync" --strip-components 1
  (
    cd "$OUT/work/rsync"
    export MACOSX_DEPLOYMENT_TARGET=14.0
    CFLAGS="-O2 -arch arm64 -arch x86_64" LDFLAGS="-arch arm64 -arch x86_64" ./configure \
      --disable-xxhash --disable-zstd --disable-lz4 --disable-openssl --disable-md2man --disable-idn \
      --with-included-popt --with-included-zlib > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -20 make.log; exit 1; }
  )
  cp "$OUT/work/rsync/rsync" "$OUT/bin/rsync"
  cp "$OUT/work/rsync/COPYING" "$OUT/licenses/rsync-COPYING"
}

echo "==> rclone $RCLONE_VERSION"
download "$RCLONE_ARM64_URL" "$OUT/src/rclone-arm64.zip" "$RCLONE_ARM64_SHA256"
download "$RCLONE_AMD64_URL" "$OUT/src/rclone-amd64.zip" "$RCLONE_AMD64_SHA256"
{
  rm -rf "$OUT/work/rclone"; mkdir -p "$OUT/work/rclone"
  unzip -q "$OUT/src/rclone-arm64.zip" -d "$OUT/work/rclone/arm64"
  unzip -q "$OUT/src/rclone-amd64.zip" -d "$OUT/work/rclone/amd64"
  lipo -create "$OUT"/work/rclone/arm64/*/rclone "$OUT"/work/rclone/amd64/*/rclone -output "$OUT/bin/rclone"
}
# Licence MIT de rclone : la section « License » du README.txt de l'archive officielle.
awk '/^License$/{buf=""; found=1} found{buf = buf $0 "\n"} END{printf "%s", buf}' "$OUT"/work/rclone/arm64/*/README.txt > "$OUT/licenses/rclone-LICENSE.txt"
[ -s "$OUT/licenses/rclone-LICENSE.txt" ] || { echo "Licence de rclone introuvable dans l'archive" >&2; exit 1; }

for tool in rsync rclone; do
  lipo "$OUT/bin/$tool" -verify_arch arm64 x86_64 || { echo "$tool n'est pas universel" >&2; exit 1; }
done
RSYNC_LINE="$("$OUT/bin/rsync" --version | sed -n 1p)"
RCLONE_LINE="$("$OUT/bin/rclone" version | sed -n 1p)"
case "$RSYNC_LINE" in "rsync  version $RSYNC_VERSION "*) ;; *) echo "rsync construit : version inattendue ($RSYNC_LINE)" >&2; exit 1 ;; esac
[ "$RCLONE_LINE" = "rclone v$RCLONE_VERSION" ] || { echo "rclone : version inattendue ($RCLONE_LINE)" >&2; exit 1; }
echo "    $RSYNC_LINE"
echo "    $RCLONE_LINE"
