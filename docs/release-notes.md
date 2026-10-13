SyncMacPro 1.2.1 — mise à jour sans perdre l'agent, et les corrections de la 1.2.0.

**Corrections (1.2.1)**
- Après une mise à jour, l'agent d'arrière-plan pouvait rester arrêté (macOS gardait l'ancien agent, refusé pour sa signature). L'app attend désormais que macOS l'ait retiré avant de le réenregistrer, et répare d'elle-même un agent installé qui ne répond pas.

**Corrections (1.2.0)**
- Synchronisation bidirectionnelle : elle échouait dès que les chemins des deux dossiers étaient longs (au-delà de 255 caractères au total, par exemple un dossier Google Drive pour ordinateur et un NAS).
- Rouvrir l'app depuis le Dock ou le Finder montre de nouveau la fenêtre.
- Une tâche « toutes les N minutes » part à l'heure (elle partait jusqu'à une minute en retard à chaque fois).
- Une vérification qui trouve des différences n'est plus relancée automatiquement toutes les heures.
- L'app ne se fige plus sur un disque réseau lent : les dossiers sont lus en arrière-plan ; un disque démonté est détecté.
- Écran Copie : glisser un élément sélectionné emporte toute la sélection ; un dépôt impossible est expliqué.
- Connexions : annulation fiable, question reposée quand rclone refuse une réponse, vérifications renforcées des noms et des valeurs, assistant plus robuste.
- Messages plus clairs (sans codes de couleur), délai sur la vérification des programmes embarqués, nettoyage des fichiers de travail d'une tâche supprimée, finitions du thème verre, messages de mise à jour traduits.

**Installation** : ouvrez le DMG et glissez SyncMacPro dans Applications (remplace la version précédente ; l'agent est réenregistré automatiquement). L'app est signée « ad hoc » : au premier lancement, autorisez-la dans Réglages Système › Confidentialité et sécurité › « Ouvrir quand même » (macOS 15+) ou par clic droit › Ouvrir (macOS 14). macOS 14 ou plus récent, Apple Silicon et Intel. rsync 3.5.1 et rclone 1.75.1 sont inclus.

**Licences** : SyncMacPro (MIT) ; rsync (GPL v3, archive source jointe à cette publication) ; rclone (MIT).
