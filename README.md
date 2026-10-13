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
| 3. Interface | à venir |
| 4. Connexion aux services | à venir |
| 5. Distribution | à venir |

## Développer

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

Sans bundle, `scripts/dev-launchd.sh install` déclare un agent de développement (service
`com.sylvain.syncmacpro.agent.dev`, données dans `SyncMacPro-dev`) ; l'utiliser avec
`syncmacpro-ctl --service com.sylvain.syncmacpro.agent.dev --state-dir "$HOME/Library/Application Support/SyncMacPro-dev"`.
`syncmacpro-agent --foreground` fait tourner l'agent dans le terminal **sans XPC** (un service Mach exige launchd).

Vérifié sur macOS 26 avec une signature ad hoc ; macOS 14 et 15 restent à confirmer. Après un arrêt brutal,
launchd met environ 10 s à relancer l'agent : l'outil patiente jusqu'à 20 s.
