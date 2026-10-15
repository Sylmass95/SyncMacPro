# SyncMacPro — sous-projet 7 : sauvegarde sur disque amovible

Date : 2026-10-15 · Statut : conception validée par l'auteur (conversation du 15/10) · Version visée : **1.4.0**

## 1. Objectif

Faire de temps en temps une sauvegarde physique sur un disque externe sans le laisser branché : la sauvegarde part
quand on branche **ce** disque, se met en pause si on le débranche, reprend au rebranchement, et repart sur une
comparaison complète si l'interruption est ancienne. En fin de sauvegarde, le disque peut être éjecté.

### Succès
- Brancher le disque : la sauvegarde démarre seule (à chaque fois, ou si la dernière réussite a plus de N jours, au choix).
- Le débrancher en pleine copie : la tâche affiche « En pause : disque débranché » (pas d'échec) ; le rebrancher le
  lendemain : la même exécution continue et finit avec un seul bilan.
- Le rebrancher une semaine plus tard (au-delà du délai de reprise) : l'exécution interrompue est close, une nouvelle
  part et recompare tout, sans recopier ce qui est déjà identique.
- Un autre disque du même nom n'est jamais pris pour le bon.
- À la fin : notification ; selon la tâche, bouton « Éjecter » ou éjection automatique.

## 2. Décisions

| Sujet | Décision |
|---|---|
| Identité du disque | **Identifiant unique du volume** (`volumeUUIDString`) mémorisé avec le nom affiché et le chemin relatif du dossier sur le disque. Monté ailleurs (« Extreme Pro 1 »), il est retrouvé ; un autre disque du même nom ne l'est pas |
| Détection | L'agent s'abonne à DiskArbitration (volume monté, démonté, apparu, disparu), file dédiée ; le minuteur de 15 s reste une sécurité. Au montage : 5 s d'attente avant d'agir (disque prêt) |
| Déclenchement (choix de l'auteur : C) | Par tâche : **à chaque branchement**, ou **au plus une fois tous les N jours** (part au branchement si la dernière réussite a plus de N jours ; sinon rien). Les conditions habituelles (secteur, plage horaire) s'appliquent. La tâche reste lançable à la main |
| Débranchement (choix de l'auteur : A) | En pleine exécution, disque démonté ou arraché : le moteur est arrêté, l'exécution est **suspendue** (« En pause : disque débranché depuis … »), ni échec ni nouvel essai. Un échec du moteur alors que le volume a disparu est traité de même (course entre l'erreur d'entrée/sortie et l'avis de démontage) |
| Reprise | Rebranché **dans le délai de reprise** (3 jours par défaut, réglable 1 à 30) : la **même exécution** continue (même ligne d'historique, bilans additionnés). Au-delà : l'exécution suspendue est close « interrompue » et une **nouvelle** part (comparaison complète ; rien d'identique n'est recopié). Bouton « Abandonner » pendant la suspension |
| Place | Une exécution suspendue ne compte pas dans les 2 exécutions simultanées. Elle survit à un redémarrage de l'agent (enregistrée) |
| Éjection | Par tâche : **non** (notification « vous pouvez éjecter … »), **bouton** (« Éjecter » sur la carte, dans la miniature et le menu de la barre, actif quand le disque est branché et la tâche au repos), **automatique** (à la fin d'une réussite, seulement si rien d'autre n'utilise le disque). Éjection par DiskArbitration (démontage du disque entier puis éjection) ; refus (fichier ouvert) : message clair |
| Modes | Copie, miroir, versions, déplacement vers le disque. Miroir : le garde-fou de suppression reste (disque rebranché vide ou reformaté) |
| Disque plein | Échec avec son message (pas une suspension) |
| Contrat XPC | Version 4 inchangée : `SyncTask.removableDrive` facultatif ; `AgentTaskInfo.driveSuspendedSince`, `driveMounted` facultatifs ; état d'attente par `waiting(reason:)` existant ; requêtes `abandonSuspended(UUID)`, `ejectDrive(UUID)` |
| `ctl` | `eject <tâche>`, `abandon <tâche>` ; `status` affiche « disque débranché depuis … » |
| Hors périmètre | Source sur disque amovible avec destination ailleurs (seule la destination est concernée) ; plusieurs disques en rotation pour une même tâche ; chiffrement du disque |

## 3. Côté agent

- `RemovableDrive { volumeUUID, volumeName, relativePath, trigger: everyConnection | atMostEveryDays(Int), resumeWindowDays, eject: never | button | automatic }` dans `SyncTask` (facultatif au décodage).
- `DriveMonitor` (protocole, faux pour les tests) : volumes montés `[uuid: mountPath]`, événements montage / démontage. Réel : DiskArbitration.
- `AgentCore` : à chaque montage d'un volume connu, tâche liée due ? (déclencheur, conditions) → lancement, ou reprise d'une exécution suspendue dans le délai. Au démontage : exécutions liées → suspension. Chemin de destination résolu au lancement : `mountPath + relativePath`.
- `TaskScheduleState.suspendedRun: SuspendedRun? { recordID, since, summary }` : l'exécution suspendue, enregistrée.
- Fin d'exécution d'une tâche liée : éjection automatique si demandée et si aucune autre exécution n'utilise le volume ; notification.

## 4. Côté app

- Éditeur : destination sur un volume externe (non interne, non réseau) → section « Disque amovible » : déclencheur, délai de reprise, éjection ; aperçu « Disque : Extreme Pro (identifiant …) ».
- Cartes, miniature, menu de la barre : « En pause : disque débranché depuis 2 h », « Abandonner » ; « Éjecter » selon le réglage.

## 5. Corrections mineures de la 1.3.0 (même version)

1. Tâche désactivée retirée de la file ; mise en file refusée pour une tâche désactivée.
2. Tâche en file lancée en dehors de la file : retirée de la file.
3. « Lancer » masqué sur une copie ponctuelle en file.
4. Bilan d'une copie ponctuelle terminée gardé dans Tâches › Copies jusqu'à fermeture.
5. Comptage des dossiers rclone arrêté quand la copie a réussi (plus d'attente en fin d'exécution).
6. Vitesse moyenne du bilan calculée sur le temps actif (pauses exclues).
7. Garde-fou rsync : « \ » échappé seulement si le chemin contient aussi `*`, `?` ou `[`.
8. Réglages › Réseau : « modifié » posé seulement par une saisie de l'utilisateur.
9. Fermer la miniature par ✕ rouvre la grande fenêtre.
10. Au démarrage de l'agent, la file attend les types de connexion avant de répartir les plafonds.
11. Message « Cette tâche n'est pas dans la file » pour un élément absent.

## 6. Tests

- Agent avec faux `DriveMonitor` et fausse horloge : montage → lancement (chaque fois / au plus tous les N jours), démontage en route → suspension (et échec moteur + volume absent → suspension), remontage dans le délai → même exécution, au-delà → nouvelle, abandon, redémarrage de l'agent pendant une suspension, autre disque du même nom ignoré, monté ailleurs retrouvé, éjection automatique (refusée si une autre exécution utilise le volume).
- Correspondance des volumes (UUID, chemin relatif), éditeur (détection d'un volume externe), rendus (carte suspendue, bouton Éjecter), textes FR/EN.
- Chaque correction mineure : un test qui la reproduit.
- Réel : image disque APFS montée comme disque externe, branchée / débranchée en pleine copie / rebranchée ; avance d'horloge simulée pour le délai ; éjection automatique.

## 7. Risques

| Risque | Parade |
|---|---|
| DiskArbitration dans un agent launchd | Session sur une file dédiée ; essai réel avec une image disque ; minuteur de 15 s en secours |
| Arrachage : rsync échoue avant l'avis de démontage | Échec + volume absent = suspension |
| Volume sans UUID (certains formats) | Repli sur nom + taille du volume, signalé dans l'éditeur |
| Éjection refusée (Spotlight, fichier ouvert) | Message, bouton toujours disponible |
