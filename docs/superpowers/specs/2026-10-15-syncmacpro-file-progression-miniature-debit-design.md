# SyncMacPro — sous-projet 6 : file d'attente, progression, miniature, débit

Date : 2026-10-15 · Statut : conception validée par l'auteur (conversation du 15/10) · Version visée : **1.3.0**

## 1. Objectif

Piloter de grosses copies (centaines de Go à plusieurs To, Drive ⇄ NAS) sans les lancer une à une à la main, en voyant
où elles en sont, sans saturer la connexion internet, et sans jamais remplacer une bonne copie par un fichier vide.

### Succès
- Mettre « COMMONS 05 » puis « COMMONS 01 » en file, lancer la file : elles partent l'une après l'autre ; l'ordre se
  change en cours de route.
- Pendant une copie : fichiers faits / total, dossiers faits / total, vitesse moyenne, temps écoulé (comme RsyncGUI) ;
  le même bilan reste affiché à la fin et dans l'historique.
- Une petite fenêtre flottante (mode miniature) montre les transferts en cours et la file, avec Pause, Reprendre, Arrêter.
- Réglages › Réseau : plafond de réception internet, d'envoi internet et du réseau local, en Mbit/s ; un changement
  s'applique aux copies en cours sans relancer l'app.
- Un fichier de 0 octet à la source ne remplace jamais une version non vide à la destination.

## 2. Décisions

| Sujet | Décision |
|---|---|
| Où vit la file | **Dans l'agent** (comme les tâches) : fonctionne app fermée, enregistrée sur le disque, la même pour l'app, la miniature et `ctl` |
| File | **Explicite** (choix de l'auteur, option A) : « Mettre en file » à côté de « Lancer ». Liste ordonnée de tâches ; on retire, on monte, on descend. « Lancer » reste immédiat ; les tâches programmées ne changent pas |
| Démarrage de la file | À la main : **Lancer la file** / **Suspendre la file**. Lancée, elle exécute ses éléments **un par un** (le suivant démarre quand le précédent se termine, quelle que soit l'issue) et continue avec ceux ajoutés en route ; vide, elle s'arrête. Suspendre laisse finir l'élément en cours et ne démarre plus rien |
| Place dans les exécutions | L'élément en cours de la file compte dans les 2 exécutions simultanées de l'agent ; s'il n'y a pas de place, il attend |
| Copies ponctuelles en file | Possibles depuis l'écran Copie (« Mettre en file »). Gardées en mémoire seulement : un redémarrage de l'agent les retire (inscrites « interrompues » dans l'historique, comme aujourd'hui) |
| Tâche absente | Une tâche supprimée ou désactivée est retirée de la file ; une tâche déjà en cours ne peut pas y être ajoutée |
| Progression | `ProgressInfo` gagne `dirsDone`, `totalDirs`, `averageSpeed` (facultatifs). rsync : dossiers lus dans sa sortie (déjà suivis). rclone : total des dossiers par un comptage en arrière-plan (`lsjson -R --dirs-only` de la source, filtres compris) ; un dossier est « fait » quand tous ses fichiers à copier le sont (fichiers suivis par les lignes « Copied » de rclone en `-v`) |
| Bilan | `RunSummary` gagne `directories` et `averageSpeed` (facultatifs). Affiché sur la carte après la fin (jusqu'au prochain lancement ou fermeture du bilan) et dans le détail de l'historique |
| Écran Tâches | Chaque ligne montre l'état et, pendant une exécution, une barre et la ligne d'avancement. Les copies ponctuelles apparaissent dans une section « Copies » (en cours, puis bilan jusqu'à fermeture). Section « File d'attente » avec l'ordre, flèches, Retirer, Lancer / Suspendre |
| « Prochaine » | Une tâche **manuelle** n'a plus de ligne « Prochaine » (carte, menu de la barre, liste) |
| Miniature | `NSPanel` flottant (niveau flottant, tous les bureaux, reste visible quand l'app n'est pas active), contenu SwiftUI : une carte par transfert en cours (nom, fichier en cours, barre, %, débit, écoulé, restant, fichiers / dossiers, Pause / Reprendre / Arrêter), puis la file en liste compacte. Entrée et sortie par un bouton et le menu Fenêtre (⌥⌘M) ; la grande fenêtre est masquée pendant le mode miniature ; position retenue |
| Plafonds de débit | Réglages › Réseau : **réception internet**, **envoi internet**, **réseau local**, chacun facultatif, en **Mbit/s** (1 Mbit/s = 1 000 000 bit/s, l'unité de speedtest). Enregistrés par l'agent (`settings.json`) |
| Sens d'une tâche | Un côté « internet » est une connexion rclone d'un type autre que `smb`, `local`, `alias` ; les autres côtés (dossier, volume, `smb`…) sont « réseau local ». Source internet → réception ; destination internet → envoi (les deux si les deux) ; aucun côté internet → réseau local |
| Partage | Les exécutions d'un même sens se partagent le plafond (plafond ÷ nombre), recalculé à chaque départ, fin ou changement de réglage. Le plafond propre à une tâche (`bandwidthLimitKBps`) reste appliqué s'il est plus bas |
| À chaud — rclone | Chaque exécution rclone ouvre son contrôle à distance sur une prise Unix privée (`--rc --rc-addr unix://… --rc-no-auth`, dossier temporaire de l'utilisateur, droits 0700) ; un changement passe par `rclone rc core/bwlimit rate=ENVOI:RÉCEPTION`. Vérifié : effet en quelques secondes |
| À chaud — rsync | rsync ne change pas sa limite en route : l'exécution arrête rsync et le relance aussitôt avec la nouvelle limite (`--partial --inplace` : il reprend où il en était). Le garde-fou du miroir n'est pas refait (le plan est déjà connu) |
| Compteur d'erreurs | Les erreurs rclone sont comptées une fois par message distinct ; les lignes de résumé (« Attempt N/M failed… », « Failed to … with N errors ») ne comptent pas |
| Fichiers vides | Avant une copie, un miroir, une version ou un déplacement, les fichiers de **0 octet** à la source (filtres compris) sont confrontés à la destination ; ceux qui y existent **non vides** sont **exclus** de l'exécution. Le bilan le dit (« N fichier(s) vide(s) à la source non copié(s) : la destination a une version non vide ») et le journal les liste. Le bidirectionnel n'est pas concerné (bisync a ses propres règles) |
| Contrat XPC | Version **4 inchangée** : ajouts seulement (nouvelles requêtes, champs facultatifs). Un ancien client ignore les champs nouveaux |
| `ctl` | `queue` (liste), `queue add|remove|up|down <tâche>`, `queue start|stop`, `bandwidth` (affiche), `bandwidth --down N --up N --local N` (`off` pour retirer) |
| Hors périmètre | Réglage de copies simultanées pour tout ; priorités, planification ou plusieurs files ; plafond par plage horaire ; progression des dossiers pour bisync |

## 3. Côté agent

- `SchedulerState.userQueue: [UUID]` et `userQueueRunning: Bool` (facultatifs au décodage). `AgentCore` : `enqueue(_:)`,
  `enqueueOnce(_:)`, `dequeue(_:)`, `moveInQueue(_:to:)`, `setQueueRunning(_:)`. Après chaque fin d'exécution, `tick()` et
  `setQueueRunning(true)` : si la file tourne, que son élément en cours est terminé et qu'il reste de la place, le premier
  élément part (`startJob`, comme un lancement manuel, conditions ignorées). L'élément part de la file **au démarrage**.
- `AgentStatus.queue: QueueInfo?` (`running`, `items: [UUID]`, `current: UUID?`) ; `AgentTaskInfo.queuePosition: Int?`.
- `AgentSettings` (`settings.json`, écriture atomique) : `downloadMbps`, `uploadMbps`, `localMbps` (`Double?`).
  `AgentStatus.bandwidth: BandwidthLimits?`. Requête `setBandwidth(BandwidthLimits)`.
- `BandwidthPlanner` (pur, testé) : sens d'une tâche selon les types de connexion ; débit de chaque exécution selon les
  plafonds et les exécutions en cours. `AgentCore` le recalcule et appelle `runner.setBandwidth(_:)` à chaque départ, fin
  ou changement. Les types de connexion viennent de `listRemotes` (au démarrage, après une configuration ou suppression).
- `TaskRunning.setBandwidth(_ limit: BandwidthRate?)` : `BandwidthRate { upBytesPerSecond, downBytesPerSecond }`
  (`nil` d'un côté = sans limite). Appelé avant `run` pour la limite de départ.
- Garde des fichiers vides : `EmptySourceGuard` (rsync : parcours de la source sur le disque ; rclone :
  `lsf -R --files-only --max-size 0` puis `lsjson --files-from` de la destination), liste d'exclusions passée au moteur.
- Erreurs : `RunLog` compte les messages distincts ; `OutputSignal`/`EngineErrorText` repèrent les lignes de résumé.

## 4. Côté app

- `AgentModel` : `queue`, `enqueue`, `enqueueOnce`, `dequeue`, `moveInQueue`, `setQueueRunning`, `bandwidth`,
  `setBandwidth` (envoi différé de 0,6 s pendant la saisie).
- `ProgressPresentation` (pur, testé) : lignes « Fichiers 120 / 925 », « Dossiers 14 / 136 », « 25,3 Mo/s en moyenne »,
  « 12 min 04 s », pour la carte, la liste, la miniature et le bilan.
- Tableau de bord et écran Tâches : section « File d'attente », bouton « Mettre en file » sur les cartes et les lignes,
  « Prochaine » masquée pour une tâche manuelle, bilan après la fin.
- Écran Copie : « Mettre en file » à côté de « Copier ».
- `MiniPanelController` (AppKit) + `MiniView` (SwiftUI), commande « Mode miniature » (⌥⌘M).
- Réglages › Réseau : trois champs Mbit/s avec interrupteurs, explication du sens et du partage.

## 5. Erreurs

- Prise de contrôle rclone indisponible (ancienne version, échec d'ouverture) : la limite de départ s'applique, les
  changements à chaud sont ignorés pour cette exécution (une ligne au journal).
- Relance rsync qui échoue : l'exécution échoue avec le message de rsync (rien n'est perdu : `--partial`).
- File : un élément dont la tâche n'existe plus est sauté ; une tâche déjà en cours ne peut pas être mise en file
  (`alreadyRunning`).
- Comptage des dossiers rclone impossible : la progression se limite aux fichiers et aux octets.

## 6. Tests

- Agent (faux exécuteur) : file — ordre, un à la fois, suivant après échec, ajout en route, réordonner, retirer, suspendre,
  tâche supprimée, redémarrage (file reprise, copies ponctuelles retirées), place limitée.
- `BandwidthPlanner` : sens de chaque combinaison (dossier, `smb`, `drive`, deux services), partage, plafond de la tâche.
- Débit à chaud : faux exécuteur appelé au départ, à la fin d'une autre, au changement de réglage ; réel : rclone vers
  `:memory:` ralenti puis accéléré ; rsync relancé avec la nouvelle limite et copie complète.
- Progression : dossiers rclone (comptage + lignes « Copied »), `ProgressInfo`/`RunSummary` (décodage d'un ancien JSON).
- Fichiers vides : rsync et rclone réels — un fichier vide à la source et plein à la destination n'est pas copié, un
  fichier vide nouveau l'est.
- Compteur d'erreurs : journal capturé d'une nouvelle tentative rclone → 1 erreur.
- App : modèle (requêtes, envoi différé), présentation, rendus (cartes, file, Réglages › Réseau, miniature), textes FR/EN.
- Réel : file de trois tâches réordonnée en route, plafond changé pendant une copie rclone et une copie rsync, miniature,
  fichier vide protégé.

## 7. Risques

| Risque | Parade |
|---|---|
| Prise Unix : chemin limité à 104 caractères | Dossier temporaire de l'utilisateur + nom court (`smp-rc/<8 caractères>.sock`), testé |
| `--rc` ouvert sans authentification | Prise Unix dans un dossier 0700 de l'utilisateur : seul lui peut s'y connecter |
| Relances rsync répétées si l'on modifie le plafond en continu | Envoi différé côté app ; côté agent, au plus une relance toutes les 5 s par exécution |
| Lignes « Copied » nombreuses (millions de fichiers) | Traitées en flux (pas de stockage du texte), journal déjà plafonné |
| `NSPanel` et SwiftUI sur macOS 14 / Swift 5.10 | `NSHostingView`, code AppKit `@MainActor` ; essai dans l'app installée |
