SyncMacPro 1.2.4 — vider l'historique, et les corrections des versions 1.2.2 et 1.2.3.

**Nouveau (1.2.4)**
- Historique › « Vider… » : vide tout l'historique, ou celui de la tâche choisie dans le filtre, après confirmation. Les journaux correspondants sont supprimés ; une exécution en cours est conservée ; tâches, fichiers et archives ne sont pas touchés. En ligne de commande : `syncmacpro-ctl history [tâche] --clear`.

**Corrections (1.2.3)**
- Après une mise à jour, l'agent d'arrière-plan pouvait encore rester arrêté (launchd refusait le nouvel agent, code 78). L'app attend que macOS ait vraiment retiré l'ancien agent, vérifie que le nouveau tourne, et sinon recommence : plus besoin de le réinstaller à la main.

**Corrections (1.2.2)**
- Une copie sur un disque ou un NAS qui ne répond plus ne reste plus « en cours » pour toujours : sans aucune activité pendant 20 minutes (pauses et veille exclues), elle est arrêtée et retentée plus tard.
- Gros volumes : l'avancement se calcule à coût constant. Une copie d'un million de fichiers ralentissait au fil du temps (jusqu'à freiner rsync) et occupait beaucoup plus de mémoire.
- Les échecs indiquent la vraie cause, expliquée en français (« Plus de place sur le disque de destination », « le disque ou le NAS a peut-être été débranché », « Dossier introuvable »…), au lieu de sa conséquence (« Broken pipe »).
- Synchronisation bidirectionnelle : une nouvelle tâche crée son dossier de destination ; quand bisync exige une réinitialisation (par exemple après un changement de casse seul dans un nom), elle est faite tout de suite, sans rien supprimer (la version remplacée est archivée), au lieu d'un échec et d'un nouvel essai une heure plus tard.
- Une vérification qui n'a pas pu se faire (NAS absent, réseau coupé) est retentée ; seule une vérification qui trouve des différences ne l'est pas.
- Finitions : lecture plus sûre de la version des programmes embarqués, nom de tâche ambigu signalé par `syncmacpro-ctl log`, avertissements de compilation.

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
