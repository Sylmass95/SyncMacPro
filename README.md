# SyncMacPro

Application macOS native, gratuite et open source, pour créer, planifier et suivre des synchronisations
et des sauvegardes entre dossiers, NAS et services en ligne, **sans ligne de commande**.
Elle s'appuie sur deux moteurs éprouvés : **rsync** (dossiers et volumes) et **rclone** (services en ligne).

Conception : [`docs/superpowers/specs/2026-10-12-syncmacpro-design.md`](docs/superpowers/specs/2026-10-12-syncmacpro-design.md)

## État

Les cinq sous-projets sont livrés : cœur (`SyncKit`), agent d'arrière-plan, interface (tableau de bord, tâches, copie
à deux panneaux, historique, réglages), connexions aux services en ligne et distribution.

L'interface utilise un thème verre (fond coloré, panneaux en verre dépoli) en clair ou en sombre, avec deux styles au
choix dans Réglages › Apparence : « Verre intense » (par défaut) et « Verre léger ».

## Installer

1. Téléchargez `SyncMacPro-<version>.dmg` depuis les [publications](https://github.com/Sylmass95/SyncMacPro/releases).
2. Ouvrez-le et glissez **SyncMacPro** dans **Applications**, puis ouvrez-la depuis Applications.
3. L'app est signée « ad hoc » (sans compte Apple Developer) : au premier lancement macOS l'arrête.
   - macOS 15 et suivants : Réglages Système › Confidentialité et sécurité › **Ouvrir quand même** ;
   - macOS 14 : clic droit sur l'app › **Ouvrir** ;
   - ou : `xattr -dr com.apple.quarantine /Applications/SyncMacPro.app`.
4. L'accueil installe l'agent d'arrière-plan (macOS peut demander de l'autoriser dans Réglages Système › Général ›
   Ouverture).

macOS 14 ou plus récent, Apple Silicon et Intel. rsync 3.5.1 et rclone 1.75.1 sont inclus : rien d'autre à installer.
L'app vérifie chaque jour s'il existe une nouvelle version (Réglages › À propos) ; elle ne s'installe pas seule.
Diagnostic : `/Applications/SyncMacPro.app/Contents/MacOS/syncmacpro-ctl doctor`.

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
history [<tâche>] --clear
queue | queue add | remove | up | down <tâche> | queue start | stop
bandwidth [--down N] [--up N] [--local N]   (Mbit/s, « off » pour retirer)
eject <tâche> | abandon <tâche>   (disque amovible : éjecter, abandonner la sauvegarde en pause)
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
`.strings` : `swift build` ne compile pas les catalogues `.xcstrings`). L'app publiée embarque rsync 3 et rclone ; en développement (`swift run`, agent de
développement), l'agent prend ceux de Homebrew (`brew install rsync rclone`) — l'`openrsync` de macOS est refusé avec un message clair.
Vérifications à la main : [`docs/manual-checks-ui.md`](docs/manual-checks-ui.md). Les tests de rendu (`ImageRenderer`) écrivent
des PNG dans `$TMPDIR/syncmacpro-renders/` ; `ImageRenderer` ne dessine ni les `ScrollView` ni les contrôles AppKit
(barres de progression, filtres), qui se vérifient dans l'app.

## Copie à deux panneaux (sous-projet 3c)

L'écran **Copie** montre deux dossiers côte à côte : à gauche la source, à droite la destination (⇄ pour échanger).
- **Copier** : les éléments choisis à gauche (⌘ et ⇧ pour en choisir plusieurs) vers le dossier de droite.
- **Synchroniser** : rend le dossier de droite identique à celui de gauche (miroir, avec archive et garde-fou).
- **Simuler** : montre ce qui serait copié et supprimé, sans rien modifier.
- **Enregistrer comme tâche** : ouvre l'éditeur pré-rempli.
- Glisser un élément d'un panneau à l'autre, ou déposer des fichiers du Finder, ouvre la même confirmation.
- Emplacements standard, disques montés et favoris (étoile) dans le menu de chaque panneau ; fichiers cachés au choix.

Chaque copie est exécutée par l'agent comme une **copie manuelle** : elle apparaît au tableau de bord le temps de
l'exécution, puis dans l'historique (avec son journal) ; elle n'est pas enregistrée dans les tâches. Une copie
interrompue par l'arrêt de l'agent n'est pas reprise. Si le garde-fou bloque une synchronisation, la confirmation propose,
après une simulation, d'accepter les suppressions annoncées.

```bash
syncmacpro-ctl copy --source DOSSIER --dest DOSSIER [--item NOM]... [--mirror]
SYNCMACPRO_AGENT_SERVICE=com.sylvain.syncmacpro.agent.dev .build/debug/SyncMacPro   # l'app sur l'agent de développement
```

## Connexions aux services (sous-projet 4)

L'écran **Connexions** liste les services en ligne configurés (y compris ceux créés avec rclone en ligne de commande),
les tâches qui les utilisent, et permet de les **tester**, de les **reconnecter** (jeton expiré) et de les **supprimer**
(refusé tant qu'une tâche s'en sert). L'**assistant** crée une connexion sans terminal :
- **Google Drive** : avec votre propre identifiant Google (guide pas à pas, recommandé : celui de rclone est limité et
  retiré en 2026) ou avec l'identifiant partagé de rclone ;
- **Dropbox**, **OneDrive** : connexion dans le navigateur ; les questions propres au service (choix du lecteur…) sont
  posées telles que rclone les formule ;
- **Amazon S3** et services compatibles (Cloudflare R2, Wasabi, MinIO…) : clés d'accès.

Dans l'éditeur de tâches, le côté « Service en ligne » propose ces connexions et un sélecteur de dossier distant.

L'agent pilote rclone par son mode non interactif et n'écrit jamais lui-même la configuration. Le fichier est celui de
rclone (`~/.config/rclone/rclone.conf`, partagé avec la ligne de commande) ; les secrets y restent comme rclone les
écrit (fichier privé de l'utilisateur), le chiffrement viendra plus tard. À la création d'une connexion, les clés
(S3, secret Google) passent en argument à rclone : elles sont visibles quelques instants dans la liste des processus,
pour votre seul compte macOS (qui peut déjà lire `rclone.conf`).

```bash
syncmacpro-ctl remotes                 # connexions
syncmacpro-ctl remote test "Google Drive"
syncmacpro-ctl remote delete "Google Drive"
```

Développement : l'agent accepte `--rclone-config FICHIER` ; `SYNCMACPRO_DEV_RCLONE_CONFIG=FICHIER scripts/dev-launchd.sh install`
le transmet à l'agent de développement (essais sans toucher à la vraie configuration).

## Sauvegarde sur disque amovible (1.4.0)

Pour une sauvegarde physique de temps en temps, sans laisser le disque branché : choisissez un dossier d'un disque
externe comme destination, puis, à l'étape Planification, cochez **« Lancer la sauvegarde quand ce disque est
branché »**.
- Le disque est reconnu par l'identifiant de son volume : monté sous un autre nom (« Extreme Pro 1 »), il est
  retrouvé ; un autre disque du même nom ne l'est pas.
- Déclenchement : **à chaque branchement**, ou **au plus une fois tous les N jours** (rien si la dernière réussite est
  plus récente). Les conditions habituelles (secteur, plage horaire) s'appliquent ; la tâche reste lançable à la main.
- Débranché en pleine copie : la tâche passe « En pause : disque débranché » (ni échec, ni nouvel essai). Rebranché
  dans le délai de reprise (3 jours par défaut, 1 à 30), la même exécution continue et finit avec un seul bilan ;
  au-delà, elle est close et une nouvelle repart sur une comparaison complète (rien d'identique n'est recopié).
  « Abandonner » clôt la sauvegarde en pause.
- En fin de sauvegarde : notification « vous pouvez éjecter », bouton **Éjecter** (carte, miniature, barre de menus)
  ou **éjection automatique** (seulement si rien d'autre n'écrit sur le disque ; un refus de macOS est signalé).

```bash
syncmacpro-ctl eject "Sauvegarde"      # éjecter le disque de la tâche
syncmacpro-ctl abandon "Sauvegarde"    # abandonner la sauvegarde en pause
```

## Construire et publier

```bash
scripts/fetch-vendor.sh      # rsync (compilé) et rclone (officiel), universels, empreintes de scripts/vendor.lock
scripts/make-release.sh      # build/SyncMacPro-<VERSION>.dmg (app universelle, signature ad hoc)
scripts/make-dev-bundle.sh   # bundle de développement dans ~/Applications (binaires embarqués s'ils sont prêts)
```

Publier une version : mettre à jour `VERSION` et `docs/release-notes.md`, fusionner, puis pousser l'étiquette
`vX.Y.Z` (`git tag v1.0.0 && git push origin v1.0.0`). Le workflow **Publication** construit le DMG et crée la
publication GitHub avec le DMG, l'archive source de rsync et le flux de mise à jour `appcast.xml` (signé). Lancé à la main (onglet Actions), il construit seulement
et garde le DMG comme artefact. Changer de version de rsync ou rclone : modifier `scripts/vendor.lock` (versions,
adresses, empreintes SHA-256 officielles).

### Mises à jour automatiques (Sparkle)

L'app (1.6.0 et suivantes) lit `appcast.xml` de la dernière publication, télécharge la nouvelle version, vérifie sa
signature EdDSA en mode strict (`SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed` : une archive ou un flux
modifié est refusé), puis l'installe quand aucune copie ne tourne. Pas de compte Apple Developer nécessaire.

**Clé de mise à jour** (une fois, par l'auteur, sur son Mac) :

```bash
scripts/fetch-sparkle-tools.sh
.build/sparkle-tools/bin/generate_keys                     # crée la clé dans le trousseau (et l'affiche)
.build/sparkle-tools/bin/generate_keys -p > scripts/sparkle-public-key.txt   # clé publique, versionnée
```

Puis la clé privée dans les secrets GitHub (fichier temporaire supprimé aussitôt) :

```bash
K="$(mktemp)"; .build/sparkle-tools/bin/generate_keys -x "$K" && gh secret set SPARKLE_ED_PRIVATE_KEY --repo Sylmass95/SyncMacPro < "$K"; rm -P "$K"
```

**Sauvegardez la clé privée** (export `-x` rangé dans un gestionnaire de mots de passe) : perdue, les apps
installées ne pourraient plus être mises à jour automatiquement (nouvelle clé = une installation manuelle pour tous).
Sans `scripts/sparkle-public-key.txt`, l'app ne s'assemble pas ; sans le secret, la publication s'arrête.

Essai de bout en bout avant de publier (app d'essai à part, clé jetable, rien d'installé n'est touché) :
`scripts/try-update.sh` — mise à jour 1 → 2 par un DMG et un flux produits par `make-appcast.sh`, puis version
falsifiée refusée.

## Confidentialité

SyncMacPro ne collecte aucune donnée : voir [`PRIVACY.md`](PRIVACY.md).

## Licences

SyncMacPro est sous licence MIT. Il embarque rsync (GPL v3) et rclone (MIT), non modifiés, lancés comme programmes
séparés : voir [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) (dans l'app : Réglages › À propos › Licences).
