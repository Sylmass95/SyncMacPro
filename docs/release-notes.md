SyncMacPro 1.1.1 — mises à jour sans perdre l'agent.

**Corrections**
- Après le remplacement de l'app par une nouvelle version, l'agent d'arrière-plan ne redémarrait plus (macOS refusait de
  lancer l'agent enregistré par l'ancienne version). L'app le réenregistre désormais elle-même au premier lancement.
- Test d'une connexion : jusqu'à 60 s (le premier appel à Google Drive peut être lent) et message clair si le service ne
  répond pas.
- Règles de confidentialité publiées (`PRIVACY.md`).

Inclut la nouvelle apparence de la 1.1.0 (thème verre, styles « intense » et « léger »).

**Installation** : ouvrez le DMG et glissez SyncMacPro dans Applications (remplace la version précédente). L'app est signée
« ad hoc » : au premier lancement, autorisez-la dans Réglages Système › Confidentialité et sécurité › « Ouvrir quand même »
(macOS 15+) ou par clic droit › Ouvrir (macOS 14). macOS 14 ou plus récent, Apple Silicon et Intel. rsync 3.5.1 et rclone
1.75.1 sont inclus.

**Licences** : SyncMacPro (MIT) ; rsync (GPL v3, archive source jointe à cette publication) ; rclone (MIT).
