# SyncMacPro

Application macOS native, gratuite et open source, pour créer, planifier et suivre des synchronisations
et des sauvegardes entre dossiers, NAS et services en ligne, **sans ligne de commande**.
Elle s'appuie sur deux moteurs éprouvés : **rsync** (dossiers et volumes) et **rclone** (services en ligne).

Conception : [`docs/superpowers/specs/2026-10-12-syncmacpro-design.md`](docs/superpowers/specs/2026-10-12-syncmacpro-design.md)

## État

| Sous-projet | État |
|---|---|
| 1. Cœur (`SyncKit`) | terminé : modèle de tâche, moteurs rsync/rclone, progression, historique |
| 2. Planification (agent) | en cours : agent d'arrière-plan, XPC et outil `syncmacpro-ctl` (voir ci-dessous) |
| 3. Interface | 3a et 3b livrées : tableau de bord, barre de menus, historique, réglages, tâches, éditeur, simulation, journal ; 3c (copie à deux panneaux) à venir |
| 4. Connexion aux services | à venir |
| 5. Distribution | à venir |

## Développer

Prérequis : macOS 14 ou plus, Xcode (ou ses outils en ligne de commande), **rsync 3.x** (`brew install rsync`, celui de
macOS est `openrsync`, insuffisant) et `rclone`.

```bash
swift build
SYNCMACPRO_RSYNC=/opt/homebrew/bin/rsync swift test   # les tests d'intégration sont ignorés sans rsync 3
```

## Agent d'arrière-plan

Un agent lance les tâches planifiées **app fermée** : horaires (quotidien, jours de la semaine, toutes les N minutes,
dès que le volume est disponible), conditions (secteur, réseau, plage horaire), 2 copies en parallèle au plus,
nouvelles tentatives (1 h, 3 essais), notifications et historique (90 jours).

- **Rattrapage** : après une veille, un arrêt ou un redémarrage, une tâche en retard s'exécute **une seule fois**,
  une minute après le réveil.
- **Pause globale** : conservée après un redémarrage du Mac ; à la reprise, le rattrapage s'applique.
- **Arrêt de l'agent** : les copies en cours sont arrêtées proprement, marquées « interrompues » dans l'historique
  et rattrapées au démarrage suivant. Un état illisible fait repartir l'agent **en pause**.
- **Suppressions** : en mode miroir, un dépassement du seuil bloque la tâche ; `syncmacpro-ctl approve <tâche>`
  la relance une fois en acceptant les suppressions.

### L'outil `syncmacpro-ctl`

```text
status | list | watch
run | pause | resume | stop | approve <tâche>
pause-all | resume-all
history [<tâche>] [--limit N]
add --name N --source P --dest P [--mode M] [--every MIN | --daily HH:MM] [--ac-power]
remove <tâche>
simulate <tâche> | log <tâche>
agent install | uninstall | status
Options : --json  --state-dir DOSSIER  --service NOM
```

Une tâche se désigne par son nom (ou un début de nom) ou son identifiant. Des alias français existent
(`statut`, `liste`, `lancer`, `reprendre`, `arreter`, `historique`, `valider`, `pause-tout`, `reprendre-tout`).
Les données sont dans `~/Library/Application Support/SyncMacPro/` (`tasks.json`, `scheduler-state.json`,
`history.sqlite`) ; l'agent est le seul à écrire l'état et l'historique.

### Installer l'agent (développement)

```bash
scripts/make-dev-bundle.sh
~/Applications/SyncMacPro.app/Contents/MacOS/syncmacpro-ctl agent install
```

`SMAppService` n'enregistre l'agent que depuis le bundle : l'outil doit être lancé par son chemin complet dans
`SyncMacPro.app/Contents/MacOS/`. Si macOS demande une autorisation, elle se donne dans Réglages Système ›
Général › Éléments de connexion et extensions.

Sans bundle, `scripts/dev-launchd.sh install` déclare un agent de développement (il reçoit `SYNCMACPRO_RSYNC` s'il est défini) (service
`com.sylvain.syncmacpro.agent.dev`, données dans `SyncMacPro-dev`) ; l'utiliser avec
`syncmacpro-ctl --service com.sylvain.syncmacpro.agent.dev --state-dir "$HOME/Library/Application Support/SyncMacPro-dev"`.
`syncmacpro-agent --foreground` fait tourner l'agent dans le terminal **sans XPC** (un service Mach exige launchd).

Vérifié sur macOS 26 avec une signature ad hoc ; macOS 14 et 15 restent à confirmer. Après un arrêt brutal,
launchd met environ 10 s à relancer l'agent : l'outil patiente jusqu'à 20 s.

## Interface (sous-projet 3a)

L'app `SyncMacPro` affiche l'état de l'agent en direct : **tableau de bord** (une carte par tâche, progression, pause globale),
**icône de barre de menus** (repos, pourcentage, pause, erreur), **historique** (filtres, détail) et **réglages**
(apparence, ouverture à la connexion, agent). Elle n'effectue aucune synchronisation : fermer la fenêtre garde l'app dans la
barre de menus, la quitter laisse l'agent tourner. Si l'agent redémarre, l'app se reconnecte seule.

```bash
scripts/make-dev-bundle.sh          # assemble ~/Applications/SyncMacPro.app (signature ad hoc)
open ~/Applications/SyncMacPro.app
```

L'installation de l'agent se fait au premier lancement (ou dans Réglages › Agent). Les tâches se créent dans l'app (écran
Tâches ou « Créer une tâche »), avec un éditeur en 5 étapes qui simule avant d'enregistrer ; l'historique montre le journal
de chaque exécution. L'agent est le seul à écrire `tasks.json` ; `syncmacpro-ctl add / remove / simulate / log` passent par lui. Textes en français et en anglais (`Sources/SyncMacProUI/Resources/*.lproj`, fichiers
`.strings` : `swift build` ne compile pas les catalogues `.xcstrings`). L'agent a besoin de **rsync 3** (`brew install rsync`) :
sans lui macOS utilise `openrsync` et le résumé des exécutions est faux (le bundle de rsync viendra au sous-projet 5).
Vérifications à la main : [`docs/manual-checks-ui.md`](docs/manual-checks-ui.md). Les tests de rendu (`ImageRenderer`) écrivent
des PNG dans `$TMPDIR/syncmacpro-renders/` ; `ImageRenderer` ne dessine ni les `ScrollView` ni les contrôles AppKit
(barres de progression, filtres), qui se vérifient dans l'app.
