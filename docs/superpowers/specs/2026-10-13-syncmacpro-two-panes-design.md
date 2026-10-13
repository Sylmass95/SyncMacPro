# SyncMacPro — sous-projet 3c : copie à deux panneaux

Date : 2026-10-13 · Statut : rédigé en autonomie (à la demande de l'auteur) · Complète le §7 de `2026-10-12-syncmacpro-design.md`

## 1. Objectif

Retrouver dans SyncMacPro l'usage de Rsync GUI : **deux panneaux de fichiers côte à côte** (à gauche la source, à droite la destination), pour **copier** une sélection, **synchroniser** un dossier, **simuler** avant, ou **enregistrer comme tâche**. Comme le dit le spec général, une copie manuelle est exécutée **par l'agent** : elle a la pause, l'arrêt, la progression au tableau de bord et l'historique avec son journal.

### Succès
- Copier trois fichiers d'un dossier vers un NAS en quelques clics, ou par glisser-déposer, sans écrire de chemin.
- Avant une synchronisation (miroir), l'utilisateur voit ce qui serait supprimé.
- La copie apparaît au tableau de bord avec sa progression, puis dans l'historique, sans encombrer l'écran Tâches.
- La taille de la sélection et la place libre de la destination sont affichées.

## 2. Décisions prises

| Sujet | Décision |
|---|---|
| Sens | **Gauche = source, droite = destination**, bouton ⇄ pour échanger ; toutes les actions vont de gauche à droite. Un dépôt (glisser) copie vers le panneau où l'on dépose |
| Exécution ponctuelle | Nouvelle commande XPC **`runOnce(SyncTask)`** : l'agent exécute une tâche **sans l'écrire dans `tasks.json`** ; elle figure dans l'état (marquée « copie manuelle ») tant qu'elle est en file ou en cours, puis seulement dans l'historique |
| Reprise | Une copie ponctuelle interrompue par l'arrêt de l'agent **n'est pas rattrapée** (elle n'existe plus après redémarrage) ; elle est marquée « interrompue » dans l'historique |
| Contrat XPC | Version **3** (nouvelle requête) ; `AgentTaskInfo.isOneOff` (optionnel, faux par défaut) |
| Copier | Les éléments choisis d'un même dossier → une tâche ponctuelle (mode copie, `sourceItems`) ; des éléments venant de dossiers différents (dépôt depuis le Finder) → une tâche par dossier parent |
| Synchroniser | Le dossier de gauche entier vers celui de droite, en **miroir** (archivage, garde-fou de suppression) |
| Confirmation | Toute copie ou synchronisation passe par une feuille de confirmation : phrase de résumé, avertissements, **Simuler**, puis **Lancer** |
| Enregistrer comme tâche | Ouvre l'éditeur de 3b pré-rempli (source, destination, éléments choisis, mode) |
| Taille | Calculée en arrière-plan pour la sélection (annulée si la sélection change), avec nombre de fichiers ; liens symboliques non suivis |
| Favoris | Dossiers favoris par panneau commun, conservés dans les réglages de l'app ; emplacements standard (Départ, Bureau, Documents, Téléchargements) et volumes montés |
| Services en ligne | Non navigables en 3c (sous-projet 4) |
| Hors périmètre | Opérations de fichiers du Finder (renommer, supprimer, créer un dossier), aperçu, navigation dans les services en ligne, onglets |

## 3. Côté agent

- `runOnce(SyncTask)` → `.ok` ; refus `invalidTask(raison)` (même validation que `saveTask`, nom compris) ou `alreadyRunning` si l'identifiant est déjà connu (tâche enregistrée ou ponctuelle en cours).
- L'agent garde les tâches ponctuelles dans `oneOffs` le temps de leur exécution : elles passent par la même file (2 en parallèle), les mêmes garde-fous, le même journal, et sortent de l'état à la fin.
- `pause`, `resume`, `stop` s'appliquent aussi à une tâche ponctuelle.

## 4. Côté app

### Écran Copie (nouvelle entrée de la barre latérale)
- Deux **panneaux** : en-tête avec menu des emplacements (favoris, dossiers standard, volumes) et bouton Ajouter aux favoris, **barre de chemin** cliquable, liste (nom, taille, date de modification ; dossiers d'abord), double-clic pour entrer dans un dossier, bouton Dossier parent, affichage des fichiers cachés au choix. Sélection multiple (⌘ et ⇧).
- **Colonne d'actions** au centre : Copier →, Synchroniser →, Simuler, Enregistrer comme tâche, ⇄.
- **Barre d'état** : nombre d'éléments choisis, leur taille (calcul en cours…), place libre sur le volume de destination.
- **Glisser-déposer** : d'un panneau vers l'autre, ou depuis le Finder ; le dépôt ouvre la confirmation.
- **Menu contextuel** d'un élément : Copier vers l'autre panneau, Simuler, Ouvrir (dossier), Ajouter aux favoris (dossier), Afficher dans le Finder.
- Un dossier illisible (droits) affiche un message dans le panneau au lieu de la liste.

### Logique testable
- `DirectoryLister` : contenu d'un dossier trié, fichiers cachés filtrés, paquets (.app) traités comme des fichiers, erreurs lisibles.
- `PathCrumbs` : chemin → éléments de la barre (le premier porte le nom du volume).
- `FavoritesStore` : ajouter, retirer, lister (sans doublon, ordre conservé), sur un `UserDefaults` injectable.
- `FolderSizer` : taille et nombre de fichiers d'une sélection, annulable, sans suivre les liens.
- `PaneModel` : dossier courant, contenu, sélection, retour au parent, fichiers cachés, erreur.
- `OneOffPlanner` : sélection → tâches ponctuelles (regroupées par dossier parent), synchronisation → tâche miroir, nom lisible.
- `AgentModel.runOnce(_:)`.

## 5. Erreurs
- Refus de l'agent (dossiers imbriqués, destination dans la sélection…) : affiché dans la feuille de confirmation.
- Agent injoignable : actions désactivées avec la raison.
- Volume démonté pendant la navigation : le panneau remonte au premier dossier existant et le signale.
- Simulation qui échoue : résultat affiché ; Lancer reste possible.

## 6. Tests
- Agent : `runOnce` (exécution, état « ponctuelle », sortie de l'état à la fin, historique, refus d'un identifiant connu, validation, arrêt), contrat v3.
- App : chacune des unités du §4, avec des dossiers temporaires réels ; rendu de la liste d'un panneau, de la barre d'état et de la feuille de confirmation.
- Réel : copier une sélection et synchroniser un dossier avec l'agent de développement, vérifier l'historique et le journal.

## 7. Risques
| Risque | Parade |
|---|---|
| CI Swift 5.10 / SDK macOS 14 | PR brouillon dès le début, poussée après chaque tâche ; vues `@MainActor` |
| Gros dossiers (milliers d'éléments) | Liste paresseuse ; calcul de taille annulable et hors du fil principal |
| Glisser-déposer non testable automatiquement | Logique du dépôt dans `OneOffPlanner` ; vérification manuelle |
| Copie ponctuelle perdue à l'arrêt de l'agent | Documenté ; marquée « interrompue » dans l'historique |

## 8. Hors périmètre (YAGNI)
Gestion de fichiers (renommer, supprimer, créer), aperçu, navigation dans les services en ligne, onglets, comparaison visuelle des deux panneaux.
