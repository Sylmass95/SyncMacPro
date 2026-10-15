# Programmes tiers inclus dans SyncMacPro

SyncMacPro (licence MIT, voir `LICENSE`) embarque deux programmes indépendants, lancés comme des programmes séparés,
et la bibliothèque Sparkle (mises à jour automatiques). Ils ne sont pas modifiés.

## Sparkle 2.10.0

- Licence : **MIT**, avec les licences des composants qu'elle inclut (texte complet : `Sparkle-LICENSE.txt`).
- © Andy Matuschak, Elgato Systems, Kornel Lesiński, Mayur Pawashe et les contributeurs de Sparkle —
  https://sparkle-project.org/ — code source : https://github.com/sparkle-project/Sparkle
- Distribution officielle 2.10.0 (paquet Swift Package Manager), services XPC retirés, signée ad hoc avec l'app.

## rsync 3.5.1

- Licence : **GNU General Public License, version 3 ou ultérieure** (texte complet : `rsync-COPYING`).
- © Andrew Tridgell, Wayne Davison et les contributeurs de rsync — https://rsync.samba.org/
- Code source correspondant : l'archive `rsync-3.5.1.tar.gz` est jointe à chaque publication de SyncMacPro
  (https://github.com/Sylmass95/SyncMacPro/releases) ; elle est identique à
  https://download.samba.org/pub/rsync/src/rsync-3.5.1.tar.gz (SHA-256
  `c55f9c9dc10fb8bec397b399a0fdded53cc9a2d8e30891bb0d63724d25c37bef`).
- Construction : `scripts/fetch-vendor.sh` du dépôt SyncMacPro (binaire universel arm64 + x86_64, macOS 14 minimum,
  `./configure --disable-xxhash --disable-zstd --disable-lz4 --disable-openssl --disable-md2man --disable-idn
  --with-included-popt --with-included-zlib`).

## rclone 1.75.1

- Licence : **MIT** (texte complet et liste des auteurs : `rclone-LICENSE.txt`).
- © Nick Craig-Wood et les contributeurs de rclone — https://rclone.org/ — code source : https://github.com/rclone/rclone
- Binaires officiels `rclone-v1.75.1-osx-arm64.zip` et `rclone-v1.75.1-osx-amd64.zip` (https://downloads.rclone.org/v1.75.1/,
  empreintes identiques au fichier `SHA256SUMS` officiel), réunis en un binaire universel par `lipo`.
