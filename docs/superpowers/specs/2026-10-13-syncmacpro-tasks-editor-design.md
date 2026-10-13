# SyncMacPro — sous-projet 3b : créer (tâches, éditeur, simulation, journal)

Date : 2026-10-13 · Statut : rédigé en autonomie (à la demande de l'auteur) · Complète le §7 de `2026-10-12-syncmacpro-design.md` et le découpage de `2026-10-13-syncmacpro-ui-dashboard-design.md`

## 1. Objectif

Permettre à quelqu'un qui n'a jamais ouvert le terminal de **créer, modifier, dupliquer, activer et supprimer** ses tâches depuis l'app, avec un **éditeur en 5 étapes** qui explique les conséquences de chaque choix et **simule** avant d'enregistrer, des **modèles** pour démarrer, et le **journal détaillé** d'une exécution dans l'historique.

### Succès
- Créer une tâche « Copier mon dossier Photos vers le NAS tous les jours à 3 h » sans taper un seul chemin (sélecteur de dossier), en moins d'une minute.
- Avant d'enregistrer un miroir, l'utilisateur voit en clair combien de fichiers seraient copiés et **supprimés**.
- Une tâche enregistrée apparaît aussitôt au tableau de bord ; l'agent reste le seul à écrire `tasks.json`.
- L'historique montre ce qu'a fait le moteur (lignes de rsync / rclone) pour une exécution donnée.
- Aucune erreur que seul le CI voit n'arrive en fin de parcours : une PR brouillon est ouverte tôt et chaque tâche est poussée.

## 2. Décisions prises

| Sujet | Décision |
|---|---|
| Écriture des tâches | **Par l'agent** : nouvelles commandes XPC `saveTask` et `removeTask`. L'agent valide, écrit `tasks.json` (atomique) et recharge. Cela lève l'écart du sous-projet 2 où `ctl` écrivait le fichier |
| Contrat XPC | Version **2** : on ajoute des cas aux requêtes et réponses ; un agent et une app de versions différentes affichent « versions incompatibles » au lieu d'une erreur obscure. App, agent et `ctl` sont livrés dans le même bundle |
| `syncmacpro-ctl add/remove` | Passent par XPC ; si l'agent est injoignable, ils écrivent le fichier comme avant et le disent |
| Simulation | Exécutée **par l'agent** (il a les binaires et les accès disque), hors de la file des exécutions, sans rien écrire dans l'historique. Résultat : statut, fichiers et octets à transférer, suppressions, message. Délai client long (15 min) et bouton Annuler |
| Détail de la simulation | Les nombres, pas la liste des fichiers (YAGNI ; la liste viendra si le besoin apparaît) |
| Journal | Un fichier texte par exécution dans `logs/<id>.log` (lignes du moteur, horodatées), plafonné à **5 Mo** (au-delà : une ligne « journal tronqué ») ; supprimé avec l'exécution lors de la purge (90 jours). L'app lit les **256 derniers Ko** par XPC |
| Choix des dossiers | Sélecteur de dossier macOS (`NSOpenPanel`) ; un dossier sur un volume réseau monté devient automatiquement une destination « réseau » (URL de remontage connue) |
| Services en ligne | Saisie manuelle `remote` + chemin dans l'éditeur, en attendant l'assistant de connexion (sous-projet 4) |
| Modèles | Trois : « Copier vers un NAS », « Synchroniser deux dossiers », « Sauvegarder vers Google Drive » ; ils pré-remplissent l'éditeur, sans chemins |
| CI | Au lieu d'un second job « strict » (inefficace : les erreurs viennent du SDK macOS 14, absent en local), **PR brouillon ouverte au début et poussée après chaque tâche** |
| Hors périmètre | Assistant de connexion aux services (4), liste des remotes rclone, liste fichier par fichier de la simulation, copie à deux panneaux (3c), import / export de tâches |

## 3. Côté agent

### Commandes XPC (version 2)
- `saveTask(SyncTask)` → `.ok` ou `error(.invalidTask(raison))`. Validation : nom non vide ; source et destination renseignées ; source ≠ destination ; le moteur choisi existe pour ce mode (`EngineSelector`) ; planification cohérente (heures 0–23, minutes 0–59, au moins un jour, intervalle ≥ 1 min). Écrit `tasks.json` avec `TaskStore.upsert`, puis recharge.
- `removeTask(UUID)` → `.ok` ; `error(.alreadyRunning)` si la tâche tourne ou attend en file ; `error(.unknownTask)` sinon.
- `simulate(SyncTask)` → `simulation(SimulationResult)` ; `cancelSimulation(UUID)` → `.ok`. `SimulationResult` : `status`, `filesToTransfer`, `bytesToTransfer`, `deletions`, `message`. Une seule simulation par identifiant de tâche à la fois (une nouvelle remplace l'ancienne).
- `runLog(runID: UUID, maxBytes: Int)` → `log(RunLogText)` (`text`, `truncated: Bool`) ; `error(.unknownRun)` si l'exécution ou son fichier n'existe pas.

### Journal
- `AgentCore.startJob` ouvre `logs/<recordID>.log` et enregistre `record.logPath` ; chaque `RunUpdate.line` y est ajoutée avec l'heure ; en tête : tâche, moteur, mode ; en fin : statut et résumé.
- Écriture hors de l'acteur, par un `RunLogWriter` thread-safe, plafonné à 5 Mo.
- La purge quotidienne supprime aussi les fichiers des exécutions purgées et les fichiers orphelins de plus de 90 jours.

## 4. Côté app

### Écrans
- **Tâches** (nouvelle entrée de la barre latérale) : liste (nom, mode, planification, interrupteur Activée), boutons Nouvelle, Modèles, Modifier, Dupliquer, Supprimer (confirmation). Double-clic : modifier.
- **Éditeur** (feuille, 5 étapes, Précédent / Suivant, étapes accessibles dans l'en-tête) :
  1. **Source et destination** : pour chaque côté, « Dossier ou disque » (sélecteur) ou « Service en ligne » (remote + chemin) ; éléments choisis facultatifs (tout le dossier par défaut).
  2. **Mode** en cartes, avec ce que fait chaque mode, un **avertissement** pour miroir, bidirectionnel et déplacement, et la mention « nécessite rclone » pour bidirectionnel et versions.
  3. **Options** (repliées) : exclusions (une par ligne), limite de débit, vérification après copie, seuil de suppression, dossier d'archive, durée de conservation (versions), quota de transfert (service en ligne), conditions (secteur, réseau, plage horaire), notifications.
  4. **Planification** : manuelle, tous les jours, certains jours, toutes les N minutes, dès que disponible ; « Prochaine exécution : … » calculée en direct.
  5. **Résumé** : une phrase en clair (« Copie les nouveautés de Photos vers NAS/Photos, tous les jours à 03:00. Rien n'est supprimé. »), **Simuler** puis **Enregistrer**.
- **Modèles** : depuis l'état vide du tableau de bord (« Créer une tâche ») et le bouton Modèles de l'écran Tâches.
- **Journal** : dans le détail de l'historique, bouton « Voir le journal » → feuille en police à chasse fixe, avec Copier.

### Logique testable (sans vue)
- `TaskDraft` : brouillon modifiable d'une tâche ; création (vide, depuis un modèle, depuis une tâche, duplication) ; validation par étape avec messages ; conversion en `SyncTask`.
- `TaskSummary` : phrase de résumé et avertissements (français, anglais).
- `EndpointResolver` : chemin → `Endpoint` (`local` ou `network` selon le volume), lecture du volume injectable.
- `AgentModel` gagne `saveTask`, `removeTask`, `simulate`, `cancelSimulation`, `runLog`.

## 5. Erreurs
- Enregistrement refusé par l'agent : message de validation affiché dans l'éditeur, qui reste ouvert.
- Agent injoignable : Enregistrer et Simuler désactivés, avec la raison.
- Simulation qui échoue (source introuvable…) ou annulée : résultat affiché, l'enregistrement reste possible.
- Suppression d'une tâche en cours : refus avec le message de l'agent.
- Journal absent (exécution antérieure à 3b, fichier purgé) : « Aucun journal pour cette exécution ».

## 6. Tests
- **Agent** : `saveTask` (création, modification, validation refusée, rechargement), `removeTask` (refus pendant l'exécution), `simulate` (faux exécuteur, rien dans l'historique, annulation), journal (écriture, plafond, `logPath`, purge), version 2 du contrat, `ctl` via XPC.
- **App** : `TaskDraft` (chaque étape, conversions aller-retour, modèles, duplication), `TaskSummary` (fr / en, avertissements), `EndpointResolver`, nouvelles actions de `AgentModel`, complétude des chaînes.
- **Rendu** : liste des tâches, chaque étape de l'éditeur, résultat de simulation, feuille du journal (contenus sans `ScrollView`, comme en 3a).
- **Réel** : créer une tâche dans l'app, la simuler, l'enregistrer, la lancer, lire son journal.

## 7. Risques
| Risque | Parade |
|---|---|
| Erreurs visibles seulement sur le CI (Swift 5.10, SDK macOS 14) | PR brouillon dès le début, poussée après chaque tâche ; vues `@MainActor` ; pas de `var` ni de `weak self` capturés dans une closure concurrente ; expressions de test découpées |
| `NSOpenPanel` non testable automatiquement | Logique isolée dans `EndpointResolver` ; essai réel |
| Simulation longue sur un gros dossier | Délai client de 15 min, bouton Annuler, la simulation ne bloque pas la file |
| Journal volumineux | Plafond de 5 Mo par exécution, lecture de la fin seulement |
| Agent et app de versions différentes | Version 2 du contrat : message clair |

## 8. Hors périmètre (YAGNI)
Assistant de connexion aux services et liste des remotes rclone (4) ; copie à deux panneaux (3c) ; liste détaillée des fichiers simulés ; import / export ; édition simultanée par plusieurs fenêtres.
