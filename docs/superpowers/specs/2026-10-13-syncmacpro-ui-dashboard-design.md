# SyncMacPro — sous-projet 3a : voir et contrôler (interface)

Date : 2026-10-13 · Statut : à relire · Complète le §7 de `2026-10-12-syncmacpro-design.md`

## 1. Objectif

Une **app SwiftUI native** qui n'effectue aucune synchronisation : elle se connecte à l'agent (sous-projet 2) par XPC, **affiche l'état en direct** des tâches, permet de **les contrôler** (lancer, pause, reprise, arrêt, pause globale, validation d'une suppression), montre l'**historique**, vit dans la **barre de menus** et propose des **réglages**. Fermer l'app n'interrompt rien.

### Découpage du sous-projet 3

| Livraison | Contenu | État |
|---|---|---|
| **3a** (ce document) | Coque de l'app, connexion à l'agent, installation de l'agent, tableau de bord, barre de menus, historique, réglages | à concevoir ici |
| 3b | Liste des tâches, éditeur en 5 étapes avec simulation, modèles d'accueil, commandes XPC `add` / `update` / `remove`, journal détaillé | plus tard |
| 3c | Copie à deux panneaux, favoris, glisser-déposer, « Enregistrer comme tâche » | plus tard |

### Succès
- Ouvrir l'app pendant une copie affiche tout de suite la carte de la tâche avec sa progression.
- Tuer l'agent : l'app indique « reconnexion… » puis se rétablit seule, sans action de l'utilisateur.
- Au premier lancement, un utilisateur qui n'a jamais vu le terminal installe l'agent en un clic.
- Fermer la fenêtre laisse l'app dans la barre de menus ; Quitter laisse l'agent tourner.
- Toute la logique (connexion, reconnexion, tri, filtres, textes) est testée sans interface ni agent réel.

## 2. Décisions prises

| Sujet | Décision |
|---|---|
| Technologie | SwiftUI natif, macOS 14 (Observation `@Observable`, `MenuBarExtra`), français et anglais |
| Structure | Un seul paquet SwiftPM : bibliothèque `SyncMacProUI` (vues et modèles, testables), exécutable fin `SyncMacPro`, tests `SyncMacProUITests` |
| Packaging | `scripts/make-dev-bundle.sh` assemble l'app complète : l'app est le programme principal ; l'agent et `syncmacpro-ctl` sont dans le même bundle |
| Présence | Dock **et** barre de menus ; fermer la fenêtre garde l'app, Quitter la ferme, l'agent continue |
| Historique | Résumé seulement en 3a (pas de journal détaillé) |
| Clic droit de la barre de menus | Non pris en charge (limite de `MenuBarExtra`) : tout passe par le panneau |
| Hors périmètre | Création et édition de tâches (3b), copie à deux panneaux (3c), connexions aux services (4), journal détaillé, icône définitive, signature et notarisation (5) |

## 3. Architecture

| Unité | Rôle | Dépend de |
|---|---|---|
| `AgentConnecting` (protocole) | État, tâches, historique, commandes, suivi en direct ; `AgentClient` y répond, un faux sert aux tests | `AgentClient` |
| `AgentModel` (`@MainActor @Observable`) | État de connexion, état des tâches, avancement en direct, historique ; boucle de connexion et de reconnexion ; actions | `AgentConnecting`, un « dormeur » et une horloge injectés |
| `AgentInstaller` (protocole + implémentation `SMAppService`) | États : non installé, à autoriser, actif, introuvable ; installer, désinstaller, ouvrir Réglages Système | `ServiceManagement` |
| `MenuBarState` | Fonction pure : état de la barre de menus (repos, copie + pourcentage, pause, erreur) | `AgentStatus`, `ProgressInfo` |
| `CardOrdering`, `HistoryFilter`, `CardText` | Fonctions pures : tri des cartes, filtres de l'historique, textes (« réussie il y a 2 h », « demain 03:00 ») | `AgentTaskInfo`, `RunRecord`, horloge injectée |
| Vues | `DashboardView`, `TaskCard`, `MenuBarPanel`, `HistoryView`, `SettingsView`, `OnboardingView`, bandeaux d'alerte | modèles ci-dessus |
| `SyncMacPro` (exécutable) | Point d'entrée `@main`, fenêtre, `MenuBarExtra`, délégué d'application | `SyncMacProUI` |

## 4. Flux de données

- **Démarrage.** `AgentModel` lit `status`, puis s'abonne aux événements (`watch`). Si launchd relance l'agent, la lecture patiente jusqu'à 20 s et l'écran affiche « connexion… ». L'état initial contient déjà l'avancement des copies en cours.
- **Événements.** `progress` met à jour la carte sans relire l'état. `taskStarted`, `taskFinished` et `stateChanged` déclenchent **une relecture groupée** (rafales regroupées sur 250 ms) ; une fin d'exécution recharge aussi l'historique. Une relecture de sécurité toutes les 30 s rattrape un événement perdu.
- **Perte de connexion.** L'écran passe en « reconnexion » ; nouvelle tentative après 1, 2, 4, 8 puis 15 s (plafond). Au retour de l'agent, tout se recharge seul.
- **Agent absent.**
  - Non installé : la carte d'accueil propose l'installation.
  - À autoriser : guide vers Réglages Système › Général › Éléments de connexion.
  - Actif mais muet : « l'agent ne répond pas » et un bouton Réessayer.
  - Version incompatible : on cesse de réessayer vite et on affiche « mettez à jour l'agent ou l'app ».
- **Actions.** L'interface attend la confirmation de l'agent au lieu d'afficher l'effet d'avance (roue d'attente sur le bouton). Une erreur s'affiche dans une alerte avec le message de l'agent.
- **Fils d'exécution.** Les rappels XPC repassent sur le fil principal avant de toucher l'état.

## 5. Écrans

**Tableau de bord**
- En-tête : pastille d'état de l'agent et bouton **Pause globale** avec une phrase d'explication.
- Bandeaux : agent injoignable, à autoriser ou version incompatible ; « l'agent est reparti en pause (fichier d'état illisible) » avec un bouton Reprendre ; `tasks.json` illisible.
- Une **carte par tâche** : nom, mode, état (au repos, en cours, en pause, en file, en attente avec la raison, validation requise, désactivée), dernier résumé, prochaine exécution ; pendant une copie : barre de progression, fichier en cours, débit, temps restant (formats de `Formatting`). Boutons Lancer, Pause ou Reprendre, Arrêter ; quand la tâche attend une validation : le motif du blocage et **Valider les suppressions**.
- Ordre : en cours ou en pause, puis à valider, en attente, puis par prochaine échéance.
- Sans tâche : message honnête (« la création de tâches arrive en 3b ; d'ici là, `syncmacpro-ctl add` »).

**Barre de menus** (`MenuBarExtra`, panneau)
- Icône : repos `arrow.triangle.2.circlepath` ; copie : pourcentage (ou « 2 copies ») ; pause `pause.circle` ; erreur : triangle d'alerte dès qu'une tâche a échoué, est bloquée ou attend une validation.
- Panneau : copies actives avec progression, 3 prochaines exécutions, Pause globale, Ouvrir SyncMacPro, Quitter.

**Historique**
- Tableau : date, tâche, état, durée, fichiers, taille, erreurs.
- Filtres : tâche, état, période (24 h, 7 jours, 30 jours, tout), recherche sur le nom ; filtrage dans l'app sur les 500 dernières exécutions.
- Volet de détail : résumé et motif d'un échec ou d'un blocage. Pas de journal.
- Rafraîchi à la fin de chaque exécution ; erreur de lecture : message avec Réessayer.

**Réglages** : apparence (automatique, clair, sombre) ; « Ouvrir à la connexion » (`SMAppService.mainApp`) ; agent (état, installer, désinstaller, ouvrir Réglages Système) ; afficher le dossier des données dans le Finder ; à propos.

**Premier lancement** : écran de bienvenue qui propose d'installer l'agent.

**Transversal** : français (langue source) et anglais dans un catalogue `Localizable.xcstrings`, VoiceOver (libellés sur les cartes et les barres de progression), raccourcis standards (⌘,).

## 6. Ajouts côté agent (nécessaires à 3a)

1. `AgentWatch` signale la **fin de connexion** (`onEnd`) : sans cela l'interface resterait figée après un redémarrage de l'agent.
2. **Fuite d'observateur** quand un client se déconnecte avant que l'abonnement ne soit enregistré : corrigée.
3. `AgentTaskInfo` gagne `progress: ProgressInfo?` (avancement courant d'une tâche en cours). Champ optionnel, donc compatible : la version du contrat XPC reste **1**.

## 7. Tests

- **`AgentModel`** avec une fausse connexion scriptée et un dormeur injecté (aucune attente réelle) : connexion réussie, injoignable puis reconnexion (suite 1, 2, 4, 8, 15), avancement appliqué sans relecture, rafales d'événements regroupées, version incompatible sans réessai rapide, erreurs d'action remontées, pause globale.
- **Fonctions pures** : `MenuBarState`, `CardOrdering`, `HistoryFilter`, `CardText` (horloge injectée, français et anglais).
- **`AgentInstaller`** avec un faux `SMAppService` ; test de **complétude du catalogue** (aucune clé sans traduction).
- **Rendu** : `ImageRenderer` sur chaque écran, en clair et en sombre, avec des données factices ; le test vérifie que l'image n'est pas vide et s'ignore proprement si l'environnement n'a pas d'écran. Inspection manuelle des PNG pendant l'implémentation.
- **Agent** : tests XPC pour la fin de connexion, la fuite d'observateur et l'avancement dans l'état.
- **Manuel** (liste de vérifications) : construire le bundle, ouvrir l'app, installer l'agent, ajouter une tâche avec `ctl`, voir la carte progresser, tuer l'agent et voir la reconnexion, vérifier l'icône de la barre de menus en copie.
- Les tests existants (241) restent verts ; CI sur macOS 14 (Swift 5.10).

## 8. Risques

| Risque | Parade |
|---|---|
| Swift 5.10 du CI plus strict que le Swift 6.3 local (deux PR déjà cassées) | Pas de variable capturée dans les closures concurrentes ; le CI est le seul juge |
| `ImageRenderer` sans écran sur le runner | Tests de rendu ignorés proprement si le rendu échoue |
| Icône dynamique du `MenuBarExtra` (rafraîchissement, limites connues) | Essai réel dès la première tâche concernée |
| Catalogue `.xcstrings` dans SwiftPM | Vérifié par un test de complétude et un essai de build |
| Bundle de développement : l'app devient le programme principal, `syncmacpro-ctl` n'est plus l'exécutable du bundle | `agent install` passe désormais par l'app (réglages) ; `ctl agent install` reste utilisable car `Bundle.main` est le bundle (à vérifier) |
| Alerte d'autorisation macOS (Éléments de connexion) mal comprise | Écran dédié avec bouton qui ouvre Réglages Système |

## 9. Hors périmètre (YAGNI)

Création, édition, duplication de tâches ; modèles d'accueil ; copie à deux panneaux ; connexions Google Drive ; journal détaillé ; réglages par défaut des tâches (limites, notifications) ; menu de clic droit de la barre de menus ; icône définitive ; signature, notarisation et mises à jour.
