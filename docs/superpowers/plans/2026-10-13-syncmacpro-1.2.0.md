# SyncMacPro 1.2.0 — corrections : plan

> Exécution native, en autonomie (superpowers:executing-plans). Chaque correction : test qui échoue d'abord, puis correction.

**Origine :** campagne de tests réels sur l'app 1.1.1 installée (13/10/2026) et défauts reportés par les relectures 3c, 4, 5 et thème verre.

## Constats de la campagne
- C1 Bidirectionnel en échec avec des chemins longs : rclone nomme verrou et listes d'après les deux chemins (> 255 caractères) ; messages pleins de codes couleur ANSI.
- C2 Rouvrir l'app (Dock, Finder, `open`) ne montre pas la fenêtre une fois fermée.
- C3 Une vérification qui trouve des différences est relancée toutes les heures (ce n'est pas une panne passagère).
- C4 « Toutes les 2 min » s'exécute toutes les 3 min : l'agent n'évalue la planification qu'une fois par minute.
- C5 Le dossier de travail bisync d'une tâche supprimée reste sur le disque.

## Tâches
1. **Moteurs** : bisync par alias rclone courts (variables `RCLONE_CONFIG_SMPA_*`), état marqué pour forcer une resynchronisation à la migration ; `--color NEVER` et retrait des codes ANSI des messages ; dossier de travail supprimé avec la tâche ; délai de 10 s sur la vérification de version d'un binaire.
2. **Agent** : pas de relance automatique d'une vérification en différence ; horloge toutes les 15 s ; noms de connexion validés à chaque étape, valeurs avec retour à la ligne refusées, `--` avant les arguments positionnels ; annulation reçue avant le démarrage de rclone retenue ; réponse rclone avec `Error` : la question est reposée avec le message ; `ctl log` retrouve les copies ponctuelles.
3. **App** : réouverture de la fenêtre ; liste des dossiers hors du fil principal ; démontage d'un volume détecté ; glisser toute la sélection ; dépôt d'un dossier dans lui-même expliqué ; garde de la liste distante annulée ; assistant (plafond des réponses automatiques, échec de suppression signalé, ajout désactivé hors ligne) ; délai client de configuration au-delà du pire cas de l'agent.
4. **Interface** : contraste du texte secondaire sur le fond, panneau de fichiers (ombre, bordure), sélecteur distant et journal en verre dense, fond de la fenêtre Réglages (⌘,), libellé d'accessibilité des barres de progression, colonne d'actions de Copie, messages de mise à jour traduits, « Afficher dans le Finder » vers l'original d'une app translocalisée, avertissement de compilation de `GlassButtonStyle`.
5. **Distribution** : droits minimaux du workflow de publication (lecture partout, écriture seulement pour publier, `persist-credentials: false`, publication seulement sur étiquette), empreinte du DMG publiée, garde sur `rm -rf` dans `assemble-app.sh`, notes de version, README (secrets en argument de rclone).
6. **Essai réel** sur l'app 1.2.0 publiée : bidirectionnel à chemins longs, cadence de 2 min, réouverture, mise à jour sans perdre l'agent.
