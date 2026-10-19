# Liste unique ordonnée (1.7.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remplacer les cartes, le panneau « File d'attente » et l'historique global par une seule liste ordonnée (ordre = ordre de départ), avec le détail de la tâche sous la liste, comme SyncBackPro.

**Architecture:** L'agent garde un ordre persistant des tâches (`SchedulerState.order`) et choisit, à chaque place libre, l'exécution en attente la mieux classée dont les disques physiques sont libres ; la file explicite disparaît (anciens messages redirigés). L'app affiche une `List` réordonnable à sélection multiple au-dessus d'un panneau de détail (Historique / Réglages / Journal).

**Tech Stack:** Swift 5.10, SwiftUI macOS 14, XCTest, DiskArbitration ; agent launchd + XPC existants.

**Spec:** `docs/superpowers/specs/2026-10-19-syncmacpro-liste-unique-design.md`

## Global Constraints

- Version **1.7.0** (`VERSION`, `docs/release-notes.md`).
- Deux copies en même temps au plus (`AgentConfiguration.maxParallel = 2`), jamais deux sur un même disque physique, en source comme en destination ; SSD interne du Mac et Google Drive non limités ; les partages d'un même serveur comptent pour un disque.
- « Forcer » passe outre le nombre de copies et le disque occupé ; refusé en pause globale (`AgentError.globallyPaused`) et pendant `restartPending` (`AgentError.restartPending`).
- Copie en pause : ne compte ni dans les places ni pour son disque ; sa reprise attend son tour, sauf forçage.
- Copie ponctuelle : en haut de la liste, part dès qu'une place se libère.
- Réordonner n'arrête ni ne met en pause aucune copie en cours.
- Messages agent ↔ app compatibles avec la version précédente pendant une mise à jour : nouveaux champs optionnels, anciennes requêtes (`enqueue`, `enqueueOnce`, `dequeue`, `moveInQueue`, `setQueueRunning`) toujours décodées et redirigées.
- Textes FR et EN dans `Localizable.strings` (les deux fichiers).
- CI : Swift 5.10 refuse une `var` capturée par une closure concurrente ou `async let`.

## Review Focus

1. Glisser une tâche pendant qu'elle copie : la copie continue, son rang change (test Tâche 1).
2. L'app envoie un ordre périmé (tâche créée ou supprimée entre-temps) : l'agent garde les tâches inconnues de l'ordre à la fin et ignore les identifiants disparus (test Tâche 1).
3. Une tâche de disque amovible branchée alors que les deux places sont prises : elle attend avec sa raison, puis part ; débranchée pendant l'attente, elle quitte l'attente (test Tâche 2).
4. Reprise d'une copie en pause alors que son disque est pris par une autre : « en pause, reprise en attente : même disque que … », puis reprise automatique quand le disque se libère (test Tâche 2).
5. Ancienne file en cours au moment de la mise à jour : ses éléments deviennent des demandes « Lancer » en tête, sans double départ de l'élément en cours (test Tâche 1).

---

### Task 1: Ordre persistant des tâches dans l'agent

**Files:**
- Modify: `Sources/SyncKit/Agent/SchedulerState.swift` (champ `order`, décodage)
- Create: `Sources/SyncKit/Agent/AgentCore+Order.swift`
- Modify: `Sources/SyncKit/Agent/AgentCore.swift` (`loadTasks`, `start`, `status`)
- Modify: `Sources/SyncKit/Agent/AgentTypes.swift` (`AgentTaskInfo.rank`)
- Modify: `Sources/SyncKit/Agent/AgentProtocol.swift`, `AgentRouter.swift`, `AgentXPC.swift` (requête `reorder`)
- Test: `Tests/SyncKitTests/AgentOrder170Tests.swift`

**Interfaces:**
- Produces: `SchedulerState.order: [UUID]` (decodeIfPresent, `[]` par défaut) ; `AgentCore.reorder(_ ids: [UUID])` ; `AgentCore.rank(of id: UUID) -> Int` (0 = premier ; copies ponctuelles avant toutes les tâches, dans l'ordre de leur demande, via `oneOffOrder: [UUID]` en mémoire) ; `AgentTaskInfo.rank: Int?` (1-based pour les tâches, `nil` pour une ponctuelle) ; `AgentRequest.reorder([UUID])` ; `status().tasks` triés : ponctuelles d'abord, puis par rang.

- [ ] **Step 1: Write the failing tests** — `testNewTasksGoToTheEndAndDeletedOnesLeave` (3 tâches enregistrées → `order` = ordre de `tasks.json` ; ajout d'une 4ᵉ → rang 4 ; suppression de la 2ᵉ → rangs 1,2,3) ; `testReorderIsPersistedAndSurvivesARestart` (reorder [C,A,B], nouvel `AgentCore` sur le même état → `status().tasks.map(\.name) == ["C","A","B"]`, `rank` 1,2,3) ; `testAStaleOrderKeepsUnknownTasksAtTheEnd` (reorder [B, inconnu] avec A,B,C → [B,A,C]) ; `testReorderingARunningTaskDoesNotTouchIt` (gated, A en cours, reorder [B,A] → runner A sans "pause"/"stop" dans `calls`) ; `testARunningOldQueueBecomesRunRequestsOnTop` (état avec `userQueue=[B,C]`, `userQueueRunning=true`, `userQueueCurrent=A` → au démarrage : order commence par [A,B,C], B et C demandés (manuels), A rattrapé une seule fois, `userQueue` vide et `userQueueRunning` faux après persistance) ; `testAStoppedOldQueueIsForgotten` (`userQueueRunning=false` → aucune demande, `userQueue` vidée).
- [ ] **Step 2: Run** `swift test --filter AgentOrder170Tests` — Expected: FAIL (compilation : `reorder`, `rank`, `order` absents).
- [ ] **Step 3: Implement** in `AgentCore+Order.swift`: `syncOrder()` (appelée par `loadTasks`) qui retire les ids disparus et ajoute les nouveaux à la fin ; `reorder(_:)` (ids connus dans l'ordre reçu, puis les absents dans leur ordre actuel, `persist()`, `emit(.stateChanged)`) ; `rank(of:)` ; migration de l'ancienne file dans `start()` (avant `advanceUserQueue`, supprimé en Tâche 3) : si `userQueueRunning`, `userQueueCurrent` puis `userQueue` placés en tête de `order` et `userQueue` mis en demandes manuelles (`QueuedRun(manual: true)`), l'élément courant restant rattrapé par le mécanisme `runningSince` ; dans tous les cas `userQueue = []`, `userQueueRunning = false`, `userQueueCurrent = nil`. Route `.reorder` dans `AgentRouter` et ajoute `reorder(_:)` au client XPC.
- [ ] **Step 4: Run** `swift test --filter AgentOrder170Tests` — Expected: PASS.
- [ ] **Step 5: Commit** `1.7.0 : ordre des tâches enregistré par l'agent (reorder, rang, migration de l'ancienne file)`.

### Task 2: Départ par rang, disque physique, pause qui libère sa place

**Files:**
- Create: `Sources/SyncKit/Agent/PhysicalDevice.swift`
- Modify: `Sources/SyncKit/Agent/AgentTypes.swift` (`SystemConditions.physicalDevice`, `AgentTaskInfo.waitReason`, `resumePending`)
- Modify: `Sources/SyncKit/Agent/System/MacSystemConditions.swift`
- Modify: `Sources/SyncKit/Agent/AgentCore.swift` (`startQueued`, `status`), `AgentCore+Drives.swift` (`handleDrives`, `driveBusy`), `AgentCore+Control.swift` (`resume`)
- Modify: `Tests/SyncKitTests/AgentTestSupport.swift` (`FakeConditions.devices: Locked<[String: String]>` chemin-préfixe → clé)
- Test: `Tests/SyncKitTests/AgentDevices170Tests.swift`

**Interfaces:**
- Consumes: `rank(of:)` (Tâche 1).
- Produces: `protocol SystemConditions { func physicalDevice(_ endpoint: Endpoint) -> String? }` (`nil` = non limité) ; `PhysicalDevice.networkKey(url: String) -> String?` (`"net:" + hôte en minuscules`) ; `AgentCore.devices(of task: SyncTask) -> Set<String>` ; `AgentCore.busyDevice(for task: SyncTask) -> (key: String, holder: UUID)?` (jobs **non en pause** seulement) ; `Job.resumeRequested: Bool` ; `AgentTaskInfo.waitReason: String?` et `AgentTaskInfo.resumePending: Bool?`.

- [ ] **Step 1: Write the failing tests** — `testWaitingRunsStartInListOrder` (3 tâches dues ensemble, ordre [C,B,A] → les deux premiers runners sont C puis B, A ensuite) ; `testABusyDiskLetsTheNextOneGo` (A et B vers le même disque « nas », C ailleurs, ordre [A,B,C] → A et C démarrent, B attend avec `waitReason` contenant « même disque que « A » ») ; `testASourceCountsLikeADestination` (A : nas → drive, B : drive → nas → pas ensemble) ; `testTwoSharesOfTheSameServerAreOneDisk` (`PhysicalDevice.networkKey("smb://moi@10.92.7.3/01_PROJETS_ACTIFS") == PhysicalDevice.networkKey("smb://moi@10.92.7.3/03_ARCHIVES_GLOBALES")`) ; `testInternalDiskAndCloudAreNotLimited` (`physicalDevice` nil → A et B partent ensemble) ; `testThirdRunWaitsForAPlace` (`waitReason` contient « place ») ; `testAPausedCopyFreesItsPlaceAndDisk` (A en cours puis en pause → B même disque démarre) ; `testResumingWaitsForItsDisk` (A en pause, B tient le disque : `resume(A)` → `resumePending == true`, A toujours en pause ; B finit → A reprend : `calls` de A finit par "resume") ; `testADriveTaskPluggedWhileBothPlacesAreTakenWaitsThenStarts` et `testAnUnpluggedDriveTaskLeavesTheWait` (Review Focus 3).
- [ ] **Step 2: Run** `swift test --filter AgentDevices170Tests` — Expected: FAIL.
- [ ] **Step 3: Implement** : `MacSystemConditions.physicalDevice` — `.network(url:_)` → `PhysicalDevice.networkKey` ; `.local(path)` sous `/Volumes/<X>` → `"disk:" +` disque entier DiskArbitration (`DADiskCreateFromVolumePath` puis `DADiskCopyWholeDisk`, nom BSD), sinon (disque de démarrage) `nil` ; `.cloud` → `nil`. Tâche de disque amovible : appareils calculés sur `resolvedForDrive(task)`. `startQueued` : tant que les jobs **non en pause** sont < `maxParallel`, choisir parmi `queue` (et les jobs en pause avec `resumeRequested`) l'élément de plus petit `rank` dont `busyDevice` est `nil` ; les autres restent avec `waiting[id]` = « même disque que « nom » » ou « en attente d'une place (n° k) ». `handleDrives` n'appelle plus `startJob` : il ajoute un `QueuedRun` (manual: false, avec le `resuming` éventuel conservé dans un dictionnaire `pendingResumes[id]`) puis `startQueued()`. `driveBusy` devient un cas de `busyDevice`. `resume(id)` : si une place et les disques sont libres → reprise immédiate, sinon `resumeRequested = true` + `emit`. `status()` remplit `waitReason` (pour `.queued`) et `resumePending`.
- [ ] **Step 4: Run** `swift test --filter "AgentDevices170Tests|AgentOneCopyPerDriveTests|AgentDrive|AgentCoreTests"` — Expected: PASS (adapter les anciens tests de « une copie par disque » si leur attente change de forme, sans affaiblir ce qu'ils vérifient).
- [ ] **Step 5: Commit** `1.7.0 : départ dans l'ordre de la liste, un disque physique à la fois, la pause libère sa place`.

### Task 3: Forcer, fin de la file explicite, ctl

**Files:**
- Modify: `Sources/SyncKit/Agent/AgentCore+Control.swift` (`force`), `AgentCore+Queue.swift` (supprimé ou réduit aux redirections), `AgentCore+OneOff.swift`
- Modify: `Sources/SyncKit/Agent/AgentProtocol.swift`, `AgentRouter.swift`, `AgentXPC.swift` (`force`)
- Modify: `Sources/SyncKit/Agent/CtlParser.swift`, `CtlSupport.swift`, `Sources/syncmacpro-ctl/main.swift`
- Test: `Tests/SyncKitTests/AgentForce170Tests.swift`, `Tests/SyncKitTests/CtlQueueTests.swift` (réécrit)

**Interfaces:**
- Consumes: Tâches 1–2.
- Produces: `AgentCore.force(_ id: UUID) throws` — idle ou en attente → `startJob` immédiat (hors limites) ; en pause → reprise immédiate ; en cours → rien ; tâche désactivée → `AgentError.invalidTask("Tâche désactivée…")` ; `AgentRequest.force(UUID)` ; anciennes requêtes : `enqueue(id)` → `runNow(id)`, `enqueueOnce(task)` → `runOnce(task)`, `dequeue(id)` → `stop(id)`, `moveInQueue(id, to:)` → `reorder` (déplacer `id` à l'index), `setQueueRunning` → sans effet ; `AgentStatus.queue` toujours `nil`. ctl : `queue` affiche « n° rang — nom — état » ; `queue up|down <tâche>` → `reorder` ; `queue start|stop` → message « La liste est la file : elle n'a plus besoin d'être lancée. » ; `force <tâche>`.

- [ ] **Step 1: Write the failing tests** — `testForceIgnoresTheTwoPlaces` (2 jobs en cours, `force(C)` → 3 runners) ; `testForceIgnoresABusyDisk` ; `testForceResumesAPausedCopyAtOnce` ; `testForceIsRefusedDuringAGlobalPause` (`AgentError.globallyPaused`) ; `testForceIsRefusedWhileARestartIsPending` ; `testAOneOffCopyGoesFirstInLine` (`runOnce` pendant 2 copies + 1 tâche en attente → la ponctuelle part avant la tâche en attente ; `status().tasks.first?.isOneOff == true`) ; `testOldQueueRequestsStillWork` (`enqueue` lance, `dequeue` retire de l'attente, `setQueueRunning(true)` ne fait rien) ; ctl : `testQueueListsTheOrder`, `testQueueUpMovesOneRank`, `testQueueStartExplainsThereIsNothingToStart`, `testForceParses`.
- [ ] **Step 2: Run** `swift test --filter "AgentForce170Tests|CtlQueueTests"` — Expected: FAIL.
- [ ] **Step 3: Implement** : `force` ; suppression de `userQueue*`, `advanceUserQueue`, `queuedOneOffs`, `Job.fromUserQueue` (appels supprimés de `tick`, `finish`, `start`, `afterJob`, `checkReplacedProgram`) ; `runOnce` ajoute la ponctuelle à `oneOffOrder` puis à `queue` (manuelle) au lieu de démarrer directement si les places sont prises ; redirections des anciennes requêtes dans `AgentRouter` ; ctl.
- [ ] **Step 4: Run** `swift test --filter SyncKitTests` — Expected: PASS (les tests de l'ancienne file `AgentQueueTests`, `Fix130ReviewTests`… sont supprimés ou réécrits sur le nouveau modèle ; chaque test supprimé est listé dans le commit).
- [ ] **Step 5: Commit** `1.7.0 : forcer, fin de la file explicite (anciens messages redirigés), ctl queue / force`.

### Task 4: Modèle de l'app

**Files:**
- Modify: `Sources/SyncMacProUI/Agent/AgentModel.swift`
- Modify: `Tests/SyncMacProUITests/FakeAgent.swift`
- Test: `Tests/SyncMacProUITests/ListModel170Tests.swift` (remplace `QueueModelTests.swift`)

**Interfaces:**
- Consumes: `AgentRequest.reorder`, `.force`, `AgentTaskInfo.rank/waitReason/resumePending`.
- Produces: `AgentModel.orderedTasks: [AgentTaskInfo]` (= `status.tasks`, déjà triés par l'agent) ; `move(_ ids: Set<UUID>, toOffset: Int) async` (calcule l'ordre complet à partir de `orderedTasks` sans les ponctuelles, envoie `.reorder`, met à jour l'affichage tout de suite) ; `force(_ id: UUID) async` ; `history(for taskID: UUID?, limit: Int = 200) async -> [RunRecord]` (`nil` = exécutions sans tâche connue : filtre côté app sur `taskID ∉ tasks`) ; suppression de `enqueue`, `dequeue`, `setQueueRunning`, `moveInQueue`, `enqueueOnce`, `queue`, `reloadHistory` global et `history` global (garder `clearHistory(taskID:)`).

- [ ] **Step 1: Write the failing tests** — `testMovingTwoSelectedTasksSendsTheFullOrder` (ordre [A,B,C,D], déplacer {C,D} à l'offset 0 → requête `.reorder([C,D,A,B])`) ; `testMoveKeepsOneOffsOutOfTheOrder` ; `testForceSendsForce` ; `testHistoryForATaskAsksTheAgentForThatTask` (FakeAgent enregistre `history(taskID: A, limit: 200)`) ; `testOtherRunsAreThoseOfUnknownTasks`.
- [ ] **Step 2: Run** `swift test --filter ListModel170Tests` — Expected: FAIL.
- [ ] **Step 3: Implement** the produced API ; FakeAgent enregistre `reorder`/`force` et filtre l'historique par tâche.
- [ ] **Step 4: Run** `swift test --filter SyncMacProUITests` — Expected: compile errors only in views still using the removed API (fixed in Tasks 5–7) : run `swift test --filter ListModel170Tests` → PASS. (Les vues gardent temporairement des appels inertes si besoin pour compiler ; Tâche 7 les retire.)
- [ ] **Step 5: Commit** `1.7.0 : modèle de l'app — ordre, forcer, historique par tâche`.

### Task 5: La liste (lignes, sélection, glisser-déposer, actions groupées)

**Files:**
- Create: `Sources/SyncMacProUI/Views/TaskListView.swift` (`TaskListView`, `TaskRow`)
- Create: `Sources/SyncMacProUI/Logic/RowText.swift` (textes d'une ligne : « source → destination » en clair, état + raison)
- Modify: `Sources/SyncMacProUI/Views/DashboardView.swift` (le contenu devient `VSplitView { TaskListView ; TaskDetailView }` — le détail arrive en Tâche 6, un espace vide en attendant)
- Modify: `Sources/SyncMacProUI/Views/TaskCard.swift` (garder `TaskCardActions` + `CardAction.availableActions`, ajouter `.force` ; retirer `.enqueue/.dequeue` ; `TaskCard` reste pour le mode mini)
- Delete: `Sources/SyncMacProUI/Logic/CardOrdering.swift`
- Modify: `Resources/fr.lproj` et `en.lproj/Localizable.strings`
- Test: `Tests/SyncMacProUITests/TaskList170Tests.swift` (remplace les parties cartes de `DashboardRenderTests`)

**Interfaces:**
- Consumes: `AgentModel.orderedTasks`, `move`, `force`, `runNow`, `pause`, `resume`, `stop`, `setEnabled`.
- Produces: `TaskListView(model:selection: Binding<Set<UUID>>, localizer:)` ; `TaskRow(info:task:progress:text:actions:)` ; `RowText.place(_ endpoint: Endpoint, drive: RemovableDrive?) -> String` (« Bureau », « Documents », « NAS (10.92.7.3) », « QNAP »… via le dernier composant du montage, « Disque « X » », « Drive partagé », « Google Drive ») ; `RowText.state(_ info: AgentTaskInfo) -> String` (inclut `waitReason`, « en pause, reprise en attente : … » si `resumePending`) ; clés : `list.rank`, `list.force`, `list.forceResume`, `list.column.*`, `list.selection.count`, `list.otherRuns`.

- [ ] **Step 1: Write the failing tests** — `testRowShowsRankPlacesStateAndWaitReason` (rendu d'un `TaskRow` : texte contient « 3 », « Bureau → QNAP », « même disque que « Mac PERSO-FILES → QNAP » ») ; `testRowActionsByState` (`CardAction.availableActions` : idle → `[.run, .force]`, en attente → `[.force, .stop]`, en pause avec reprise en attente → `[.force, .stop]`, en cours → `[.pause, .stop]`) ; `testPlaceNames` (valeurs ci-dessus) ; `testDisabledRowIsDimmed` ; `testOneOffRowIsMarked` (« ponctuelle ») ; `testListRendersInAgentOrder`.
- [ ] **Step 2: Run** `swift test --filter TaskList170Tests` — Expected: FAIL.
- [ ] **Step 3: Implement** : `List(selection:)` + `ForEach(...).onMove { model.move(...) }` (déplacement d'une sélection : `onMove` reçoit tous les index sélectionnés), menu contextuel sur la sélection (Lancer, Forcer, Pause, Activer / Désactiver), barre au-dessus de la liste avec les mêmes actions et le bouton de pause globale existant ; ligne fixe « Autres exécutions » en bas, non déplaçable (`moveDisabled`), sélectionnable (id réservé `TaskListView.otherRunsID`).
- [ ] **Step 4: Run** `swift test --filter "TaskList170Tests|DashboardRenderTests"` — Expected: PASS.
- [ ] **Step 5: Commit** `1.7.0 : tableau de bord en liste ordonnée (lignes, sélection, glisser-déposer)`.

### Task 6: Le détail en bas (Historique, Réglages, Journal)

**Files:**
- Create: `Sources/SyncMacProUI/Views/TaskDetailView.swift` (`TaskDetailView`, onglets)
- Create: `Sources/SyncMacProUI/Editing/QuickSettings.swift` (`QuickSettings` : horaire, activée, conditions, déclencheur de disque ; `apply(to: SyncTask) -> SyncTask`)
- Modify: `Sources/SyncMacProUI/Views/DashboardView.swift` (brancher le détail, `onEdit` → éditeur complet via `RootView.open`)
- Modify: `Sources/SyncMacProUI/Views/HistoryView.swift` (garder `HistoryTableBody` et `RunLogSheet`, réutilisés par l'onglet)
- Test: `Tests/SyncMacProUITests/TaskDetail170Tests.swift`

**Interfaces:**
- Consumes: `AgentModel.history(for:)`, `runLog`, `saveTask`, `clearHistory(taskID:)`.
- Produces: `TaskDetailView(model:selection: Set<UUID>, localizer:onEdit: (SyncTask) -> Void)` ; `QuickSettings(task: SyncTask)` avec `schedule: Schedule`, `isEnabled: Bool`, `requiresACPower: Bool`, `allowedHours: HourRange?`, `driveTrigger: DriveTrigger?` (seulement si `task.removableDrive != nil`), `func apply(to task: SyncTask) -> SyncTask`.

- [ ] **Step 1: Write the failing tests** — `testQuickSettingsChangeOnlyTheEssentials` (horaire quotidien 21:30 + plage 10–22 appliqués ; source, destination, exclusions inchangées) ; `testDriveTriggerOnlyForLinkedTasks` ; `testDetailWithNothingSelectedInvitesToClick` ; `testDetailWithTwoSelectedShowsTheCountAndGroupActions` ; `testHistoryTabLoadsTheSelectedTaskOnly` (FakeAgent) ; `testOtherRunsRowShowsRunsOfUnknownTasks` ; `testEditButtonOpensTheFullEditor` (closure `onEdit` appelée avec la tâche).
- [ ] **Step 2: Run** `swift test --filter TaskDetail170Tests` — Expected: FAIL.
- [ ] **Step 3: Implement** : onglets Historique (rechargé à chaque sélection et à chaque `taskFinished`), Réglages (formulaire `QuickSettings`, « Enregistrer » → `model.saveTask`, « Modifier… » → `onEdit`), Journal (`runLog` de l'exécution en cours, sinon de la dernière).
- [ ] **Step 4: Run** `swift test --filter "TaskDetail170Tests|HistoryRenderTests"` — Expected: PASS.
- [ ] **Step 5: Commit** `1.7.0 : détail de la tâche sous la liste (historique, réglages essentiels, journal)`.

### Task 7: Le reste de l'app, version et notes

**Files:**
- Modify: `Sources/SyncMacProUI/Views/RootView.swift` (retirer `SidebarItem.history`)
- Modify: `Sources/SyncMacProUI/Views/MiniView.swift` (copies en cours puis les 3 prochaines en attente par rang, plus de `QueueSection`)
- Modify: `Sources/SyncMacProUI/Logic/MenuBarState.swift` (section « à venir » par rang)
- Modify: `Sources/SyncMacProUI/Views/CopyConfirmationView.swift` (« Mettre en file » → « Forcer » : `runOnce` puis `force`)
- Modify: `Sources/SyncMacProUI/Views/TasksView.swift` (retirer `QueueSection`)
- Delete: `Sources/SyncMacProUI/Views/QueueSection.swift` (garder `TaskProgressDetails` en le déplaçant dans `TaskCard.swift`)
- Modify: `VERSION` (1.7.0), `docs/release-notes.md`, `scripts/dmg-readme.txt` si la file y est décrite
- Test: `Tests/SyncMacProUITests/MiniViewTests.swift`, `MenuBarRenderTests.swift`, `RootViewTests.swift` (mis à jour), `QueueRenderTests.swift` (supprimé)

**Interfaces:**
- Consumes: Tâches 4–6.

- [ ] **Step 1: Write the failing tests** — `testSidebarHasNoGlobalHistory` ; `testMiniShowsRunningThenNextInOrder` ; `testMenuBarUpcomingFollowsTheList` ; `testCopyForceStartsTheOneOffAtOnce` (FakeAgent reçoit `runOnce` puis `force`).
- [ ] **Step 2: Run** `swift test --filter "RootViewTests|MiniViewTests|MenuBarRenderTests|CopyConfirmation"` — Expected: FAIL.
- [ ] **Step 3: Implement** ; notes de version 1.7.0 (liste unique, ordre = départ, deux copies, disque physique, forcer, pause qui libère sa place, détail en bas, historique global retiré, ctl).
- [ ] **Step 4: Run** the full suite with the bundled engines: `R=/Applications/SyncMacPro.app/Contents/Resources/bin; SYNCMACPRO_RSYNC=$R/rsync SYNCMACPRO_RCLONE=$R/rclone swift test` — Expected: `Executed N tests, with 0 failures`.
- [ ] **Step 5: Commit** `1.7.0 : historique global retiré, mode mini et barre de menus dans l'ordre de la liste, Forcer dans l'écran Copier, notes`.
