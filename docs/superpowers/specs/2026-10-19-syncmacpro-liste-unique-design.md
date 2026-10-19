# SyncMacPro — liste unique ordonnée (façon SyncBackPro)

Date : 2026-10-19 · Statut : à valider par l'auteur · Version visée : **1.7.0**

## 1. Pourquoi

Aujourd'hui il faut regarder trois endroits pour savoir ce qui se passe : les cartes du tableau de bord, le panneau
« File d'attente » et l'onglet Historique. La file d'attente est en plus un objet à part : il faut y ajouter des tâches
puis la « lancer » avec son bouton. L'auteur trouve ce principe compliqué à comprendre. Il veut un écran comme
SyncBackPro : une seule liste de tâches en lignes, dont l'ordre est l'ordre de passage, et le détail de la tâche
cliquée sous la liste.

### Succès
- Un seul écran suffit pour voir toutes les tâches, ce qui tourne, ce qui attend (et pourquoi), et l'historique d'une
  tâche.
- Glisser une ligne (ou plusieurs lignes sélectionnées) change l'ordre de passage, enregistré.
- La nuit, les copies dues partent dans l'ordre de la liste, deux à la fois au plus, jamais deux sur le même disque
  physique (sauf forçage).
- « Forcer » démarre une copie tout de suite, quelles que soient les limites.

### Anti-objectifs (échec même si « ça marche »)
- Réordonner la liste n'arrête ni ne met en pause une copie en cours.
- Plus de bouton « Lancer la file » ni de file séparée à remplir.
- Pas de perte d'information par rapport à aujourd'hui : progression, état du disque amovible, garde-fou de
  suppression à valider, nouvelle tentative, attente d'un partage, mise à jour en attente.

## 2. Décisions de l'auteur

| Sujet | Décision |
|---|---|
| Disposition | Une liste de **blocs allongés** (une ligne par tâche), le **détail en bas** de la fenêtre (choix A des maquettes, comme SyncBackPro) |
| Ordre | **L'ordre de la liste est l'ordre de départ** : quand plusieurs copies attendent, la plus haute part en premier, puis la suivante, de haut en bas |
| Réordonner | Glisser-déposer les lignes ; on peut **sélectionner plusieurs blocs** et les déplacer ensemble |
| Parallélisme | **Deux copies en même temps** au plus, si elles ne touchent pas le même **disque physique** |
| Disque physique | Compté en **source comme en destination**. Limités : le NAS du travail (ses partages 01_PROJETS_ACTIFS et 03_ARCHIVES_GLOBALES = un seul disque), le QNAP, chaque disque externe, tout autre disque local que le disque interne. Non limités : le **SSD interne du Mac** et **Google Drive** (proposition de Claude acceptée par l'auteur) |
| Forcer | « Forcer » démarre tout de suite et **passe outre toutes les limites** (nombre de copies et disque occupé) |
| Clic sur un bloc | Détail en bas avec son **historique** ; onglet Réglages pour modifier **l'essentiel** d'une tâche programmée, avec un bouton vers **l'éditeur complet** |
| Copie en pause | Elle **libère sa place et son disque** ; à la reprise elle **attend son tour** si les deux places sont prises (ou si son disque est occupé), **sauf si elle est forcée** |
| Copie ponctuelle | Placée **en haut** de la liste : elle part dès qu'une place se libère ; bouton **« Forcer »** pour ne pas attendre |
| Historique global | **Supprimé** (l'historique est dans le détail de chaque tâche) |
| Barre de menus, mode mini | **Gardés** |

## 3. Comportement

### 3.1 La liste
- Chaque tâche a un **rang** (1, 2, 3…), enregistré par l'agent (il survit aux redémarrages). Une nouvelle tâche arrive
  en bas. Une tâche supprimée sort de la liste. Les tâches désactivées restent à leur place, grisées.
- Une copie ponctuelle (« Copier une fois », écran Copier) apparaît comme une ligne temporaire **en haut** de la liste
  (au-dessus des tâches, dans l'ordre des demandes), marquée « ponctuelle », et disparaît quand elle est finie. Elle part
  dès qu'une place se libère ; « Forcer » (sur la ligne, et dans l'écran Copier à la place de l'ancien « Ajouter à la
  file ») la démarre tout de suite.
- Une ligne montre : poignée de déplacement, rang, nom, « source → destination » en clair (type de lieu : Bureau, NAS
  Synology, QNAP, disque externe, Drive partagé…), horaire, état (avec barre de progression pendant la copie et la
  **raison de l'attente** : « même disque que n° 2 », « 3ᵉ place », « hors plage horaire », « partage injoignable,
  nouvel essai à HH:MM », « disque non branché », « mise à jour installée… »), dernière exécution (date + réussie /
  échec), et les boutons utiles selon l'état (comme aujourd'hui sur les cartes : lancer, forcer, pause, reprendre,
  arrêter, valider la suppression, éjecter, abandonner la sauvegarde en pause).
- Sélection : clic, ⇧-clic, ⌘-clic. Sur une sélection (menu contextuel et boutons de la barre) : Lancer, Forcer, Pause,
  Activer / Désactiver. Glisser une sélection la déplace d'un bloc.

### 3.2 Ordre de départ (agent)
- Une exécution **attend** quand elle est due (horaire, nouvel essai, rattrapage, disque branché) ou demandée par
  « Lancer ». Les conditions (secteur, réseau, plage horaire, disque branché) s'appliquent comme aujourd'hui ; une
  demande manuelle les ignore comme aujourd'hui.
- Dès qu'une place se libère, l'agent démarre **l'exécution en attente la plus haute dans la liste** dont les disques
  physiques sont libres. Une exécution bloquée par son disque laisse passer les suivantes (elles prennent la place
  libre).
- **Forcer** : démarre immédiatement, même au-delà de deux copies, même sur un disque occupé. La pause globale et la
  mise à jour en attente (1.6.7) restent prioritaires : « Forcer » est alors refusé avec un message clair (choix de
  Claude).
- Une copie **en pause** (à la main ou par la pause globale) ne compte plus dans les deux places et ne tient plus son
  disque : les suivantes peuvent partir. Sa **reprise** est une demande comme les autres : elle reprend dès qu'une place
  et son disque sont libres, selon son rang (affichée « en pause, reprise en attente : … ») ; **« Forcer la reprise »**
  la relance tout de suite. Une copie en pause retenue ainsi reste figée (son processus en pause) jusqu'à sa reprise.
- Réordonner ne touche pas aux copies en cours ; le nouvel ordre vaut pour les prochains départs.
- La règle « une copie à la fois par disque amovible » (1.6.3) et « un montage à la fois par partage » (1.6.6)
  deviennent des cas de la règle du disque physique.
- La file d'attente explicite actuelle (`userQueue`, `userQueueRunning`, `userQueueCurrent`, « Lancer la file »,
  « Ajouter à la file », `QueueSection`) disparaît. À la mise à jour : les éléments de l'ancienne file deviennent des
  demandes « Lancer » en attente si la file tournait, sinon ils sont oubliés ; leur ordre sert de début de liste
  (choix de Claude). Rang initial des autres tâches : l'ordre actuel de `tasks.json`.

### 3.3 Le détail (bas de la fenêtre)
- Séparation redimensionnable entre la liste et le détail ; rien de sélectionné : le détail invite à cliquer une
  tâche. Plusieurs blocs sélectionnés : le détail montre le nombre et les actions groupées.
- Onglets :
  - **Historique** : les exécutions de la tâche (date, durée, état, résultat : fichiers, volume, message), les plus
    récentes en haut ; « Vider l'historique de cette tâche » ; double-clic → journal de l'exécution. Chargé à la
    sélection (l'agent sait déjà filtrer par tâche).
  - **Réglages** : l'essentiel modifiable sur place — horaire (manuel / chaque jour à… / jours ouvrés / toutes les N
    minutes ; pour une tâche déjà liée à un disque amovible : « à chaque branchement » / « au plus tous les N jours »),
    activée ou non, conditions (secteur, plage horaire autorisée). Lier ou délier un disque reste dans l'éditeur
    complet (choix de Claude). Bouton
    **« Modifier… »** qui ouvre l'éditeur complet actuel (source, destination, mode, exclusions…). Pour une tâche
    sans horaire, l'onglet montre aussi l'horaire « à la main ».
  - **Journal** : la fin du journal de l'exécution en cours, ou de la dernière.

### 3.4 Ce qui reste, ce qui part
- Reste : barre de menus (sa section « à venir » suit l'ordre de la liste), mode mini (copies en cours, puis les
  prochaines en attente dans l'ordre de la liste, à la place de la file), Copier, Connexions, Réglages, éditeur.
- Historique sans tâche dans la liste (copies ponctuelles terminées, tâches supprimées) : une dernière ligne fixe
  « Autres exécutions », non déplaçable, dont l'onglet Historique les montre — rien n'est perdu (choix de Claude).
- Part : l'onglet **Historique** global, le panneau **File d'attente**, la grille de cartes du tableau de bord.
- `syncmacpro-ctl` : `status` affiche les tâches dans l'ordre de la liste avec leur rang ; `queue start|stop` est
  retiré ; `queue up|down <tâche>` déplace d'un rang ; `queue` liste l'ordre ; ajout de `force <tâche>` (choix de
  Claude, à garder simple).

## 4. Laissé au constructeur
- Comment identifier un disque physique : partage réseau → son serveur (hôte de l'adresse smb, en minuscules) ; dossier
  local → le disque entier qui porte le volume (DiskArbitration), le disque de démarrage étant non limité ; Drive et
  autres services en ligne → aucun. Deux noms différents pour un même serveur (adresse IP et nom Bonjour) comptent pour
  deux : limite acceptée.
- Le détail du glisser-déposer en SwiftUI (List + `onMove` multi-sélection, ou table), le rendu exact des lignes et de
  la séparation, tant que la maquette A est respectée.
- La forme des nouveaux messages agent ↔ app (ordre complet envoyé à chaque déplacement, rang dans `AgentTaskInfo`,
  raison d'attente, « forcer ») et la compatibilité avec un agent plus ancien pendant une mise à jour (champs
  optionnels, comme `restartPending`).
- Textes français et anglais, à la manière des textes actuels.

## 5. Tests attendus
- Agent : départ dans l'ordre de la liste, deux places, disque physique occupé (source ou destination) qui laisse
  passer la suivante, partages d'un même NAS comptés ensemble, SSD interne et Drive non limités, Forcer au-delà des
  limites, réordonner sans toucher aux copies en cours, rang enregistré et migration de l'ancienne file, copie
  ponctuelle en bas de liste.
- App : rendu de la liste et du détail (comme les tests de rendu actuels), sélection multiple et déplacement, onglet
  Réglages qui enregistre l'horaire, bouton vers l'éditeur, historique d'une tâche chargé à la sélection, mode mini et
  barre de menus dans l'ordre de la liste.
