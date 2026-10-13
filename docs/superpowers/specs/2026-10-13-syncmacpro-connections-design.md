# SyncMacPro — sous-projet 4 : connexion aux services en ligne

Date : 2026-10-13 · Statut : rédigé en autonomie (à la demande de l'auteur) · Complète le §3 (sous-projet 4), le §7 (écran Connexions) et le risque 1 du §10 de `2026-10-12-syncmacpro-design.md`

## 1. Objectif

Brancher Google Drive, Dropbox, OneDrive et Amazon S3 (ou un service compatible S3) **sans terminal** : un assistant crée la connexion rclone, la teste, et l'éditeur de tâches la propose avec un **sélecteur de dossier distant** au lieu d'une saisie manuelle.

### Succès
- Ajouter Google Drive en quelques minutes en suivant l'assistant (identifiant client propre ou partagé), puis créer une tâche « Photos → Drive/Sauvegardes » sans taper de chemin.
- Les connexions déjà créées avec rclone en ligne de commande apparaissent telles quelles (même fichier de configuration).
- Une connexion utilisée par une tâche ne peut pas être supprimée par erreur.
- Une connexion dont le jeton a expiré se répare avec « Reconnecter ».

## 2. Décisions prises

| Sujet | Décision |
|---|---|
| Qui écrit la configuration | **L'agent**, et toujours **par rclone** (`config create` / `update` / `delete` en mode `--non-interactive`) : jamais d'écriture directe de `rclone.conf`. L'agent a déjà le binaire et l'environnement ; l'app ne lance aucun processus |
| Fichier | Celui de rclone par défaut (comme aujourd'hui pour les exécutions) : les connexions sont partagées avec rclone en ligne de commande. Option d'agent `--rclone-config FICHIER` (développement, tests, essais réels sans toucher au vrai fichier) |
| Secrets | **Restent dans `rclone.conf`**, comme le fait rclone (fichier lisible par l'utilisateur seul). Écart assumé au §4 du spec général (Trousseau) : chiffrer la configuration imposerait un mot de passe à chaque usage de rclone en ligne de commande et un passage du mot de passe à chaque exécution. Reporté (sous-projet 5 ou plus tard), documenté dans le README |
| Dialogue avec rclone | Le **protocole non interactif** de rclone : chaque réponse est une question JSON (`State`, `Option` : nom, aide, valeur par défaut, exemples, obligatoire, secret) ou une fin. L'assistant **pré-répond** aux questions connues de chaque service et **pose les autres telles que rclone les formule** (choix parmi les exemples, ou champ libre). Ainsi OneDrive (choix du lecteur) ou un S3 exotique fonctionnent sans code dédié |
| Services de l'assistant | Google Drive, Dropbox, OneDrive, Amazon S3 et compatibles S3 (Cloudflare R2, Wasabi, MinIO… via le fournisseur S3 de rclone). Les autres types créés en ligne de commande sont listés et utilisables |
| Google Drive | Assistant en deux voies : **identifiant client propre** (recommandé : étapes guidées dans Google Cloud, bouton qui ouvre la console, rappel de « publier » l'application pour éviter l'expiration des jetons au bout de 7 jours) ou **identifiant partagé de rclone** (plus rapide, avertissement : limité et appelé à disparaître). Accès complet (`scope=drive`) |
| Autorisation (OAuth) | `config_is_local = true` : rclone ouvre le navigateur et attend la réponse ; l'assistant affiche « Terminez la connexion dans votre navigateur… » avec **Annuler** (délai maximal 10 min). Annuler arrête rclone et **supprime la connexion à moitié créée** |
| Nom | Proposé d'après le service (« Google Drive », « Dropbox »…, suffixe s'il existe déjà) ; règles de rclone : lettres, chiffres, `_ - . + @` et espaces, sans espace ni « - » au début, sans espace à la fin, unique |
| Test | `rclone lsjson nom: --dirs-only --max-depth 1` avec un délai de 30 s : à la fin de l'assistant et à la demande (« Tester ») ; message clair en cas d'échec |
| Reconnecter | `config update nom config_refresh_token=true --non-interactive` puis le même dialogue (navigateur) |
| Suppression | Refusée si une tâche utilise la connexion (message avec le nom des tâches) ; confirmation sinon |
| Écran Connexions | Nouvelle entrée de la barre latérale : liste (nom, service, tâches qui l'utilisent), Ajouter, Tester, Reconnecter, Supprimer |
| Éditeur de tâches | Côté « Service en ligne » : menu des connexions (avec « Ajouter une connexion… ») au lieu du champ libre, et **Choisir…** qui ouvre un navigateur de dossiers distants (un niveau à la fois, création impossible : on choisit un dossier existant ou on tape un nouveau nom au bout du chemin) |
| Contrat XPC | Version **4** |
| Hors périmètre | Navigation dans les services en ligne depuis l'écran Copie, chiffrement `crypt`, modification d'une connexion (on la supprime et la recrée), import/export de configuration, Trousseau |

## 3. Côté agent

- `listRemotes` → liste `RemoteInfo` (`name`, `type`) depuis `rclone listremotes --long --json`.
- `configureRemote(RemoteConfigStep)` → `configQuestion(RemoteQuestion)` ou `configDone` :
  - `start(name, type, parameters)` : `rclone config create NOM TYPE clé=valeur… --non-interactive` ;
  - `answer(name, state, result)` : `rclone config update NOM --continue --state … --result … --non-interactive` ;
  - `reconnect(name)` : `rclone config update NOM config_refresh_token=true --non-interactive`.
  Une seule configuration à la fois par nom ; délai 10 min (le navigateur), puis arrêt.
- `cancelConfiguration(name)` → arrête le processus en cours ; si la configuration était une création, supprime la connexion.
- `deleteRemote(name)` → `rclone config delete` ; refus `remoteInUse([noms de tâches])`.
- `testRemote(name)` → `remoteTest(RemoteTestResult)` (`ok`, `message`).
- `listRemoteFolders(remote, path)` → `folders([String])` (`rclone lsjson nom:chemin --dirs-only`, délai 30 s).
- rclone introuvable : `binaryMissing` avec le message clair existant.

## 4. Côté app

### Écran Connexions
Liste des connexions avec l'icône du service, le nom, le type, les tâches qui l'utilisent ; boutons Ajouter, Tester (résultat dans la ligne), Reconnecter (services à jeton), Supprimer (confirmation, refus expliqué). État vide : « Aucune connexion » et bouton Ajouter.

### Assistant (feuille)
1. **Service** : cartes Google Drive, Dropbox, OneDrive, Amazon S3 / compatible.
2. **Préparation** : Google Drive — choix identifiant propre (guide pas à pas + champs ID et secret) ou partagé (avertissement) ; S3 — fournisseur, clé d'accès, clé secrète, région ou adresse du service ; autres — rien.
3. **Nom**.
4. **Connexion** : dialogue avec rclone ; questions restantes affichées (choix ou champ) ; attente du navigateur avec Annuler.
5. **Test** puis **Terminé** (« Utilisable dans vos tâches »).

### Logique testable
- `ServiceCatalog` : service → type rclone, paramètres pré-remplis, réponses automatiques, besoin d'OAuth, icône.
- `RemoteNameRule` : validation et proposition de nom.
- `WizardModel` : étapes, validation de chaque étape, réponses automatiques, passage d'une question rclone à la suivante.
- `RemoteUsage` : quelles tâches utilisent quelle connexion.
- `AgentModel` : `listRemotes`, `configure`, `cancelConfiguration`, `deleteRemote`, `testRemote`, `listRemoteFolders`.
- Côté SyncKit : `RcloneConfigCommand` (arguments), `RcloneConfigReply` (lecture du JSON de rclone, captures réelles).

## 5. Erreurs
- Navigateur fermé, refus d'accès, délai dépassé : message, connexion supprimée, on peut recommencer.
- Identifiants S3 faux : la création réussit (rclone ne vérifie pas) mais le test échoue avec le message de rclone ; l'assistant propose de corriger (retour à l'étape 2, la connexion est recréée).
- Agent injoignable : écran et assistant désactivés avec la raison.
- Connexion supprimée en ligne de commande alors qu'une tâche l'utilise : la tâche échoue avec le message de rclone (comme aujourd'hui).

## 6. Tests
- SyncKit : arguments des commandes de configuration, lecture des réponses JSON (captures réelles : question booléenne, question à choix, fin, erreur), règles de nom.
- Agent avec le **vrai rclone** sur un fichier de configuration temporaire : créer une connexion S3 (aucun réseau nécessaire), la lister, refuser sa suppression si une tâche l'utilise, la supprimer, dialogue OneDrive jusqu'à la question d'autorisation puis annulation (la connexion disparaît), test d'une connexion `local` (`alias` vers un dossier temporaire) et d'une connexion injoignable.
- App : catalogue, nom, assistant (chaque étape, réponses automatiques, question générique), usage, actions de `AgentModel` ; rendu de l'écran Connexions, de chaque étape de l'assistant et du sélecteur de dossier distant.
- Réel (manuel) : Google Drive avec identifiant propre et partagé, Dropbox, OneDrive, S3 ; reconnexion ; tâche vers Drive avec dossier choisi.

## 7. Risques
| Risque | Parade |
|---|---|
| OAuth impossible à tester automatiquement | Dialogue testé jusqu'à la question d'autorisation avec le vrai rclone ; vérifications manuelles listées |
| Protocole non interactif de rclone qui évolue | Lecture tolérante (champs facultatifs), captures réelles en tests, question générique pour l'inconnu |
| Jetons Google expirés au bout de 7 jours (application « en test ») | L'assistant explique comment publier l'application ; bouton Reconnecter |
| Secrets en clair dans `rclone.conf` | Comportement standard de rclone, fichier privé ; documenté ; chiffrement plus tard |
| CI Swift 5.10 / SDK macOS 14 | PR brouillon dès le début, poussée après chaque tâche ; vues `@MainActor` |
