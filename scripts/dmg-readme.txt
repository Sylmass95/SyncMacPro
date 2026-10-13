SyncMacPro — installation
=========================

1. Glissez SyncMacPro dans le dossier Applications (à droite).
2. Ouvrez-la depuis Applications.

SyncMacPro est signée « ad hoc » (sans compte Apple Developer) : au premier lancement, macOS l'arrête.
- macOS 15 et suivants : ouvrez l'app, fermez l'avertissement, puis Réglages Système › Confidentialité et sécurité ›
  « Ouvrir quand même » (en bas), et confirmez.
- macOS 14 : clic droit (ou Ctrl-clic) sur l'app › Ouvrir › Ouvrir.
- Ou, dans le Terminal : xattr -dr com.apple.quarantine /Applications/SyncMacPro.app

L'accueil installe ensuite l'agent d'arrière-plan (macOS peut demander de l'autoriser dans Réglages Système ›
Général › Ouverture). rsync et rclone sont inclus : rien d'autre à installer.

Licences : SyncMacPro (MIT), rsync (GPL v3), rclone (MIT) — Réglages › À propos › Licences.
Code source : https://github.com/Sylmass95/SyncMacPro


SyncMacPro — installation (English)
===================================

1. Drag SyncMacPro to the Applications folder (on the right).
2. Open it from Applications.

SyncMacPro is "ad hoc" signed (no Apple Developer account): macOS stops it on first launch.
- macOS 15 and later: open the app, dismiss the warning, then System Settings › Privacy & Security ›
  "Open Anyway" (at the bottom), and confirm.
- macOS 14: right-click (or Control-click) the app › Open › Open.
- Or, in Terminal: xattr -dr com.apple.quarantine /Applications/SyncMacPro.app

The welcome screen then installs the background agent (macOS may ask you to allow it in System Settings ›
General › Login Items). rsync and rclone are included: nothing else to install.

Licenses: SyncMacPro (MIT), rsync (GPL v3), rclone (MIT) — Settings › About › Licenses.
Source code: https://github.com/Sylmass95/SyncMacPro
