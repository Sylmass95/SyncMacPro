SyncMacPro 1.4.0 — sauvegarde sur disque amovible.

**Nouveau (1.4.0)**
- Sauvegarde sur disque externe : une tâche liée à un disque part quand vous le branchez (à chaque fois, ou au plus une fois tous les N jours), se met en pause si vous le débranchez, et reprend au rebranchement ; après plusieurs jours (3 par défaut), une nouvelle sauvegarde repart sur une comparaison complète. Le disque est reconnu par son identifiant, même monté sous un autre nom.
- En fin de sauvegarde : notification, bouton « Éjecter » ou éjection automatique, au choix ; « Abandonner » pour une sauvegarde en pause.
- `syncmacpro-ctl eject <tâche>` et `syncmacpro-ctl abandon <tâche>`.

**Corrections (1.4.0)**
- Une tâche désactivée est retirée de la file et ne peut plus y être mise ; une tâche lancée hors de la file en est retirée.
- Une copie ponctuelle en file n'affiche plus « Lancer » ; le bilan d'une copie terminée reste dans Tâches › Copies jusqu'à ce que vous le fermiez.
- La fin d'une copie vers un service en ligne n'attend plus le comptage des dossiers.
- La vitesse moyenne du bilan ne compte plus le temps passé en pause.
- Le garde-fou des fichiers vides gère les noms qui contiennent « \ ».
- Réglages › Réseau n'envoie plus rien à l'agent à la simple ouverture ; fermer la miniature rouvre la grande fenêtre.
- Au démarrage, la file attend de connaître les connexions avant de répartir les plafonds de débit ; message clair pour un élément absent de la file.

**Nouveau (1.3.0)**
- File d'attente : « Mettre en file » sur une tâche ou une copie, puis « Lancer la file » ; les tâches partent une par une, dans l'ordre que vous choisissez (monter, descendre, retirer). Un échec ne bloque pas la file.
- Progression comme RsyncGUI : fichiers et dossiers faits sur le total, vitesse moyenne, temps écoulé ; le bilan reste affiché sur la carte et dans l'historique.
- Mode miniature (⌥⌘M ou le bouton de la barre d'outils) : une petite fenêtre toujours visible avec les transferts en cours et la file.
- Réglages › Réseau : plafonds de réception et d'envoi internet et du réseau local, en Mbit/s comme speedtest, appliqués aux copies en cours ; les copies d'un même sens se partagent le plafond.
- Garde-fou : un fichier vide à la source ne remplace plus une version non vide à la destination (cas d'un fichier que Drive pour ordinateur n'a pas fini d'envoyer).
- `syncmacpro-ctl queue …` et `syncmacpro-ctl bandwidth …`.

**Corrections (1.3.0)**
- Une tâche manuelle n'affiche plus « Prochaine : Sans échéance ».
- Le nombre d'erreurs ne compte plus plusieurs fois le même incident (une nouvelle tentative de rclone).

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
