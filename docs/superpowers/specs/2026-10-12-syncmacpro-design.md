# SyncMacPro — document de conception

Date : 2026-10-12 · Statut : à relire · Auteur : conception menée avec Sylvain

## 1. Objectif

SyncMacPro est une **application macOS native**, gratuite et open source, qui permet à n'importe qui de **créer, planifier et suivre des synchronisations et des sauvegardes** entre dossiers, NAS et services en ligne, **sans ligne de commande**, à la manière de SyncBackPro sur Windows.

Elle s'appuie sur deux moteurs éprouvés, **rsync** et **rclone**, qu'elle pilote sans les modifier. Elle regroupe en une seule app :

- la **copie manuelle à deux panneaux** (ce que fait aujourd'hui le projet Rsync-GUI) ;
- les **tâches planifiées** qui tournent en arrière-plan, app fermée ;
- un **tableau de bord** et une **icône de barre de menus** montrant l'état, le résumé de la dernière exécution et la prochaine exécution.

### Origine du besoin

Un utilisateur sauvegarde un NAS Synology vers un Drive partagé et synchronise un dossier du Drive vers le NAS, avec rclone et des scripts. Ce système fonctionne mais demande la ligne de commande et une icône SwiftBar bricolée. L'objectif est d'en faire un produit que d'autres personnes pourront utiliser seules.

## 2. Public et décisions prises

| Sujet | Décision |
|---|---|
| Public | **Grand public, open source** (dépôt GitHub public) |
| Technologie | **App 100 % native Swift / SwiftUI**, agent d'arrière-plan Swift, aucun Python |
| macOS minimum | **macOS 14**. Aspect Liquid Glass automatique sur macOS 26, matériaux classiques sur 14 et 15 |
| Moteurs | **rsync** (dossiers et volumes) et **rclone** (services en ligne), choix automatique |
| Services visés | Dossiers locaux, volumes réseau (SMB), Google Drive, Dropbox, OneDrive, Amazon S3. **v1 : dossiers/NAS + Google Drive**, les autres ensuite |
| Arrière-plan | **Oui** : un agent lance les tâches app fermée |
| Lien avec Rsync-GUI | La nouvelle app **inclut tout** (copie à deux panneaux + tâches + tableau de bord). Rsync-GUI reste un projet séparé |
| Langues | Français et anglais dès le départ |
| Dépôt | https://github.com/Sylmass95/SyncMacPro |

## 3. Sous-projets et ordre de livraison

Le produit est découpé en cinq sous-projets, chacun avec sa propre conception, son plan et ses tests :

1. **Cœur (SyncKit)** : modèle de tâche, adaptateurs rsync et rclone, lecture de la progression et du résumé, historique.
2. **Planification (agent)** : exécution en arrière-plan, rattrapage, pause, reprise, notifications.
3. **Interface** : éditeur de tâches, tableau de bord, copie à deux panneaux, historique, barre de menus.
4. **Connexion aux services** : assistant sans terminal pour Google Drive, puis Dropbox, OneDrive, S3.
5. **Distribution** : binaires embarqués, signature, notarisation, mises à jour, documentation.

**Première livraison** : sous-projets 1 à 3 avec dossiers/NAS (rsync) et Google Drive (rclone). Le présent document couvre la vision d'ensemble ; chaque sous-projet détaillera sa part dans son propre plan.

## 4. Architecture

```
┌─────────────┐  XPC   ┌──────────────┐  appelle   ┌──────────────────────┐
│  App (UI)   │◄──────►│ Agent (fond) │───────────►│ SyncKit (bibliothèque)│
│  SwiftUI    │        │ planifie,    │            │ modèle de tâche,      │
│             │        │ lance,       │            │ moteurs rsync/rclone, │
│             │        │ notifie      │            │ lecture progression,  │
└─────────────┘        └──────────────┘            │ historique            │
                                                   └──────────────────────┘
        binaires embarqués : rsync, rclone
```

- **SyncKit** (bibliothèque Swift) : modèle de tâche, deux moteurs derrière une même interface, lecture de leur sortie, stockage. Elle ne connaît ni l'interface ni la planification, ce qui la rend testable seule.
- **Agent** : programme lancé par macOS (`SMAppService`) qui reste actif sans l'app. Il calcule les tâches dues, les exécute avec SyncKit, gère pause et rattrapage, envoie les notifications. Il répond à l'app par **XPC**. C'est le **seul écrivain** de l'état et de l'historique.
- **App** : n'effectue aucune synchronisation. Elle édite les tâches, affiche l'état en direct reçu de l'agent, l'historique, la barre de menus et l'assistant de connexion. L'app peut être fermée sans rien interrompre.
- **Données** dans `~/Library/Application Support/SyncMacPro/` : tâches, historique (SQLite), journaux. Les mots de passe et jetons sont dans le **Trousseau macOS**.
- **rsync et rclone embarqués** : rsync 3.x compilé avec uniquement des bibliothèques système, rclone binaire officiel. Aucun outil à installer.

Une copie manuelle est simplement une **tâche sans planification**, exécutée par le même agent : elle bénéficie de la reprise, de la pause et de l'historique.

## 5. Tâches, moteurs et modes

### 5.1 Tâche

Une tâche comporte :

- une **source** et une **destination** : dossier local, volume réseau (SMB) ou service en ligne ;
- un **mode** (voir 5.3) ;
- des **options** : filtres et exclusions, limite de débit, vérification après copie ;
- une **planification** : manuelle, quotidienne à une heure, toutes les N heures, certains jours, ou « dès que ce volume / ce service est joignable » ;
- des **conditions** : sur secteur seulement, sur un réseau donné, plages horaires interdites ;
- des **notifications** : résumé à la fin, seulement en cas d'erreur, ou aucune.

### 5.2 Choix du moteur

- Les deux côtés sont des dossiers ou des volumes → **rsync** (reprise des gros fichiers avec `--inplace`).
- Au moins un côté est un service en ligne → **rclone**.
- Un utilisateur avancé peut forcer l'autre moteur lorsque c'est possible.

### 5.3 Modes

| Mode | Effet | Moteur |
|---|---|---|
| **Copie** | Ajoute ce qui est nouveau ou modifié, ne supprime jamais | rsync ou rclone |
| **Miroir** | La destination devient identique ; ce qui est supprimé ou écrasé est **archivé dans un dossier daté** | rsync ou rclone |
| **Bidirectionnel** | Les deux côtés restent à jour, suppressions comprises | rclone `bisync` |
| **Déplacer** | Copie puis supprime la source, **uniquement après vérification** | rsync ou rclone |
| **Sauvegarde avec versions** | Garde l'historique des anciennes versions pendant N jours | rclone |
| **Vérifier** | Compare sans rien modifier | rsync ou rclone |

### 5.4 Garde-fous communs

- Toute tâche peut être **simulée** avant d'être lancée.
- Les modes qui suppriment (miroir, bidirectionnel, déplacer) imposent une **première simulation obligatoire** et un **blocage automatique** si trop de fichiers seraient supprimés d'un coup (seuil réglable, 25 % par défaut).
- Rien n'est détruit sans archive ou confirmation.

## 6. Agent et planification

**Installation.** À la première ouverture, l'app enregistre l'agent auprès de macOS. L'utilisateur voit une seule autorisation dans les Réglages Système ; l'agent redémarre à l'ouverture de session.

**Déclenchement.** L'agent évalue les tâches toutes les minutes. Une tâche est **due** si sa planification le prévoit et qu'elle n'a pas déjà tourné. **Rattrapage** : si le Mac était éteint ou en veille à l'heure prévue, la tâche se lance au réveil dès que ses conditions sont remplies.

**Exécution.**

- Un seul exemplaire d'une tâche à la fois (verrou) ; nombre maximum de tâches en parallèle réglable (2 par défaut).
- Pas de mise en veille pendant une copie (assertion d'alimentation), relâchée à la fin ou en pause.
- **Progression en direct** : fichier en cours (taille, débit, restant) et total (fichiers, dossiers, volume, vitesse moyenne, restant). L'app s'y abonne par XPC.
- **Pause, reprise, arrêt, lancer maintenant** par tâche, et **pause globale** qui survit au redémarrage du Mac.

**Pannes.**

- *Coupure réseau ou volume démonté* : état « Reprise », nouvelle tentative avec délai croissant ; remontage du volume si son adresse est connue (identifiants dans le Trousseau).
- *Échec persistant* : état « Échec », notification, nouvelle tentative au bout d'une heure par défaut.
- *Mac éteint en pleine copie* : au redémarrage la tâche apparaît « Interrompue » puis reprend ; les gros fichiers reprennent où ils s'étaient arrêtés.
- *Quota Google Drive (750 Go par jour)* : détecté ; affiche « Quota atteint, reprise demain à telle heure » au lieu d'un échec.

**Notifications.** À la fin de chaque exécution, avec le résumé (fichiers copiés, supprimés, erreurs, volume, durée), réglables par tâche.

**Historique.** Base SQLite, une ligne par exécution avec son résumé et son journal détaillé. Conservation réglable (90 jours par défaut).

## 7. Interface

**Fenêtre principale**, avec barre latérale :

- **Tableau de bord** : une carte par tâche (état, dernier résumé, prochaine exécution, progression en direct) et un bouton **Pause globale**.
- **Copie** : deux panneaux natifs (tableau, favoris, barre de chemin, glisser-déposer, calcul de taille, menu contextuel). Actions : Copier, Synchroniser, Simuler, **Enregistrer comme tâche**.
- **Tâches** : liste, création, duplication, modification, activation.
- **Historique** : exécutions avec filtres, résumé et journal.
- **Connexions** : services configurés et assistant d'ajout.
- **Réglages** : apparence (automatique, clair, sombre), notifications, limites par défaut, démarrage à l'ouverture de session.

**Icône de barre de menus** : l'icône reflète l'état (repos, copie avec pourcentage, pause, erreur). Un clic ouvre un panneau avec les transferts actifs, les prochaines exécutions, Pause et Arrêter ; un clic droit ouvre le menu rapide.

**Éditeur de tâche**, en étapes : (1) source et destination, (2) mode présenté en cartes avec avertissement pour les modes destructifs, (3) options repliées, (4) planification avec « prochaine exécution : … », (5) résumé en langage clair et **Simuler** avant d'enregistrer.

**Premier lancement** : écran d'accueil avec des modèles (« Sauvegarder un dossier vers Google Drive », « Synchroniser deux dossiers », « Copier vers un NAS »).

**Design** : composants SwiftUI standards (barre latérale, tableaux, formulaires, barre d'outils), aspect Liquid Glass automatique sur macOS 26. Style personnalisé limité aux cartes de progression. Clair, sombre ou automatique. Français et anglais, VoiceOver et navigation au clavier.

## 8. Tests

- **SyncKit isolée** : lecture de la sortie de rsync et rclone à partir de **captures réelles** (fichiers de référence), calcul de « tâche due » avec horloge simulée, machine d'états d'une exécution.
- **Intégration avec les vrais binaires** sur dossiers temporaires : copie, miroir, archivage, reprise après un processus tué, débit limité, panne simulée.
- **Interface** : instance de test isolée avec données factices et captures de la fenêtre.
- **GitHub Actions** (macOS) : compilation et tests à chaque PR.
- **Google Drive et NAS réels** : jamais en automatique ; liste de vérifications manuelles.

## 9. Distribution, licences et structure

- **Hors App Store** (le bac à sable interdit de lancer rsync/rclone et de lire des dossiers arbitraires). DMG sur GitHub, puis cask Homebrew.
- **Signature** : « ad hoc » sans compte Apple Developer (avertissement au premier lancement : clic droit › Ouvrir) ; **notarisation** avec un compte Developer ID, recommandée pour un produit public.
- **Licence** : **MIT** pour l'app. rsync (GPL) et rclone (MIT) sont embarqués comme programmes séparés : mention des licences et lien vers leur code source dans l'app et la documentation.

```
SyncMacPro/
  Package.swift                 SwiftPM : SyncKit + agent + app
  Sources/SyncKit/              modèles, moteurs, lecture de la sortie, stockage
  Sources/SyncAgent/            planification, exécution, XPC, notifications
  Sources/App/                  interface SwiftUI
  Tests/                        tests + captures de sortie de rsync/rclone
  Resources/bin/                rsync et rclone embarqués
  scripts/                      compilation, assemblage, signature, DMG
  docs/superpowers/             conception et plans
```

La construction repose sur SwiftPM et un script d'assemblage de l'app (comme pour Rsync-GUI). Si la localisation ou la signature l'exigent, un projet Xcode généré pourra s'y ajouter.

## 10. Risques

1. **Google Drive en public (le plus sérieux).** rclone utilise un identifiant d'application partagé qui sera retiré en 2026. Une app publique doit avoir le sien, et l'accès complet à Drive est un droit « restreint » que Google ne valide qu'après une vérification de sécurité longue et parfois payante. **Plan** : en v1, un assistant guide chaque utilisateur pour créer **son propre identifiant** ; la vérification Google viendrait plus tard.
2. **`bisync` est en bêta** dans rclone : garde-fous (blocage sur suppressions massives, archivage, conflits conservés) et procédure de réinitialisation guidée.
3. **Autorisations macOS** : l'agent doit obtenir l'accès aux dossiers, volumes réseau et disques ; l'app guide l'utilisateur.
4. **Ampleur** : cinq sous-projets ; l'ordre de livraison limite le risque.
5. **GPL de rsync** : respecter les obligations de mention et de fourniture du code source.

## 11. Hors périmètre (YAGNI)

- Windows, Linux, iOS.
- Versions de fichiers au niveau du bloc ou déduplication.
- Chiffrement propre à l'app (rclone `crypt` pourra être exposé plus tard).
- Mise en vente sur l'App Store.
- Gestion d'équipe, comptes ou synchronisation entre plusieurs Mac.

## 12. Questions ouvertes

- Compte Apple Developer : à créer ou non pour la notarisation (décision de l'auteur avant le sous-projet 5).
- Nom de domaine ou page de présentation du projet (facultatif).
- Détail des modèles de tâche proposés à l'accueil (à fixer dans le sous-projet 3).
