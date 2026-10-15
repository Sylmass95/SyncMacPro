# Disque amovible et corrections mineures — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sauvegardes sur disque externe déclenchées au branchement, suspendues au débranchement, reprises dans un délai, éjection au choix ; plus les 11 corrections mineures de la 1.3.0 — version 1.4.0.

**Architecture:** `SyncTask.removableDrive` décrit le disque (UUID du volume, chemin relatif, déclencheur, délai de reprise, éjection). Un `DriveMonitor` (DiskArbitration en réel, faux en test) signale les montages ; `AgentCore` lance, suspend, reprend ou clôt les exécutions liées, et résout la destination (`point de montage + chemin relatif`) au lancement. Une exécution suspendue est enregistrée dans `TaskScheduleState.suspendedRun` et reprend sous la même ligne d'historique.

**Tech Stack:** Swift 5 (CI Swift 5.10 / SDK macOS 14), DiskArbitration, `diskutil eject`, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-15-syncmacpro-disque-amovible-design.md`

## Global Constraints

- Contrat XPC version 4 inchangée : ajouts seulement, champs nouveaux facultatifs ; aucun nouveau cas dans `TaskRunState` (l'attente du disque passe par `waiting(reason:)`).
- Swift 5.10 : pas de `var` capturée dans une closure `@Sendable`/`Task` ; boucles `while true` : variables initialisées à la déclaration ; vues `@MainActor`.
- Délai de reprise par défaut 3 jours (1 à 30) ; attente après montage 5 s.
- Textes FR et EN (test `StringsCompletenessTests`).
- Tests : `SYNCMACPRO_RSYNC=/Applications/SyncMacPro.app/Contents/Resources/bin/rsync swift test`, aucun test ignoré.
- Ne jamais ouvrir une app d'essai (même identifiant que l'app installée) ni lancer `scripts/make-dev-bundle.sh` ; essais réels par un agent de banc séparé.

## Review Focus

- Disque arraché en pleine copie : rsync échoue (erreur d'entrée/sortie) avant l'avis de démontage — la tâche doit être suspendue, pas en échec ni retentée.
- Agent redémarré pendant une suspension : la suspension et sa ligne d'historique doivent survivre (ni « interrompue » ni rattrapage automatique sans disque).
- Un autre disque du même nom monté au même chemin : rien ne doit partir.
- Disque monté puis démonté avant la fin des 5 s : rien ne doit partir.
- Lancement manuel d'une tâche liée disque débranché : refus clair, pas de dossier créé sous `/Volumes`.

---

### Task 1: Corrections mineures — agent (1, 2, 10, 11)

**Files:** Modify `Sources/SyncKit/Agent/AgentCore+Queue.swift`, `AgentCore+Tasks.swift`, `AgentCore+Control.swift`, `AgentCore.swift`, `AgentTypes.swift` (erreur `notInQueue`), `Sources/syncmacpro-agent/main.swift`. Test: `Tests/SyncKitTests/Fix140AgentTests.swift`.

- [ ] Tests (rouges d'abord) :
  - `testDisablingATaskRemovesItFromTheQueue` : enqueue A ; `setEnabled(A, false)` → `queueInfo.items == []`.
  - `testDisabledTaskCannotBeQueued` : tâche désactivée → `enqueue` lève `.invalidTask`.
  - `testQueuedTaskStartedOutsideTheQueueLeavesIt` : enqueue A (file suspendue) ; `runNow(A)` → A retirée de la file.
  - `testUnknownQueueItemHasItsOwnError` : `dequeue(UUID())` lève `.notInQueue`, dont le texte est « Cette tâche n'est pas dans la file. ».
  - `testQueueWaitsForRemoteTypesBeforeStarting` : `AgentCore` avec `remotes` ; état `userQueueRunning` vrai et A en file ; `start()` ne lance rien tant que `refreshRemoteTypes()` n'a pas été appelé ; après, A part.
- [ ] Implémentation :
  - `enqueue` : `guard task.isEnabled else { throw AgentError.invalidTask("Tâche désactivée : activez-la avant de la mettre en file.") }`.
  - `setEnabled(false)` : `state.userQueue.removeAll { $0 == id }`.
  - `startJob` : `state.userQueue.removeAll { $0 == task.id }` quand le départ ne vient pas de la file (`advanceUserQueue` pose `userQueueCurrent` avant `startJob`).
  - `AgentError.notInQueue` (+ texte) pour `dequeue` / `moveInQueue`.
  - `var remoteTypesLoaded = false` ; posé par `refreshRemoteTypes` ; `advanceUserQueue` : `guard remotes == nil || remoteTypesLoaded`.
- [ ] `swift test --filter "Fix140AgentTests|AgentQueueTests|Fix130AgentReviewTests"` vert ; commit.

### Task 2: Corrections mineures — moteurs (5, 6, 7)

**Files:** `TaskRunner+Rclone.swift`, `TaskRunner.swift`, `EmptySourceGuard.swift`. Test: `Tests/SyncKitTests/Fix140RunnerTests.swift`.

- [ ] Tests :
  - `testAverageSpeedExcludesPauses` : `TaskRunner.result(...)` avec `snapshot.activeTime = 10`, `doneBytes = 100` et une durée murale de 100 s → `averageSpeed == 10`.
  - `testBackslashIsEscapedOnlyWithWildcards` : `EmptySourceGuard.rsyncEscape("a\\b.txt") == "a\\b.txt"` ; `rsyncEscape("a\\b*.txt") == "a\\\\b\\*.txt"`.
  - `testDirectoryCountDoesNotDelayTheEnd` : faux `rclone` (script) dont la simulation (`--dry-run`) dort 20 s et dont la copie finit tout de suite → `run` rend la main en moins de 5 s.
- [ ] Implémentation :
  - `averageSpeed` = `doneBytes / activeTime` si `activeTime > 0`, sinon la durée murale.
  - `rsyncEscape` : si le chemin ne contient ni `*`, ni `?`, ni `[`, il est rendu tel quel.
  - rclone : après une réussite du processus principal, `control.stopAuxiliary()` avant `await counting?.value` (le comptage interrompu laisse `directories` tel quel).
- [ ] Tests ciblés verts ; commit.

### Task 3: Corrections mineures — app (3, 4, 8, 9)

**Files:** `TaskCard.swift`, `TasksView.swift`, `AgentModel.swift` (copies terminées), `NetworkSettingsSection.swift`, `MiniPanelController.swift`. Test: `Tests/SyncMacProUITests/Fix140AppTests.swift`.

- [ ] Tests :
  - `testQueuedOneOffHasNoRunButton` : `TaskCard.availableActions(info:)` (nouvelle fonction pure qui liste les boutons) pour une copie ponctuelle `.queued` ne contient pas `.run`.
  - `testFinishedOneOffSummaryIsKeptUntilDismissed` : le modèle reçoit `taskFinished` pour une copie ponctuelle puis un état où elle n'existe plus → `model.finishedCopies` la contient ; `dismissFinishedCopy(id)` la retire.
  - `testDraftEditedOnlyByTheUser` : `NetworkSettingsSection.shouldSend(draft:model:)` faux quand le brouillon égale `BandwidthDraft(model.bandwidth)`.
  - `testClosingThePanelShowsTheMainWindow` : `MiniPanelController` se pose en `delegate` du panneau ; `windowWillClose` appelle `restoreMainWindow` (vérifié par un compteur injecté).
- [ ] Implémentation conforme aux tests (boutons calculés par `availableActions`, `finishedCopies: [UUID: AgentTaskInfo]` rempli au `taskFinished` d'une copie ponctuelle à partir de son dernier état connu, croix « Fermer » sur sa carte ; `NSWindowDelegate`).
- [ ] Tests ciblés verts ; commit.

### Task 4: Types du disque amovible

**Files:** Create `Sources/SyncKit/RemovableDrive.swift`; modify `SyncTask.swift`, `SchedulerState.swift`, `AgentTypes.swift`, `AgentProtocol.swift`, `AgentRouter.swift`. Test: `Tests/SyncKitTests/RemovableDriveTypesTests.swift`.

**Produces:**

```swift
public struct RemovableDrive: Codable, Equatable, Hashable, Sendable {
    public enum Trigger: Codable, Equatable, Hashable, Sendable { case everyConnection, atMostEveryDays(Int) }
    public enum Eject: String, Codable, Equatable, Hashable, Sendable { case never, button, automatic }
    public var volumeUUID: String
    public var volumeName: String
    /// Dossier de destination relatif à la racine du volume (« Sauvegardes/Photos »), sans « / » initial.
    public var relativePath: String
    public var trigger: Trigger
    public var resumeWindowDays: Int   // 1...30, défaut 3
    public var eject: Eject
    public func destinationPath(mountPath: String) -> String
}
public struct SuspendedRun: Codable, Equatable, Sendable { public var recordID: UUID; public var since: Date; public var summary: RunSummary }
```

`SyncTask.removableDrive: RemovableDrive?` (décodage `decodeIfPresent` dans l'`init(from:)` existant) ; `TaskScheduleState.suspendedRun: SuspendedRun?`, `lastMountHandled: Date?` ; `AgentTaskInfo.driveSuspendedSince: Date?`, `driveMounted: Bool?` ; `AgentRequest.abandonSuspended(UUID)`, `.ejectDrive(UUID)` ; `AgentError.driveNotConnected(String)`.

- [ ] Tests : aller-retour JSON de chaque type ; ancien JSON de `SyncTask` sans la clé → `removableDrive == nil` ; `destinationPath(mountPath: "/Volumes/Extreme Pro 1")` avec `relativePath` « Sauvegardes » → « /Volumes/Extreme Pro 1/Sauvegardes », chemin vide → le point de montage.
- [ ] Router : cas branchés vers des méthodes de l'agent (tâche 6) ; d'ici là `.error(.internalFailure("non pris en charge"))`.
- [ ] Tests verts ; commit.

### Task 5: Surveillance des disques

**Files:** Create `Sources/SyncKit/Agent/DriveMonitor.swift` (protocole + `VolumeLookup`), `Sources/SyncKit/Agent/System/DiskArbitrationMonitor.swift`; test fake `Tests/SyncKitTests/FakeDriveMonitor.swift`. Test: `Tests/SyncKitTests/DriveMonitorTests.swift`.

**Produces:**

```swift
public protocol DriveMonitor: Sendable {
    /// UUID de volume → point de montage, pour les volumes montés.
    func mountedVolumes() -> [String: String]
    /// Appelé à chaque montage ou démontage (file quelconque).
    func start(onChange: @escaping @Sendable () -> Void)
    /// `nil` si l'éjection a réussi, sinon le message de macOS.
    func eject(mountPath: String) async -> String?
}
public enum VolumeLookup {
    /// UUID, nom, racine, interne ou non, réseau ou non, du volume qui contient `path`.
    public static func info(forPath path: String) -> VolumeInfo?
}
public struct VolumeInfo: Equatable, Sendable { public var uuid: String?; public var name: String; public var rootPath: String; public var isInternal: Bool; public var isNetwork: Bool }
```

- [ ] Tests : `VolumeLookup.info(forPath: NSTemporaryDirectory())` → volume interne avec UUID ; image disque réelle (`hdiutil create -size 20m -fs APFS`, attachée dans le bac à sable du test) → `isInternal == false`, UUID présent, `DiskArbitrationMonitor().mountedVolumes()` contient son UUID ; après `hdiutil detach`, ne le contient plus, et `onChange` a été appelé (attente 5 s au plus).
- [ ] Réel : `DiskArbitrationMonitor` — `DASessionCreate`, `DASessionSetDispatchQueue`, `DARegisterDiskAppearedCallback` / `DARegisterDiskDisappearedCallback` / `DARegisterDiskDescriptionChangedCallback` (clé `kDADiskDescriptionVolumePathKey`) qui appellent `onChange` ; `mountedVolumes()` par `FileManager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: [.skipHiddenVolumes])` ; `eject` par `/usr/sbin/diskutil eject <mountPath>` (sortie d'erreur rendue si code ≠ 0).
- [ ] Tests verts ; commit.

### Task 6: Agent — lancer, suspendre, reprendre, abandonner

**Files:** Create `Sources/SyncKit/Agent/AgentCore+Drives.swift`; modify `AgentCore.swift` (`drives`, `startJob(resuming:)`, `finish`, `unmetCondition`, `tick`, `status`), `AgentCore+Control.swift` (`runNow` : résolution), `main.swift`. Test: `Tests/SyncKitTests/AgentDriveTests.swift`.

**Consumes:** types tâche 4, `DriveMonitor` tâche 5.
**Produces:** `AgentCore.drivesChanged()`, `abandonSuspended(_:)`, `ejectDrive(_:) async throws`.

- [ ] Tests (faux moniteur, fausse horloge, faux exécuteurs) :
  - `testPluggingTheDriveStartsTheBackupAfterFiveSeconds` (et démonté avant 5 s : rien).
  - `testEveryConnectionRunsOncePerConnection` ; `testAtMostEveryNDaysSkipsARecentBackup`.
  - `testUnpluggingSuspendsInsteadOfFailing` (démontage pendant l'exécution → état `waiting` « disque débranché », pas de `retryAt`, ligne d'historique `interrupted` avec message de pause).
  - `testEngineFailureWithTheVolumeGoneSuspends` (échec du faux exécuteur alors que le volume n'est plus monté).
  - `testReplugWithinTheWindowContinuesTheSameRun` (même `RunRecord.id`, fichiers additionnés).
  - `testReplugAfterTheWindowStartsANewRun` (ancienne ligne close, nouvelle ligne).
  - `testSuspensionSurvivesAnAgentRestart`.
  - `testAnotherDiskWithTheSameNameIsIgnored` ; `testDriveMountedElsewhereIsFound` (destination résolue = nouveau point de montage + chemin relatif).
  - `testManualRunWithoutTheDriveIsRefused` (`AgentError.driveNotConnected`).
  - `testAbandonClosesTheSuspendedRun`.
- [ ] Implémentation :
  - `drivesChanged()` : instantané `mountedVolumes()` ; pour chaque tâche liée et activée : montage nouveau → `mountSeen[uuid] = now` ; démontage → exécutions liées en cours : `job.driveLost = true`, `runner.stop()`.
  - Dans `tick()` (et `drivesChanged()`) : pour chaque tâche liée dont le volume est monté depuis 5 s et pas encore traité pour ce montage (`lastMountHandled < mountSeen`) : s'il y a `suspendedRun` et `now - since <= resumeWindowDays` jours → `startJob(task résolue, resuming: suspendedRun)` ; sinon clore la ligne suspendue (`interrupted`, message « Interrompue : disque débranché trop longtemps »), puis selon le déclencheur (`everyConnection` ou `atMostEveryDays(n)` avec `lastSuccess`) → `startJob` si conditions remplies. `lastMountHandled = now`.
  - Les tâches liées sont exclues du calcul d'échéance ordinaire (`dueDate` → `nil`).
  - `finish` : tâche liée et (`job.driveLost` ou (`status == .failed` et volume absent)) → suspension : ligne `interrupted` « En pause : disque débranché », `suspendedRun = SuspendedRun(recordID:, since: now, summary: cumul)`, pas de nouvel essai, notification « … : en pause, disque débranché ». Exécution reprise : `RunRecord` réutilisé (même `id`, `startedAt` d'origine), bilans additionnés.
  - `status()` : tâche liée suspendue → `.waiting(reason: "disque débranché depuis …")`, `driveSuspendedSince`, `driveMounted`.
  - `runNow` d'une tâche liée sans volume → `driveNotConnected(volumeName)`.
  - `main.swift` : `DiskArbitrationMonitor()`, `start { Task.detached { await core.drivesChanged() } }`, plus un second appel 6 s après chaque événement.
- [ ] Tests verts (et suites agent existantes) ; commit.

### Task 7: Éjection et notifications

**Files:** `AgentCore+Drives.swift`, `AgentCore.swift` (`notify`). Test: `AgentDriveTests.swift` (ajouts).

- [ ] Tests : `testAutomaticEjectAfterSuccess` (faux moniteur reçoit `eject` du bon point de montage) ; `testNoEjectWhileAnotherRunUsesTheDrive` ; `testEjectRequestReportsRefusal` (`ejectDrive` lève avec le message du moniteur) ; `testEndNotificationSaysYouCanEject`.
- [ ] Implémentation : après une réussite d'une tâche liée : `eject == .automatic` et aucune autre exécution sur ce volume → `await drives.eject(...)` (message d'échec en notification) ; sinon notification « … : terminée — vous pouvez éjecter <nom> ». `ejectDrive(id)` pour le bouton.
- [ ] Tests verts ; commit.

### Task 8: `ctl` (eject, abandon, status)

**Files:** `CtlParser.swift`, `syncmacpro-ctl/main.swift`, `CtlSupport.swift` (`statusLines` : « disque débranché depuis … »), README. Test: `Tests/SyncKitTests/CtlDriveTests.swift`.

- [ ] Tests : `eject <tâche>` → `.eject`, `abandon <tâche>` → `.abandon` ; ligne de statut d'une tâche suspendue.
- [ ] Implémentation, tests verts, commit.

### Task 9: App — éditeur et écrans

**Files:** `TaskDraft.swift` (`RemovableDraft`), `EditorSteps.swift` (section Disque amovible), `TaskCard.swift` / `MiniView.swift` / `MenuBarViews.swift` (pause, Abandonner, Éjecter), `AgentModel.swift` (`abandonSuspended`, `ejectDrive`), `Localizable.strings`. Tests: `Tests/SyncMacProUITests/RemovableDriveUITests.swift`.

- [ ] Tests : `RemovableDraft` depuis un `VolumeInfo` externe (nom, UUID, chemin relatif) et retour vers `RemovableDrive` ; volume interne ou réseau → section absente ; `TaskCard.availableActions` d'une tâche suspendue → `.abandon` ; tâche au repos, éjection `button`, disque branché → `.eject` ; rendu de la carte suspendue et de la section de l'éditeur ; textes FR/EN.
- [ ] Implémentation, tests verts, commit.

### Task 10: Version 1.4.0, essais réels

- [ ] Suite complète verte ; `VERSION` 1.4.0 ; notes de version ; README (disque amovible, `ctl eject`, `ctl abandon`).
- [ ] Essai réel (agent de banc, app d'essai jamais ouverte) : image disque APFS « BancUSB » de 1 Go ; tâche liée (copie de 300 Mo, plafond local pour la ralentir) ; montage → départ après 5 s ; `hdiutil detach -force` en route → suspension ; montage → même exécution, fichiers identiques (`cmp`) ; suspension « vieille » simulée en reculant `since` dans `scheduler-state.json` (agent arrêté) → nouvelle exécution ; éjection automatique → volume démonté. Nettoyer le banc ; vérifier l'agent installé.
- [ ] Commit.
