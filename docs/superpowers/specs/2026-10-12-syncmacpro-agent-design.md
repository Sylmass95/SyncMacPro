# SyncMacPro — sous-projet 2 : l'agent d'arrière-plan

Date : 2026-10-12 · Statut : à relire · Complète le §6 de `2026-10-12-syncmacpro-design.md`

## 1. Objectif

Faire tourner les tâches de synchronisation **app fermée** : planification, exécution, pause / reprise / arrêt, pause globale qui survit au redémarrage, rattrapage après veille, notifications et historique. L'agent se pilote par **XPC** et par un **outil en ligne de commande** `syncmacpro-ctl`. Il n'y a **pas d'interface graphique** (sous-projet 3), mais le contrat XPC est celui que l'interface utilisera.

### Succès
- Une tâche planifiée s'exécute à l'heure dite sans qu'aucune app ne soit ouverte.
- Après veille ou redémarrage, une tâche en retard s'exécute **une seule fois**.
- La pause globale tient après un redémarrage du Mac.
- Tuer l'agent ne perd rien : l'historique marque les exécutions « interrompues » et launchd relance l'agent.
- Tout le comportement du planificateur est testable sans attendre le temps réel.

## 2. Décisions prises

| Sujet | Décision |
|---|---|
| Architecture | Un seul paquet SwiftPM : cœur pur dans `SyncKit`, exécutables `syncmacpro-agent` et `syncmacpro-ctl` |
| Planification | Calcul des échéances dans l'agent (pas de `StartCalendarInterval`), horloge injectée |
| Enregistrement | `SMAppService.agent(plistName:)`, plist dans `Contents/Library/LaunchAgents` du bundle |
| Signature | Ad hoc suffit (vérifié par un spike sur macOS 26) ; pas de compte développeur requis |
| Écriture des données | **L'agent est le seul à écrire** historique, état et tâches |
| Hors périmètre | Interface graphique, notarisation, conditions réseau fines (Wi-Fi précis, VPN) |

### Résultats du spike (macOS 26, app signée ad hoc dans `~/Applications`)
- Statut `notFound` → `enabled` sans validation manuelle ; l'enregistrement par une app ad hoc est accepté.
- XPC (service Mach déclaré dans le plist) fonctionnel.
- L'agent a launchd pour parent et survit à la fermeture de l'app.
- Après un arrêt brutal, launchd relance l'agent à la demande, **avec un délai d'environ 10 s** (régulation anti-boucle). Le client attend donc jusqu'à 20 s avant de conclure que l'agent est absent.
- Non vérifié : macOS 14 / 15, et l'approbation dans Éléments de connexion sur une machine tierce → mode de repli prévu (§8).

## 3. Composants

| Unité | Rôle | Dépend de |
|---|---|---|
| `Scheduler` (SyncKit, pur) | Calcule `nextDue`, décide quelles tâches lancer à un instant donné | `SyncTask`, `Schedule`, `Clock` |
| `Clock` (protocole) | `now()` et fuseau ; `SystemClock` en production, horloge fausse en test | — |
| `SchedulerState` (SyncKit) | État persistant : dernière exécution, tentatives, prochaine tentative, pause globale | `Codable` JSON |
| `JobQueue` (SyncKit) | File ordonnée par échéance, 2 exécutions en parallèle maximum, jamais deux fois la même tâche | `TaskRunning` |
| `TaskRunning` (protocole) | Interface de `TaskRunner` ; un faux en test | — |
| `AgentProtocol`, DTO (SyncKit) | Contrat XPC versionné, messages `Codable` | — |
| `syncmacpro-agent` | Boucle d'évaluation, serveur XPC, notifications, assertion anti-veille | tout ce qui précède |
| `syncmacpro-ctl` | Client XPC en ligne de commande | `AgentProtocol` |
| `AgentRegistration` | Enregistre / retire l'agent via `SMAppService`, expose l'état | `ServiceManagement` |

## 4. Planification et rattrapage

L'agent évalue les tâches **chaque minute** et à chaque réveil du Mac.

**`nextDue(task, lastRun, now)`**
- `manual` : jamais.
- `daily(h, m)` : prochaine occurrence locale de l'heure.
- `weekdays(jours, h, m)` : prochaine occurrence parmi les jours choisis.
- `everyMinutes(n)` : `lastRun + n` minutes ; première exécution immédiate si jamais lancée.
- `whenAvailable` : dès que source et destination sont toutes deux accessibles et que la dernière exécution est terminée.
- Les changements d'heure (été / hiver) ne doivent ni sauter ni dupliquer une exécution quotidienne.

**Rattrapage.** Une tâche dont une échéance est passée (veille, extinction, agent arrêté) s'exécute **une seule fois**, pas une fois par échéance manquée, **60 s** après le réveil pour laisser revenir le réseau.

**Conditions** (par tâche) : secteur, réseau disponible, plage horaire. Une condition non remplie met la tâche **en attente** : ce n'est ni un échec ni une échéance manquée, la tâche repart dès que tout est réuni.

**Échec.** Nouvelle tentative après 1 h par défaut, 3 essais au maximum, puis la tâche attend son échéance normale et une notification d'erreur part.

**Pause globale.** Plus rien ne démarre, les exécutions en cours sont mises en pause, l'état est écrit sur disque (`paused: true`). Après redémarrage, l'agent relit l'état et reste en pause. À la reprise, le rattrapage s'applique comme après une veille.

## 5. Exécution et concurrence

- L'agent appelle `TaskRunner` du sous-projet 1 sans le modifier.
- **2 exécutions en parallèle au maximum**, les autres attendent par ordre d'échéance.
- Une tâche ne tourne qu'**une fois à la fois** ; une échéance qui revient pendant l'exécution est ignorée.
- Une assertion anti-veille est tenue tant qu'une exécution est en cours et relâchée quand la file est vide.
- **Mode miroir :** la garde de suppression du sous-projet 1 s'applique. Si elle bloque, la tâche passe en « attente de validation », une notification part, et rien ne s'exécute avant `approveDeletion`.
- **Arrêt de l'agent** (déconnexion, extinction, SIGTERM) : les exécutions en cours sont arrêtées proprement (`terminate(killAfter:)`), marquées « interrompues » (`markRunningAsInterrupted`) et rattrapées au démarrage suivant.

## 6. État, historique, notifications

- **Fichiers** (dans `~/Library/Application Support/SyncMacPro/`) : `tasks.json` (existant, `TaskStore`), `scheduler-state.json` (nouveau), `history.sqlite` (existant, `HistoryStore`).
- **Seul l'agent écrit.** App et CLI lisent via XPC et demandent les modifications à l'agent. `tasks.json` reste modifiable à la main : l'agent le surveille et le recharge.
- **Écriture atomique** de `scheduler-state.json` (fichier temporaire puis renommage) ; un fichier illisible ou corrompu est mis de côté (`.corrupt`) et l'agent repart d'un état vierge **en pause**, pour ne rien lancer par surprise.
- **Rétention** de l'historique : 90 jours par défaut, purge quotidienne.
- **Notifications** par `UNUserNotificationCenter`, selon `NotificationPolicy` de chaque tâche. Elles exigent que l'agent soit dans le bundle de l'app.

## 7. Contrat XPC et CLI

`AgentProtocol` (`@objc`, messages `Codable` en JSON), numéro de version dans chaque échange :

- **Lectures :** `status()`, `listTasks()`, `history(taskID:limit:)`.
- **Commandes :** `runNow`, `pause`, `resume`, `stop` (par tâche), `setGlobalPause(Bool)`, `approveDeletion`, `reloadTasks`.
- **Suivi en direct :** le client exporte un `AgentObserver` ; l'agent y pousse l'avancement (octets, fichier en cours, vitesse, état).
- **Version incompatible :** erreur explicite « mettez à jour l'agent ou l'app », jamais un échec silencieux.
- **Sécurité :** service Mach visible seulement dans la session de l'utilisateur ; l'agent vérifie l'identité de signature du client quand elle existe, sinon se limite au même utilisateur (signature ad hoc).
- **Délai :** le client réessaie jusqu'à 20 s si l'agent n'est pas encore relancé.

**CLI `syncmacpro-ctl`** : `status`, `list`, `run <tâche>`, `pause|resume|stop <tâche>`, `pause-all`, `resume-all`, `history <tâche>`, `watch`, `approve <tâche>`, `agent install|uninstall|status`. Sortie lisible, `--json` pour les scripts, code de sortie non nul si l'agent est injoignable.

## 8. Enregistrement et repli

- `scripts/make-dev-bundle.sh` assemble un bundle ad hoc (app minimale + plist + agent) dans `~/Applications` pour le développement.
- `requiresApproval` : le CLI explique comment autoriser l'agent dans Réglages Système › Éléments de connexion et peut ouvrir ce volet.
- **Repli sans bundle :** `syncmacpro-agent --foreground` fait tourner l'agent dans le terminal, sans launchd ; sert au débogage et aux tests d'intégration.
- Désinstallation : `agent uninstall` désenregistre l'agent ; les données de `Application Support` restent.

## 9. Tests

- **Planificateur** (horloge injectée) : chaque `Schedule`, bascule d'heure, rattrapage unique, conditions, nouvelles tentatives, pause globale.
- **File** (faux `TaskRunning`) : limite de 2, pas de doublon, arrêt propre, mode miroir bloqué puis validé.
- **État :** écriture atomique, fichier corrompu → démarrage en pause.
- **XPC :** agent lancé en `--foreground` sur un service Mach de test, piloté par un vrai client ; incompatibilité de version.
- **Intégration** (derrière un drapeau, lent) : vraie copie rsync planifiée toutes les minutes sur dossiers temporaires, redémarrage de l'agent en cours d'exécution.
- Les tests existants du sous-projet 1 restent verts ; CI sur macOS 14.

## 10. Risques

| Risque | Parade |
|---|---|
| macOS 14 / 15 ou autre machine refusent l'enregistrement ad hoc | Mode de repli `--foreground`, message d'approbation clair ; test sur une seconde machine avant la v1 |
| Délai de relance launchd (~10 s) | Client patient (20 s), documenté |
| Veille pendant une copie | Assertion anti-veille ; reprise via interruption + rattrapage |
| Volume réseau absent au réveil | Condition « réseau / volume accessible », délai de 60 s, nouvelles tentatives |
| Corruption de l'état | Écriture atomique, démarrage en pause |

## 11. Hors périmètre (YAGNI)

Interface graphique ; notarisation et distribution ; conditions réseau fines (SSID, VPN, connexion limitée) ; exécutions distantes ou multi-utilisateurs ; planification à la seconde.
