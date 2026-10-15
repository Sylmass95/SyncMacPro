# File d'attente, progression, miniature, débit — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Une file d'attente explicite dans l'agent, une progression façon RsyncGUI (fichiers, dossiers, vitesse moyenne, temps écoulé, bilan), un mode miniature, des plafonds de débit en Mbit/s modifiables à chaud, un compteur d'erreurs juste et un garde-fou contre les fichiers vides — version 1.3.0.

**Architecture:** Tout l'état (file, plafonds) vit dans `AgentCore` et passe par le contrat XPC 4 (ajouts seulement). `BandwidthPlanner` (pur) répartit les plafonds ; chaque `TaskRunner` reçoit sa limite par `setBandwidth` : rclone via sa prise de contrôle Unix (`rclone rc core/bwlimit`), rsync par relance. L'app ajoute la présentation (`ProgressPresentation`), les sections File d'attente, Réglages › Réseau et un `NSPanel` miniature.

**Tech Stack:** Swift 5 (SwiftPM, CI Swift 5.10 / SDK macOS 14), SwiftUI + AppKit, XCTest, rsync 3.5.1 et rclone 1.75.1 embarqués.

**Spec:** `docs/superpowers/specs/2026-10-15-syncmacpro-file-progression-miniature-debit-design.md`

## Global Constraints

- macOS 14, Swift 5 mode ; CI Swift 5.10 : vues SwiftUI `@MainActor`, pas de `var` ni de `weak self` capturés dans une closure `@Sendable`/`Task`, pas d'initialiseur `@MainActor` appelé depuis un contexte non isolé.
- Contrat XPC **version 4 inchangée** : nouvelles requêtes et nouveaux champs seulement, champs nouveaux **facultatifs** (un ancien JSON se décode).
- 1 Mbit/s = 1 000 000 bit/s = 125 000 octets/s.
- Textes de l'interface en français et en anglais (`fr.lproj`, `en.lproj`), le test `StringsCompletenessTests` doit passer.
- Une tâche manuelle (`Schedule.manual`) n'affiche jamais de ligne « Prochaine ».
- Tests : `SYNCMACPRO_RSYNC=/Applications/SyncMacPro.app/Contents/Resources/bin/rsync swift test` (aucun test ignoré).
- Commentaires et messages en français, dans le style du code existant.
- Ne jamais lancer `scripts/make-dev-bundle.sh` sur un bundle existant (il désenregistre l'agent installé) : pour un essai réel, `swift build -c release` + `scripts/assemble-app.sh`.

## Review Focus

- Un élément de la file qui échoue ou est arrêté : la file doit passer au suivant, pas se bloquer.
- Un plafond modifié pendant un miroir rsync : la relance ne doit ni refaire le garde-fou ni supprimer quoi que ce soit en plus.
- Une file sauvegardée qui cite une tâche supprimée entre-temps : l'élément est sauté au chargement, sans erreur.
- Un fichier vide à la source alors que la destination n'a pas ce fichier : il doit être copié (seul l'écrasement d'un fichier non vide est empêché).
- Un ancien `scheduler-state.json`, `RunSummary` ou `AgentStatus` (sans les champs nouveaux) : il doit se lire sans perte.

---

### Task 1: Types partagés (contrat XPC 4, ajouts)

**Files:**
- Modify: `Sources/SyncKit/Agent/AgentTypes.swift` (ProgressInfo, AgentTaskInfo, AgentStatus)
- Modify: `Sources/SyncKit/RunRecord.swift` (RunSummary)
- Modify: `Sources/SyncKit/Agent/AgentProtocol.swift` (requêtes)
- Create: `Sources/SyncKit/Bandwidth.swift`
- Test: `Tests/SyncKitTests/SubProject6TypesTests.swift`

**Interfaces:**
- Produces:
  - `public struct BandwidthLimits: Codable, Equatable, Sendable { var downloadMbps: Double?; var uploadMbps: Double?; var localMbps: Double? }`
  - `public struct BandwidthRate: Equatable, Sendable { var upBytesPerSecond: Int64?; var downBytesPerSecond: Int64? }` + `static func bytesPerSecond(mbps: Double) -> Int64`
  - `public struct QueueInfo: Codable, Equatable, Sendable { var running: Bool; var items: [UUID]; var current: UUID? }`
  - `ProgressInfo.dirsDone: Int?`, `.totalDirs: Int?`, `.averageSpeed: Double?`
  - `RunSummary.directories: Int?`, `.averageSpeed: Double?`
  - `AgentTaskInfo.queuePosition: Int?` ; `AgentStatus.queue: QueueInfo?`, `.bandwidth: BandwidthLimits?`
  - `AgentRequest`: `.enqueue(UUID)`, `.enqueueOnce(SyncTask)`, `.dequeue(UUID)`, `.moveInQueue(UUID, to: Int)`, `.setQueueRunning(Bool)`, `.setBandwidth(BandwidthLimits)`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SyncKit

final class SubProject6TypesTests: XCTestCase {
    func testMbpsAreSpeedtestMegabits() {
        XCTAssertEqual(BandwidthRate.bytesPerSecond(mbps: 100), 12_500_000)
        XCTAssertEqual(BandwidthRate.bytesPerSecond(mbps: 0.5), 62_500)
    }

    // Un agent 1.2.x envoie des JSON sans les champs nouveaux : ils se lisent, les champs restent vides.
    func testOldJSONStillDecodes() throws {
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data(
            #"{"filesTransferred":1,"bytesTransferred":2,"deletions":0,"errors":0,"durationSeconds":3}"#.utf8))
        XCTAssertNil(summary.directories)
        XCTAssertNil(summary.averageSpeed)
        let status = try JSONDecoder().decode(AgentStatus.self, from: Data(
            #"{"globalPause":false,"stateRecovered":false,"tasks":[]}"#.utf8))
        XCTAssertNil(status.queue)
        XCTAssertNil(status.bandwidth)
        var progress = ProgressInfo(TransferSnapshot())
        progress.dirsDone = nil
        let encoded = try JSONEncoder().encode(progress)
        XCTAssertEqual(try JSONDecoder().decode(ProgressInfo.self, from: encoded), progress)
    }

    func testProgressCarriesDirectoriesAndAverageSpeed() {
        var snapshot = TransferSnapshot()
        snapshot.dirsDone = 3
        snapshot.totalDirs = 9
        snapshot.averageSpeed = 25_000_000
        let info = ProgressInfo(snapshot)
        XCTAssertEqual(info.dirsDone, 3)
        XCTAssertEqual(info.totalDirs, 9)
        XCTAssertEqual(info.averageSpeed, 25_000_000)
    }

    func testNewRequestsRoundTrip() throws {
        let id = UUID()
        for request in [AgentRequest.enqueue(id), .dequeue(id), .moveInQueue(id, to: 2), .setQueueRunning(true),
                        .setBandwidth(BandwidthLimits(downloadMbps: 200, uploadMbps: 50, localMbps: nil))] {
            let data = try JSONEncoder().encode(AgentRequestEnvelope(request: request))
            XCTAssertEqual(try JSONDecoder().decode(AgentRequestEnvelope.self, from: data).request, request)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SubProject6TypesTests`
Expected: FAIL (compilation : `BandwidthRate`, `dirsDone`, `.enqueue` inconnus)

- [ ] **Step 3: Write minimal implementation**

`Sources/SyncKit/Bandwidth.swift` :

```swift
import Foundation

/// Plafonds de débit des réglages, en Mbit/s (l'unité de speedtest : 1 Mbit/s = 1 000 000 bit/s). `nil` : pas de plafond.
public struct BandwidthLimits: Codable, Equatable, Sendable {
    /// Réception depuis internet (source sur un service en ligne).
    public var downloadMbps: Double?
    /// Envoi vers internet (destination sur un service en ligne).
    public var uploadMbps: Double?
    /// Copies entre disques et NAS du réseau local.
    public var localMbps: Double?

    public init(downloadMbps: Double? = nil, uploadMbps: Double? = nil, localMbps: Double? = nil) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.localMbps = localMbps
    }
}

/// Limite appliquée à une exécution, en octets par seconde ; `nil` d'un côté : sans limite.
public struct BandwidthRate: Equatable, Sendable {
    public var upBytesPerSecond: Int64?
    public var downBytesPerSecond: Int64?

    public init(upBytesPerSecond: Int64? = nil, downBytesPerSecond: Int64? = nil) {
        self.upBytesPerSecond = upBytesPerSecond
        self.downBytesPerSecond = downBytesPerSecond
    }

    public static let unlimited = BandwidthRate()

    public static func bytesPerSecond(mbps: Double) -> Int64 { Int64((mbps * 1_000_000 / 8).rounded()) }
}

/// La file d'attente explicite, vue par l'app.
public struct QueueInfo: Codable, Equatable, Sendable {
    public var running: Bool
    public var items: [UUID]
    /// L'élément de la file qui s'exécute.
    public var current: UUID?

    public init(running: Bool, items: [UUID], current: UUID?) {
        self.running = running
        self.items = items
        self.current = current
    }
}
```

`ProgressInfo` (AgentTypes.swift) : ajouter `public var dirsDone: Int?`, `public var totalDirs: Int?`, `public var averageSpeed: Double?`, et dans `init(_ snapshot:)` : `dirsDone = snapshot.dirsDone; totalDirs = snapshot.totalDirs; averageSpeed = snapshot.averageSpeed > 0 ? snapshot.averageSpeed : nil`.
`AgentTaskInfo` : `public var queuePosition: Int?` (paramètre d'init `queuePosition: Int? = nil`).
`AgentStatus` : `public var queue: QueueInfo?`, `public var bandwidth: BandwidthLimits?` (paramètres d'init avec `= nil`).
`RunSummary` (RunRecord.swift) : `public var directories: Int?`, `public var averageSpeed: Double?` (init `= nil`).
`AgentRequest` : ajouter après `clearHistory` :

```swift
    // File d'attente explicite et plafonds de débit (1.3.0 : ajouts, aucun message existant ne change)
    case enqueue(UUID)
    case enqueueOnce(SyncTask)
    case dequeue(UUID)
    case moveInQueue(UUID, to: Int)
    case setQueueRunning(Bool)
    case setBandwidth(BandwidthLimits)
```

Dans `AgentRouter`, ajouter temporairement les cas qui renvoient `.error(.internalFailure("non pris en charge"))` (remplacés aux tâches 3 et 4) pour que le `switch` reste exhaustif.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SubProject6TypesTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncKit Tests/SyncKitTests/SubProject6TypesTests.swift
git commit -m "Types du sous-projet 6 : plafonds, file, dossiers et vitesse moyenne (champs facultatifs, contrat 4)"
```

### Task 2: Compteur d'erreurs juste

**Files:**
- Modify: `Sources/SyncKit/RunnerTypes.swift` (`RunLog.addError`)
- Modify: `Sources/SyncKit/EngineErrorText.swift` (`isConsequence`)
- Modify: `Sources/SyncKit/TaskRunner+Rclone.swift` (`errors:` du résultat)
- Test: `Tests/SyncKitTests/SubProject6ErrorCountTests.swift`

**Interfaces:**
- Produces: `RunLog.errors` = nombre de messages d'erreur distincts hors lignes de résumé.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SyncKit

final class SubProject6ErrorCountTests: XCTestCase {
    // Journal réel de COMMONS 01 (15/10) : un seul incident, rapporté trois fois.
    func testOneRcloneIncidentCountsOnce() {
        let log = RunLog()
        log.addError("partial file rename failed: rename A.partial A: file busy")
        log.addError("Attempt 1/3 failed with 1 errors and: rename A.partial A: file busy")
        log.addError("partial file rename failed: rename A.partial A: file busy")
        XCTAssertEqual(log.errors, 1)
        XCTAssertEqual(log.mainError?.contains("partial file rename failed"), true, log.mainError ?? "")
    }

    func testDistinctErrorsAreAllCounted() {
        let log = RunLog()
        log.addError("rsync: send_files failed to open \"/a\": Permission denied (13)")
        log.addError("rsync: send_files failed to open \"/b\": Permission denied (13)")
        log.addError("Failed to copy with 2 errors: last error was: x")
        XCTAssertEqual(log.errors, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SubProject6ErrorCountTests`
Expected: FAIL (`3 ≠ 1`, `3 ≠ 2`)

- [ ] **Step 3: Write minimal implementation**

`EngineErrorText.isConsequence` : ajouter `|| lower.hasPrefix("attempt ") && lower.contains(" failed with ") || lower.hasPrefix("failed to ") && lower.contains(" with ") && lower.contains(" error")`.
`RunLog` : remplacer `errorCount` par un ensemble :

```swift
    private var distinctErrors: Set<String> = []

    func addError(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if firstErrors.count < 20 { firstErrors.append(line) }
        // Une ligne de résumé (« Attempt 1/3 failed… ») rappelle une erreur déjà vue : elle ne compte pas.
        if !EngineErrorText.isConsequence(line) || line.lowercased().hasPrefix("rsync error:") { distinctErrors.insert(line) }
    }

    var errors: Int { lock.lock(); defer { lock.unlock() }; return distinctErrors.count }
```

`EngineErrorText.summary(errors:total:)` reste appelé avec `total: distinctErrors.count`.
`TaskRunner+Rclone.swift`, fin de `runRclone` : remplacer `errors: max(log.errors, stats?.errors ?? 0)` par `errors: log.errors > 0 ? log.errors : (stats?.errors ?? 0)` (les statistiques de rclone recomptent chaque tentative).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "SubProject6ErrorCountTests|Fix122ErrorTextTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncKit Tests/SyncKitTests/SubProject6ErrorCountTests.swift
git commit -m "Compteur d'erreurs : un incident rclone n'est plus compté à chaque tentative"
```

### Task 3: File d'attente dans l'agent

**Files:**
- Modify: `Sources/SyncKit/Agent/SchedulerState.swift` (`userQueue`, `userQueueRunning`)
- Create: `Sources/SyncKit/Agent/AgentCore+Queue.swift`
- Modify: `Sources/SyncKit/Agent/AgentCore.swift` (`Job.fromUserQueue`, `finish`, `status`, `loadTasks`)
- Modify: `Sources/SyncKit/Agent/AgentRouter.swift`
- Test: `Tests/SyncKitTests/AgentQueueTests.swift`

**Interfaces:**
- Consumes: `QueueInfo`, `AgentRequest.enqueue…` (tâche 1)
- Produces: `AgentCore.enqueue(_ id: UUID) throws`, `enqueueOnce(_ task: SyncTask) throws`, `dequeue(_ id: UUID) throws`, `moveInQueue(_ id: UUID, to index: Int) throws`, `setQueueRunning(_ running: Bool)`, `var queueInfo: QueueInfo`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SyncKit

final class AgentQueueTests: XCTestCase {
    private func ran(_ h: AgentHarness) -> [String] {
        h.factory.runners.get().flatMap { $0.ranTasks.get().map(\.name) }
    }

    func testQueueRunsOneAtATimeInOrderAndSurvivesAFailure() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let a = makeTask("A", schedule: .manual), b = makeTask("B", schedule: .manual), c = makeTask("C", schedule: .manual)
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        for task in [a, b, c] { try await core.enqueue(task.id) }
        try await core.moveInQueue(c.id, to: 0)          // C passe devant
        XCTAssertEqual(h.factory.created, 0, "la file ne part qu'avec « Lancer la file »")
        await core.setQueueRunning(true)
        XCTAssertEqual(h.factory.created, 1, "un seul élément à la fois")
        h.factory.status.set(.failed)
        h.factory.runners.get()[0].release()             // C échoue
        let second = await eventually { h.factory.created == 2 }
        XCTAssertTrue(second, "un échec n'arrête pas la file")
        h.factory.status.set(.succeeded)
        h.factory.runners.get()[1].release()
        _ = await eventually { h.factory.created == 3 }
        h.factory.runners.get()[2].release()
        await core.waitForIdle()
        XCTAssertEqual(ran(h), ["C", "A", "B"])
        let info = await core.queueInfo
        XCTAssertEqual(info.items, [])
        XCTAssertFalse(info.running, "vide, la file s'arrête")
    }

    func testSuspendLetsTheCurrentItemFinishAndStartsNothingElse() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let a = makeTask("A", schedule: .manual), b = makeTask("B", schedule: .manual)
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        try await core.enqueue(b.id)
        await core.setQueueRunning(true)
        await core.setQueueRunning(false)
        h.factory.runners.get()[0].release()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.created, 1)
        let items = await core.queueInfo.items
        XCTAssertEqual(items, [b.id])
    }

    func testQueueIsSavedAndRemovedTasksAreSkipped() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = makeTask("A", schedule: .manual), b = makeTask("B", schedule: .manual)
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        try await core.enqueue(b.id)
        try h.save([b])                                  // A supprimée hors de l'agent
        let again = h.makeCore()
        await again.start()
        let items = await again.queueInfo.items
        XCTAssertEqual(items, [b.id])
    }

    func testRunningOrQueuedTasksCannotBeAddedTwice() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = makeTask("A", schedule: .manual)
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        do { try await core.enqueue(a.id); XCTFail("déjà en file") } catch {
            XCTAssertEqual(error as? AgentError, .alreadyRunning)
        }
    }

    func testOneOffCopiesCanBeQueuedButAreNotSaved() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        var copy = makeTask("Copie de 2 élément(s)", schedule: .manual)
        copy.id = UUID()
        try await core.enqueueOnce(copy)
        let items = await core.queueInfo.items
        XCTAssertEqual(items, [copy.id])
        let again = h.makeCore()
        await again.start()
        let after = await again.queueInfo.items
        XCTAssertEqual(after, [])
    }

    func testStatusShowsQueuePositions() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = makeTask("A", schedule: .manual), b = makeTask("B", schedule: .manual)
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(b.id)
        try await core.enqueue(a.id)
        let status = await core.status()
        XCTAssertEqual(status.queue?.items, [b.id, a.id])
        XCTAssertEqual(status.tasks.first { $0.id == a.id }?.queuePosition, 2)
        XCTAssertEqual(status.tasks.first { $0.id == b.id }?.queuePosition, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentQueueTests`
Expected: FAIL (compilation : `enqueue`, `queueInfo` inconnus)

- [ ] **Step 3: Write minimal implementation**

`SchedulerState` : `public var userQueue: [UUID] = []`, `public var userQueueRunning: Bool = false` et un `init(from:)` qui lit ces deux clés avec `decodeIfPresent` (les autres comme aujourd'hui). Écrire le décodage explicite :

```swift
    private enum CodingKeys: String, CodingKey { case paused, lastPurge, tasks, userQueue, userQueueRunning }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        lastPurge = try c.decodeIfPresent(Date.self, forKey: .lastPurge)
        tasks = try c.decodeIfPresent([String: TaskScheduleState].self, forKey: .tasks) ?? [:]
        userQueue = try c.decodeIfPresent([UUID].self, forKey: .userQueue) ?? []
        userQueueRunning = try c.decodeIfPresent(Bool.self, forKey: .userQueueRunning) ?? false
    }
```

`AgentCore` : propriétés `var queuedOneOffs: [UUID: SyncTask] = [:]` (copies ponctuelles en file, jamais enregistrées) et `var userQueueCurrent: UUID?`. `Job` gagne `var fromUserQueue = false`.

`Sources/SyncKit/Agent/AgentCore+Queue.swift` :

```swift
import Foundation

/// File d'attente explicite : des tâches lancées une par une, dans l'ordre choisi, après « Lancer la file ».
extension AgentCore {
    public var queueInfo: QueueInfo {
        QueueInfo(running: state.userQueueRunning, items: state.userQueue, current: userQueueCurrent)
    }

    public func enqueue(_ id: UUID) throws {
        guard tasks.contains(where: { $0.id == id }) else { throw AgentError.unknownTask }
        try ensureNotBusy(id)
        state.userQueue.append(id)
        persist()
        emit(.stateChanged)
        advanceUserQueue()
    }

    /// Copie ponctuelle mise en file depuis l'écran Copie : gardée en mémoire seulement.
    public func enqueueOnce(_ task: SyncTask) throws {
        do { try TaskValidator.validate(task) } catch { throw AgentError.invalidTask("\(error)") }
        try ensureNotBusy(task.id)
        queuedOneOffs[task.id] = task
        state.userQueue.append(task.id)
        persist()
        emit(.stateChanged)
        advanceUserQueue()
    }

    public func dequeue(_ id: UUID) throws {
        guard let index = state.userQueue.firstIndex(of: id) else { throw AgentError.notRunning }
        state.userQueue.remove(at: index)
        queuedOneOffs[id] = nil
        persist()
        emit(.stateChanged)
    }

    public func moveInQueue(_ id: UUID, to index: Int) throws {
        guard let from = state.userQueue.firstIndex(of: id) else { throw AgentError.notRunning }
        state.userQueue.remove(at: from)
        state.userQueue.insert(id, at: max(0, min(index, state.userQueue.count)))
        persist()
        emit(.stateChanged)
    }

    public func setQueueRunning(_ running: Bool) {
        state.userQueueRunning = running && !state.userQueue.isEmpty
        persist()
        emit(.stateChanged)
        advanceUserQueue()
    }

    private func ensureNotBusy(_ id: UUID) throws {
        guard jobs[id] == nil, !queue.contains(where: { $0.id == id }), !state.userQueue.contains(id) else {
            throw AgentError.alreadyRunning
        }
    }

    /// Démarre le premier élément si la file tourne, qu'aucun de ses éléments ne s'exécute et qu'il reste de la place.
    func advanceUserQueue() {
        guard state.userQueueRunning, !state.paused, !shuttingDown, userQueueCurrent == nil else { return }
        // Éléments devenus impossibles (tâche supprimée ou désactivée) : sautés.
        while let first = state.userQueue.first,
              !(queuedOneOffs[first] != nil || tasks.contains { $0.id == first && $0.isEnabled }) {
            state.userQueue.removeFirst()
        }
        guard let next = state.userQueue.first else {
            state.userQueueRunning = false
            persist()
            emit(.stateChanged)
            return
        }
        guard jobs.count < configuration.maxParallel, jobs[next] == nil else { return }
        state.userQueue.removeFirst()
        userQueueCurrent = next
        persist()
        if let copy = queuedOneOffs.removeValue(forKey: next) { oneOffs[next] = copy }
        guard let task = lookupTask(next) else { userQueueCurrent = nil; advanceUserQueue(); return }
        startJob(task, overrideGuard: false)
        jobs[next]?.fromUserQueue = true
        emit(.stateChanged)
    }
}
```

`AgentCore.finish(_:_:)` : après `startQueued()` ajouter :

```swift
        if userQueueCurrent == id { userQueueCurrent = nil }
        advanceUserQueue()
```

`AgentCore.loadTasks()` : après le filtrage de `state.tasks`, retirer de `state.userQueue` les identifiants qui ne sont ni des tâches connues ni des copies en mémoire : `state.userQueue = state.userQueue.filter { id in known.contains(id.uuidString) || queuedOneOffs[id] != nil }`.
`AgentCore.start()` : `state.userQueueRunning = state.userQueueRunning && !state.userQueue.isEmpty` puis, après `persist()`, `advanceUserQueue()`.
`AgentCore.shutdown()` : avant `queue.removeAll()`, inscrire `interrupted` dans l'historique pour chaque `queuedOneOffs` (même texte que les copies ponctuelles) et vider `queuedOneOffs`, retirer ces identifiants de `state.userQueue`, `persist()`.
`AgentCore.status()` : `queuePosition: state.userQueue.firstIndex(of: task.id).map { $0 + 1 }` dans `AgentTaskInfo`, ajouter les copies de `queuedOneOffs` à la liste comme les `oneOffs` (état `.queued`), et `AgentStatus(..., queue: queueInfo, bandwidth: settingsLimits)` (`settingsLimits` vient de la tâche 4 ; d'ici là `nil`).
`AgentCore.removeTask` : retirer l'identifiant de `state.userQueue`.
`AgentRouter` : brancher `.enqueue`, `.enqueueOnce`, `.dequeue`, `.moveInQueue`, `.setQueueRunning` sur ces méthodes (réponse `.ok`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "AgentQueueTests|AgentCoreTests|AgentControlTests|AgentOneOffTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncKit Tests/SyncKitTests/AgentQueueTests.swift
git commit -m "File d'attente explicite dans l'agent : un élément à la fois, réordonnable, enregistrée"
```

### Task 4: Plafonds de débit — réglages, répartition, application

**Files:**
- Create: `Sources/SyncKit/Agent/AgentSettings.swift` (store `settings.json`)
- Create: `Sources/SyncKit/BandwidthPlanner.swift`
- Modify: `Sources/SyncKit/Agent/TaskRunning.swift` (`setBandwidth`)
- Modify: `Sources/SyncKit/Agent/AgentCore.swift` (`settingsStore`, `remoteTypes`, `applyBandwidth()`)
- Modify: `Sources/SyncKit/Agent/AgentPaths.swift` (`settings`)
- Modify: `Sources/syncmacpro-agent/main.swift`
- Modify: `Tests/SyncKitTests/AgentTestSupport.swift` (FakeRunner enregistre les limites)
- Test: `Tests/SyncKitTests/BandwidthTests.swift`

**Interfaces:**
- Consumes: `BandwidthLimits`, `BandwidthRate` (tâche 1)
- Produces:
  - `public enum BandwidthDirection: Equatable { case download, upload, both, local }`
  - `BandwidthPlanner.direction(of task: SyncTask, remoteTypes: [String: String]) -> BandwidthDirection`
  - `BandwidthPlanner.rates(for running: [(id: UUID, task: SyncTask)], limits: BandwidthLimits, remoteTypes: [String: String]) -> [UUID: BandwidthRate]`
  - `TaskRunning.setBandwidth(_ rate: BandwidthRate)`
  - `AgentCore.setBandwidth(_ limits: BandwidthLimits)` ; `AgentCore(… settingsStore: AgentSettingsStore? = nil …)`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SyncKit

final class BandwidthTests: XCTestCase {
    let types = ["Google Drive": "drive", "nas": "smb", "S3": "s3"]

    func task(_ source: Endpoint, _ destination: Endpoint, limitKBps: Int? = nil) -> SyncTask {
        var t = SyncTask(name: "t", source: source, destination: destination)
        t.options.bandwidthLimitKBps = limitKBps
        return t
    }

    func testDirectionFollowsWhereInternetIs() {
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.cloud(remote: "Google Drive", path: "a"), .cloud(remote: "nas", path: "b")), remoteTypes: types), .download)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.cloud(remote: "nas", path: "a"), .cloud(remote: "Google Drive", path: "b")), remoteTypes: types), .upload)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.local(path: "/a"), .cloud(remote: "nas", path: "b")), remoteTypes: types), .local)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.local(path: "/a"), .local(path: "/b")), remoteTypes: types), .local)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.cloud(remote: "S3", path: "a"), .cloud(remote: "Google Drive", path: "b")), remoteTypes: types), .both)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.cloud(remote: "inconnue", path: "a"), .local(path: "/b")), remoteTypes: types), .download,
                       "type inconnu : on suppose internet (le plafond protège la connexion)")
    }

    func testSameDirectionSharesTheCapAndTaskLimitWinsWhenLower() {
        let limits = BandwidthLimits(downloadMbps: 100, uploadMbps: 40, localMbps: nil)
        let a = UUID(), b = UUID(), c = UUID()
        let drive = Endpoint.cloud(remote: "Google Drive", path: "x"), nas = Endpoint.cloud(remote: "nas", path: "y")
        let rates = BandwidthPlanner.rates(for: [
            (a, task(drive, nas)), (b, task(drive, nas, limitKBps: 1000)), (c, task(.local(path: "/a"), .local(path: "/b"))),
        ], limits: limits, remoteTypes: types)
        XCTAssertEqual(rates[a]?.downBytesPerSecond, 6_250_000, "100 Mbit/s partagés par deux")
        XCTAssertEqual(rates[b]?.downBytesPerSecond, 1_024_000, "la limite de la tâche (1000 Ko/s) est plus basse")
        XCTAssertNil(rates[a]?.upBytesPerSecond)
        XCTAssertEqual(rates[c], .unlimited, "pas de plafond local")
    }

    func testAgentAppliesRatesAtStartAndWhenSettingsChange() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let copy = SyncTask(name: "Drive → NAS", source: .cloud(remote: "Google Drive", path: "a"),
                            destination: .cloud(remote: "nas", path: "b"), schedule: .manual)
        try h.save([copy])
        let remotes = FakeRemotes()
        remotes.remotes.set([RemoteInfo(name: "Google Drive", type: "drive"), RemoteInfo(name: "nas", type: "smb")])
        let settings = AgentSettingsStore(url: h.directory.appendingPathComponent("settings.json"))
        let core = h.makeCore(remotes: remotes, settings: settings)
        await core.start()
        await core.setBandwidth(BandwidthLimits(downloadMbps: 80))
        try await core.runNow(copy.id)
        let runner = h.factory.runners.get()[0]
        XCTAssertEqual(runner.rates.get().last?.downBytesPerSecond, 10_000_000)
        await core.setBandwidth(BandwidthLimits(downloadMbps: 160))
        XCTAssertEqual(runner.rates.get().last?.downBytesPerSecond, 20_000_000, "changement appliqué à chaud")
        XCTAssertEqual(settings.load().downloadMbps, 160, "enregistré")
        runner.release()
        await core.waitForIdle()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BandwidthTests`
Expected: FAIL (compilation)

- [ ] **Step 3: Write minimal implementation**

`Sources/SyncKit/BandwidthPlanner.swift` :

```swift
import Foundation

public enum BandwidthDirection: Equatable, Sendable { case download, upload, both, local }

/// Répartit les plafonds des réglages entre les exécutions en cours.
public enum BandwidthPlanner {
    /// Types de connexion rclone du réseau local : tout le reste passe par internet.
    static let localTypes: Set<String> = ["smb", "local", "alias"]

    static func isInternet(_ endpoint: Endpoint, _ remoteTypes: [String: String]) -> Bool {
        guard case .cloud(let remote, _) = endpoint else { return false }
        guard let type = remoteTypes[remote] else { return true }
        return !localTypes.contains(type)
    }

    public static func direction(of task: SyncTask, remoteTypes: [String: String]) -> BandwidthDirection {
        switch (isInternet(task.source, remoteTypes), isInternet(task.destination, remoteTypes)) {
        case (true, true): return .both
        case (true, false): return .download
        case (false, true): return .upload
        case (false, false): return .local
        }
    }

    public static func rates(
        for running: [(id: UUID, task: SyncTask)], limits: BandwidthLimits, remoteTypes: [String: String]
    ) -> [UUID: BandwidthRate] {
        let directions = running.map { ($0.id, $0.task, direction(of: $0.task, remoteTypes: remoteTypes)) }
        func share(_ mbps: Double?, among count: Int) -> Int64? {
            guard let mbps, mbps > 0, count > 0 else { return nil }
            return BandwidthRate.bytesPerSecond(mbps: mbps) / Int64(count)
        }
        let downloaders = directions.filter { $0.2 == .download || $0.2 == .both }.count
        let uploaders = directions.filter { $0.2 == .upload || $0.2 == .both }.count
        let locals = directions.filter { $0.2 == .local }.count
        var result: [UUID: BandwidthRate] = [:]
        for (id, task, direction) in directions {
            var rate = BandwidthRate.unlimited
            switch direction {
            case .download: rate.downBytesPerSecond = share(limits.downloadMbps, among: downloaders)
            case .upload: rate.upBytesPerSecond = share(limits.uploadMbps, among: uploaders)
            case .both:
                rate.downBytesPerSecond = share(limits.downloadMbps, among: downloaders)
                rate.upBytesPerSecond = share(limits.uploadMbps, among: uploaders)
            case .local:
                let cap = share(limits.localMbps, among: locals)
                rate = BandwidthRate(upBytesPerSecond: cap, downBytesPerSecond: cap)
            }
            // Le plafond propre à la tâche (Ko/s, 1 Ko = 1 024 octets) reste appliqué s'il est plus bas.
            if let kbps = task.options.bandwidthLimitKBps, kbps > 0 {
                let own = Int64(kbps) * 1024
                rate.upBytesPerSecond = min(rate.upBytesPerSecond ?? own, own)
                rate.downBytesPerSecond = min(rate.downBytesPerSecond ?? own, own)
            }
            result[id] = rate
        }
        return result
    }
}
```

Note : avec un plafond propre à la tâche et un sens unique, les deux côtés reçoivent `own` (comme `--bwlimit` aujourd'hui) ; le test vérifie `downBytesPerSecond`.

`Sources/SyncKit/Agent/AgentSettings.swift` :

```swift
import Foundation

/// Réglages tenus par l'agent (`settings.json`) : aujourd'hui les plafonds de débit.
public struct AgentSettingsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    /// Fichier absent ou illisible : aucun plafond (on ne bride jamais par surprise).
    public func load() -> BandwidthLimits {
        guard let data = try? Data(contentsOf: url) else { return BandwidthLimits() }
        return (try? JSONDecoder().decode(BandwidthLimits.self, from: data)) ?? BandwidthLimits()
    }

    public func save(_ limits: BandwidthLimits) throws {
        try JSONEncoder().encode(limits).write(to: url, options: .atomic)
    }
}
```

`TaskRunning` : ajouter `func setBandwidth(_ rate: BandwidthRate)`. `TaskRunner` : `public func setBandwidth(_ rate: BandwidthRate) { control.setBandwidth(rate) }` (tâches 5 et 6 l'appliquent ; ici `RunControl` le garde seulement : `private var bandwidthValue = BandwidthRate.unlimited`, `var bandwidth: BandwidthRate { … }`, `func setBandwidth(_:)` qui l'enregistre puis appelle un `bandwidthHook` facultatif hors verrou).
`FakeRunner` : `let rates = Locked<[BandwidthRate]>([])` ; `func setBandwidth(_ rate: BandwidthRate) { rates.update { $0.append(rate) } }`.
`AgentHarness.makeCore` : paramètre `settings: AgentSettingsStore? = nil` passé à `AgentCore`.
`AgentCore` : `let settingsStore: AgentSettingsStore?`, `var settingsLimits = BandwidthLimits()`, `var remoteTypes: [String: String] = [:]`. Dans `start()` : `settingsLimits = settingsStore?.load() ?? BandwidthLimits()`. Méthodes :

```swift
    public func setBandwidth(_ limits: BandwidthLimits) {
        settingsLimits = limits
        do { try settingsStore?.save(limits) } catch { log("réglages non enregistrés : \(error)") }
        applyBandwidth()
        emit(.stateChanged)
    }

    /// Recalcule la part de chaque exécution et la transmet (départ, fin, réglage modifié).
    func applyBandwidth() {
        let running = jobs.map { (id: $0.key, task: $0.value.task) }
        let rates = BandwidthPlanner.rates(for: running, limits: settingsLimits, remoteTypes: remoteTypes)
        for (id, rate) in rates { jobs[id]?.runner.setBandwidth(rate) }
    }

    /// Types des connexions rclone (local ou internet) : relus au démarrage et après une modification.
    public func refreshRemoteTypes() async {
        guard let remotes, let list = try? await remotes.listRemotes() else { return }
        remoteTypes = Dictionary(list.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
    }
```

Appeler `applyBandwidth()` dans `startJob` juste après `jobs[task.id] = Job(…)` et **avant** `Task.detached` (le runner reçoit sa limite avant `run`), et dans `finish` après `jobs.removeValue`. Appeler `await refreshRemoteTypes()` à la fin de `start()` (rendre `start` `async` n'est pas nécessaire : `main.swift` appelle `await core.refreshRemoteTypes()` après `await core.start()` ; les tests aussi via le harnais, qui l'appelle dans `makeCore` quand `remotes` est fourni — non : le test appelle `start()` puis la tâche démarre ; ajouter `await core.refreshRemoteTypes()` dans le test après `start()`), et dans `AgentCore+Remotes` après une configuration terminée ou une suppression.
`AgentPaths` : `public var settings: URL { root.appendingPathComponent("settings.json") }`. `main.swift` : `settingsStore: AgentSettingsStore(url: paths.settings)` et `await core.refreshRemoteTypes()`.
`AgentRouter` : `.setBandwidth(let limits)` → `await core.setBandwidth(limits)`. `status()` : `bandwidth: settingsLimits`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "BandwidthTests|AgentQueueTests|AgentCoreTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources Tests/SyncKitTests
git commit -m "Plafonds de débit : réglages de l'agent, sens de chaque tâche, partage, application au départ et à chaud"
```

### Task 5: rclone — limite au départ et à chaud par sa prise de contrôle

**Files:**
- Modify: `Sources/SyncKit/RcloneCommandBuilder.swift` (`--bwlimit` à partir de `RunOptions.bandwidth`, `--rc`)
- Modify: `Sources/SyncKit/EngineCommand.swift` (`RunOptions.bandwidth: BandwidthRate?`, `rcSocketPath: String?`)
- Create: `Sources/SyncKit/RcloneRemoteControl.swift`
- Modify: `Sources/SyncKit/TaskRunner+Rclone.swift`
- Test: `Tests/SyncKitTests/RcloneBandwidthTests.swift`

**Interfaces:**
- Consumes: `BandwidthRate`, `RunControl.bandwidth`, `RunControl.setBandwidthHook(_:)` (tâche 4)
- Produces: `RcloneCommandBuilder.bwlimitValue(_ rate: BandwidthRate) -> String?` (« UPK:DOWNK », `off`) ; `RcloneRemoteControl.socketPath() -> String` ; `RcloneRemoteControl.setRate(rclone:socket:rate:) async -> Bool`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SyncKit

final class RcloneBandwidthTests: IntegrationTestCase {
    func testBwlimitValueIsUploadColonDownloadInKiB() {
        XCTAssertEqual(RcloneCommandBuilder.bwlimitValue(BandwidthRate(upBytesPerSecond: 1_024_000, downBytesPerSecond: nil)), "1000K:off")
        XCTAssertEqual(RcloneCommandBuilder.bwlimitValue(BandwidthRate(upBytesPerSecond: nil, downBytesPerSecond: 2_048)), "off:2K")
        XCTAssertNil(RcloneCommandBuilder.bwlimitValue(.unlimited))
    }

    func testSocketPathFitsTheUnixLimit() {
        XCTAssertLessThan(RcloneRemoteControl.socketPath().utf8.count, 104)
    }

    // Copie réelle vers la mémoire : lente au départ (1 Mo/s), accélérée à chaud (100 Mo/s), elle finit vite.
    func testRateChangesWhileCopying() async throws {
        let runner = try makeRunner(rclone: true)
        let source = try folder("s")
        try writeBytes(source + "/gros.bin", megabytes: 40)
        var copy = SyncTask(name: "t", source: .local(path: source), destination: .cloud(remote: ":memory:", path: "b"))
        copy.options.excludes = []
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_000_000, downBytesPerSecond: 1_000_000))
        let started = Date()
        let running = Task { try await runner.run(copy) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 100_000_000, downBytesPerSecond: 100_000_000))
        let result = try await running.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "à 1 Mo/s il faudrait 40 s")
    }
}
```

(Si `:memory:` n'est pas accepté comme `remote` par `Endpoint.rcloneSpec`, utiliser `.cloud(remote: ":memory", path: "b")` selon le format produit par `rcloneSpec` : vérifier que la commande contient `:memory:b`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RcloneBandwidthTests`
Expected: FAIL (compilation)

- [ ] **Step 3: Write minimal implementation**

`RunOptions` : `public var bandwidth: BandwidthRate?` et `public var rcSocketPath: String?` (init `= nil`).
`RcloneCommandBuilder` :

```swift
    /// `--bwlimit` de rclone : « ENVOI:RÉCEPTION » en Kio/s, `off` pour un côté sans limite.
    public static func bwlimitValue(_ rate: BandwidthRate) -> String? {
        guard rate.upBytesPerSecond != nil || rate.downBytesPerSecond != nil else { return nil }
        func side(_ bytes: Int64?) -> String { bytes.map { "\(max(1, $0 / 1024))K" } ?? "off" }
        return "\(side(rate.upBytesPerSecond)):\(side(rate.downBytesPerSecond))"
    }
```

Dans `command(for:run:)`, remplacer le bloc `bandwidthLimitKBps` par :

```swift
        if task.mode != .verify {
            if let rate = run.bandwidth, let value = bwlimitValue(rate) {
                args += ["--bwlimit", value]
            } else if let limit = task.options.bandwidthLimitKBps {
                args += ["--bwlimit", "\(limit)K"]
            }
            if let socket = run.rcSocketPath { args += ["--rc", "--rc-addr", "unix://\(socket)", "--rc-no-auth"] }
        }
```

`Sources/SyncKit/RcloneRemoteControl.swift` :

```swift
import Foundation

/// Contrôle à distance d'une exécution rclone par une prise Unix privée : change sa limite de débit en route.
public enum RcloneRemoteControl {
    /// `<dossier temporaire de l'utilisateur>/smp-rc/<8 caractères>.sock` : sous la limite de 104 caractères des prises.
    public static func socketPath() -> String {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("smp-rc")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (folder as NSString).appendingPathComponent("\(UUID().uuidString.prefix(8)).sock")
    }

    /// `rclone rc core/bwlimit rate=…` ; faux si la prise ne répond pas (exécution qui démarre ou se termine).
    public static func setRate(rclone: String, socket: String, rate: BandwidthRate) async -> Bool {
        let value = RcloneCommandBuilder.bwlimitValue(rate) ?? "off"
        guard let process = try? ProcessRunner.spawn(
            executable: rclone, arguments: ["rc", "core/bwlimit", "rate=\(value)", "--unix-socket", socket], onLine: { _ in }
        ) else { return false }
        return await process.waitForExit() == 0
    }
}
```

`TaskRunner+Rclone.swift`, avant la construction de `command` : `options.bandwidth = control.bandwidth` et, sauf simulation et vérification, `let socket = RcloneRemoteControl.socketPath(); options.rcSocketPath = socket`. Après `control.registerMain(process)` :

```swift
        if let socket = options.rcSocketPath {
            control.setBandwidthHook { rate in
                Task.detached { _ = await RcloneRemoteControl.setRate(rclone: rclone, socket: socket, rate: rate) }
            }
        }
```

et après `waitForExit` : `control.setBandwidthHook(nil)` puis `try? FileManager.default.removeItem(atPath: socket)`. La simulation du garde-fou (`mirrorGuard`) n'ouvre pas de prise (`simulated.rcSocketPath = nil`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "RcloneBandwidthTests|RcloneCommandBuilderTests|RcloneRunnerTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncKit Tests/SyncKitTests/RcloneBandwidthTests.swift
git commit -m "rclone : limite de débit au départ et modifiable en route par sa prise de contrôle Unix"
```

### Task 6: rsync — limite au départ et relance à chaud

**Files:**
- Modify: `Sources/SyncKit/RsyncCommandBuilder.swift` (`RunOptions.bandwidth` → `--bwlimit`)
- Modify: `Sources/SyncKit/TaskRunner+Rsync.swift` (boucle de relance)
- Modify: `Sources/SyncKit/RunnerTypes.swift` (`RunControl.restartRequested`)
- Test: `Tests/SyncKitTests/RsyncBandwidthTests.swift`

**Interfaces:**
- Consumes: `RunControl.bandwidth`, `setBandwidthHook` (tâche 4)
- Produces: `RsyncCommandBuilder.bwlimitKBps(_ rate: BandwidthRate) -> Int?` (le plus petit des deux côtés, Kio/s)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SyncKit

final class RsyncBandwidthTests: IntegrationTestCase {
    func testRsyncUsesTheLowerSideInKiB() {
        XCTAssertEqual(RsyncCommandBuilder.bwlimitKBps(BandwidthRate(upBytesPerSecond: 2_048_000, downBytesPerSecond: 1_024_000)), 1000)
        XCTAssertNil(RsyncCommandBuilder.bwlimitKBps(.unlimited))
    }

    // Copie lente (1 Mo/s), plafond relevé en route : rsync est relancé, reprend et finit vite, fichier complet.
    func testRaisingTheCapRestartsRsyncAndFinishes() async throws {
        let runner = try makeRunner(rsync: true)
        let source = try folder("s"), destination = try folder("d")
        try writeBytes(source + "/gros.bin", megabytes: 30)
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_000_000, downBytesPerSecond: 1_000_000))
        let started = Date()
        let running = Task { try await runner.run(task(source, destination)) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 200_000_000, downBytesPerSecond: 200_000_000))
        let result = try await running.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        let copied = try FileManager.default.attributesOfItem(atPath: destination + "/gros.bin")[.size] as? Int
        XCTAssertEqual(copied, 30 * 1_048_576)
    }

    // Un miroir relancé ne refait pas son garde-fou et ne supprime rien de plus.
    func testMirrorRestartKeepsItsPlan() async throws {
        let runner = try makeRunner(rsync: true)
        let source = try folder("s"), destination = try folder("d")
        try writeBytes(source + "/gros.bin", megabytes: 20)
        try write(destination + "/en-trop.txt", "x")
        for index in 0..<10 { try write(destination + "/garde\(index).txt", "x"); try write(source + "/garde\(index).txt", "x") }
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_000_000, downBytesPerSecond: 1_000_000))
        let running = Task { try await runner.run(task(source, destination, mode: .mirror)) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        runner.setBandwidth(.unlimited)
        let result = try await running.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertFalse(exists(destination + "/en-trop.txt"))
        XCTAssertEqual(names(in: destination).filter { $0.hasPrefix("garde") }.count, 10)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SYNCMACPRO_RSYNC=/Applications/SyncMacPro.app/Contents/Resources/bin/rsync swift test --filter RsyncBandwidthTests`
Expected: FAIL (compilation)

- [ ] **Step 3: Write minimal implementation**

`RsyncCommandBuilder` :

```swift
    /// `--bwlimit` de rsync (Kio/s) : un seul débit, le plus bas des deux côtés.
    public static func bwlimitKBps(_ rate: BandwidthRate) -> Int? {
        let sides = [rate.upBytesPerSecond, rate.downBytesPerSecond].compactMap { $0 }
        guard let lowest = sides.min() else { return nil }
        return Int(max(1, lowest / 1024))
    }
```

Dans `command(for:run:)` : `if let rate = run.bandwidth, let kbps = bwlimitKBps(rate) { args.append("--bwlimit=\(kbps)") } else if let limit = task.options.bandwidthLimitKBps, task.mode != .verify { args.append("--bwlimit=\(limit)") }` (verify exclu dans les deux cas).
`RunControl` : `private var restartFlag = false`, `func requestRestart()` (pose le drapeau et termine `main` : `main?.terminate()`), `func consumeRestart() -> Bool` (lit et remet à faux).
`TaskRunner+Rsync.swift` : la partie « exécution » devient une boucle :

```swift
        var lastRestart = Date.distantPast
        control.setBandwidthHook { [control] _ in
            // Au plus une relance toutes les 5 s : un réglage modifié en continu ne fait pas redémarrer rsync sans fin.
            guard Date().timeIntervalSince(lastRestart) > 5 else { return }
            control.requestRestart()
        }
```

Attention Swift 5.10 : `lastRestart` est une `var` capturée — utiliser `let lastRestart = Locked(Date.distantPast)` et `lastRestart.get()/set(Date())`. Puis :

```swift
        var code: Int32
        repeat {
            var runOptionsNow = runOptions
            runOptionsNow.bandwidth = control.bandwidth
            let command = try RsyncCommandBuilder.command(for: task, run: runOptionsNow)
            let process = try ProcessRunner.spawn(executable: rsync, arguments: command.arguments) { output in /* inchangé */ }
            control.registerMain(process)
            watch.attach(process)
            code = await process.waitForExit()
            watch.stop()
            control.clearMain()
            if control.consumeRestart() && !control.stopRequested {
                onUpdate(.line("Limite de débit modifiée : rsync est relancé et reprend où il en était."))
                continue
            }
            break
        } while true
        control.setBandwidthHook(nil)
```

Le `watch` doit être recréé à chaque tour (`makeWatch(for: .rsync)` dans la boucle) et `lastRestart.set(Date())` dans le hook quand il relance. Le plan (`knownPlan`) et le garde-fou restent avant la boucle : ils ne sont pas refaits.

- [ ] **Step 4: Run test to verify it passes**

Run: `SYNCMACPRO_RSYNC=/Applications/SyncMacPro.app/Contents/Resources/bin/rsync swift test --filter "RsyncBandwidthTests|RsyncRunnerTests|RsyncCommandBuilderTests|Fix122RunnerTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncKit Tests/SyncKitTests/RsyncBandwidthTests.swift
git commit -m "rsync : limite de débit au départ, relance transparente quand elle change en route"
```

### Task 7: Progression des dossiers et vitesse moyenne (rclone et rsync), bilan

**Files:**
- Create: `Sources/SyncKit/RcloneDirectoryProgress.swift`
- Modify: `Sources/SyncKit/RcloneCommandBuilder.swift` (`-v` pour copy/sync/move ; `dirsCountCommand`)
- Modify: `Sources/SyncKit/RcloneOutputParser.swift` (`.copied(name:)`)
- Modify: `Sources/SyncKit/ProgressTracker.swift` (`fillFromRclone` : dossiers)
- Modify: `Sources/SyncKit/TaskRunner+Rclone.swift`, `Sources/SyncKit/TaskRunner.swift` (`result` : `directories`, `averageSpeed`)
- Test: `Tests/SyncKitTests/DirectoryProgressTests.swift`

**Interfaces:**
- Consumes: `ProgressInfo.dirsDone/totalDirs/averageSpeed`, `RunSummary.directories/averageSpeed` (tâche 1)
- Produces: `RcloneDirectoryProgress` (`init(directoriesOfPendingFiles: [String: Int])`, `mutating func fileCopied(_ path: String)`, `var done: Int`, `var total: Int`) ; `RcloneEvent.copied(name: String)`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SyncKit

final class DirectoryProgressTests: IntegrationTestCase {
    func testADirectoryIsDoneWhenAllItsFilesAreCopied() {
        var progress = RcloneDirectoryProgress(directoriesOfPendingFiles: ["a": 2, "a/b": 1, "": 1])
        XCTAssertEqual(progress.total, 3)
        progress.fileCopied("a/x.txt")
        XCTAssertEqual(progress.done, 0)
        progress.fileCopied("a/y.txt")
        XCTAssertEqual(progress.done, 1)
        progress.fileCopied("a/b/z.txt")
        progress.fileCopied("racine.txt")
        XCTAssertEqual(progress.done, 3)
        progress.fileCopied("a/b/z.txt")       // retransfert : rien de plus
        XCTAssertEqual(progress.done, 3)
    }

    func testCopiedLinesAreParsed() {
        let line = #"{"level":"info","msg":"Copied (new)","object":"a/b/z.txt","objectType":"*local.Object"}"#
        XCTAssertEqual(RcloneOutputParser.parse(line: line), .copied(name: "a/b/z.txt"))
        let replaced = #"{"level":"info","msg":"Copied (replaced existing)","object":"x.txt"}"#
        XCTAssertEqual(RcloneOutputParser.parse(line: replaced), .copied(name: "x.txt"))
    }

    // Copie rclone réelle : fichiers et dossiers suivis, bilan avec dossiers et vitesse moyenne.
    func testRcloneRunReportsDirectoriesAndAverageSpeed() async throws {
        let runner = try makeRunner(rclone: true)
        let source = try folder("s"), destination = try folder("d")
        for dir in ["a", "a/b", "c"] { for index in 0..<3 { try write(source + "/\(dir)/f\(index).txt", "x") } }
        let updates = UpdateCollector()
        var copy = SyncTask(name: "t", source: .local(path: source), destination: .cloud(remote: ":local", path: destination))
        copy.options.excludes = []
        let result = try await runner.run(copy) { updates.add($0) }
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(result.snapshot.totalDirs, 3)
        XCTAssertEqual(result.snapshot.dirsDone, 3)
        XCTAssertEqual(result.summary.directories, 3)
        XCTAssertNotNil(result.summary.averageSpeed)
    }
}
```

(Endpoint `:local` : si `rcloneSpec` ne permet pas une connexion `:local`, utiliser une destination `.local(path:)` avec `forcedEngine: .rclone` — vérifier `EngineSelector` ; le but est une exécution rclone réelle entre deux dossiers.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DirectoryProgressTests`
Expected: FAIL (compilation)

- [ ] **Step 3: Write minimal implementation**

`Sources/SyncKit/RcloneDirectoryProgress.swift` :

```swift
import Foundation

/// Dossiers « faits » d'une exécution rclone : un dossier l'est quand tous ses fichiers à copier le sont.
/// rclone ne donne que des fichiers ; le total vient de la simulation (fichiers à copier, groupés par dossier).
public struct RcloneDirectoryProgress: Sendable {
    private var remaining: [String: Int]
    private var copied: Set<String> = []
    public private(set) var done = 0
    public let total: Int

    /// - Parameter directoriesOfPendingFiles: dossier relatif (« » pour la racine) → nombre de fichiers à copier.
    public init(directoriesOfPendingFiles: [String: Int]) {
        remaining = directoriesOfPendingFiles.filter { $0.value > 0 }
        total = remaining.count
    }

    public mutating func fileCopied(_ path: String) {
        guard copied.insert(path).inserted else { return }
        let directory = (path as NSString).deletingLastPathComponent
        guard let count = remaining[directory] else { return }
        if count <= 1 { remaining[directory] = nil; done += 1 } else { remaining[directory] = count - 1 }
    }
}
```

`RcloneOutputParser` : `case copied(name: String)` ; dans `parse`, avant le `switch decoded.level`, `if message.hasPrefix("Copied (") || message.hasPrefix("Moved ("), let object = decoded.object { return .copied(name: object) }`.
`RcloneCommandBuilder` : ajouter `"-v"` aux arguments de `copy`, `sync` et `move` (pas à `bisync` ni `check`).
`TaskRunner+Rclone.swift` : pour copy, mirror, versioned, move (hors simulation), lancer en arrière-plan la simulation existante `--dry-run` avec `-v` dans un `stream` qui lit les lignes « Skipped copy as --dry-run is set » (rclone écrit `"msg":"Skipped copy as --dry-run is set (size …)","object":"chemin"`), pour bâtir `[dossier: nombre]` ; puis `let directories = Locked<RcloneDirectoryProgress?>(nil)` alimenté quand la simulation finit. Dans le gestionnaire de lignes : `case .copied(let name): directories.update { $0?.fileCopied(name) }` et, à chaque `.stats`, `tracker.apply(stats)` puis `tracker.setRcloneDirectories(done:total:)` depuis `directories.get()`.
`ProgressTracker` : `private var rcloneDirs: (done: Int, total: Int)?`, `public func setRcloneDirectories(done: Int, total: Int)`, et dans `fillFromRclone` : `snap.dirsDone = rcloneDirs?.done ?? 0; snap.totalDirs = rcloneDirs?.total`, `snap.averageSpeed = activeTime > 0 ? Double(stats.bytes) / activeTime : 0`.
`TaskRunner.result(…)` : `directories: snapshot.totalDirs.map { _ in snapshot.dirsDone }` et `averageSpeed: summary.durationSeconds > 0 ? Double(snapshot.doneBytes) / durationSeconds : nil` dans `RunSummary`.

- [ ] **Step 4: Run test to verify it passes**

Run: `SYNCMACPRO_RSYNC=/Applications/SyncMacPro.app/Contents/Resources/bin/rsync swift test --filter "DirectoryProgressTests|ProgressTrackerTests|ParserTests|RcloneRunnerTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncKit Tests/SyncKitTests/DirectoryProgressTests.swift
git commit -m "Progression : dossiers faits sur total aussi avec rclone, vitesse moyenne et dossiers dans le bilan"
```

### Task 8: Garde-fou des fichiers vides

**Files:**
- Create: `Sources/SyncKit/EmptySourceGuard.swift`
- Modify: `Sources/SyncKit/TaskRunner+Rsync.swift`, `Sources/SyncKit/TaskRunner+Rclone.swift`
- Modify: `Sources/SyncKit/EngineCommand.swift` (`RunOptions.excludeFrom: String?`), builders (`--exclude-from`)
- Test: `Tests/SyncKitTests/EmptySourceGuardTests.swift`

**Interfaces:**
- Produces: `EmptySourceGuard.protectedPaths(sourceEmpty: [String], destinationSizes: [String: Int64]) -> [String]` ; `EmptySourceGuard.message(count: Int) -> String`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SyncKit

final class EmptySourceGuardTests: IntegrationTestCase {
    func testOnlyEmptySourcesOverNonEmptyDestinationsAreProtected() {
        let protected = EmptySourceGuard.protectedPaths(
            sourceEmpty: ["a.psb", "nouveau.txt", "vide-partout.txt"],
            destinationSizes: ["a.psb": 6_488_591_566, "vide-partout.txt": 0]
        )
        XCTAssertEqual(protected, ["a.psb"])
    }

    func testRsyncCopyDoesNotOverwriteWithAnEmptyFile() async throws {
        let runner = try makeRunner(rsync: true)
        let source = try folder("s"), destination = try folder("d")
        try write(source + "/gros.psb", "")
        try write(destination + "/gros.psb", "contenu précieux")
        try write(source + "/nouveau-vide.txt", "")
        let result = try await runner.run(task(source, destination))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(read(destination + "/gros.psb"), "contenu précieux")
        XCTAssertTrue(exists(destination + "/nouveau-vide.txt"), "un fichier vide nouveau est copié")
        XCTAssertEqual(result.summary.message, EmptySourceGuard.message(count: 1))
    }

    func testRcloneCopyDoesNotOverwriteWithAnEmptyFile() async throws {
        let runner = try makeRunner(rclone: true)
        let source = try folder("s"), destination = try folder("d")
        try write(source + "/gros.psb", "")
        try write(destination + "/gros.psb", "contenu précieux")
        var copy = task(source, destination)
        copy.options.forcedEngine = .rclone
        let result = try await runner.run(copy)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read(destination + "/gros.psb"), "contenu précieux")
        XCTAssertEqual(result.summary.message, EmptySourceGuard.message(count: 1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SYNCMACPRO_RSYNC=/Applications/SyncMacPro.app/Contents/Resources/bin/rsync swift test --filter EmptySourceGuardTests`
Expected: FAIL (compilation)

- [ ] **Step 3: Write minimal implementation**

`Sources/SyncKit/EmptySourceGuard.swift` :

```swift
import Foundation

/// Un fichier de 0 octet à la source ne remplace jamais une version non vide à la destination : c'est presque toujours
/// un fichier que Drive pour ordinateur n'a pas fini d'envoyer (essai réel du 15/10 : un .psb de 6,5 Go à 0 octet).
public enum EmptySourceGuard {
    public static func protectedPaths(sourceEmpty: [String], destinationSizes: [String: Int64]) -> [String] {
        sourceEmpty.filter { (destinationSizes[$0] ?? 0) > 0 }.sorted()
    }

    public static func message(count: Int) -> String {
        "\(count) fichier(s) vide(s) à la source non copié(s) : la destination a une version non vide (voir le journal)."
    }

    /// Écrit la liste d'exclusions (un chemin par ligne, ancré à la racine) dans le dossier temporaire ; `nil` si vide.
    static func excludeFile(_ paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smp-vides-\(UUID().uuidString).txt")
        let lines = paths.map { "/" + $0.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "*", with: "\\*") }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
```

`RunOptions.excludeFrom: String?` ; rsync : `if let file = run.excludeFrom { args.append("--exclude-from=\(file)") }` ; rclone : `args += ["--exclude-from", file]` (avant les filtres de l'utilisateur ; avec une sélection d'éléments, les filtres rclone `--filter` gardent l'ordre : placer `--exclude-from` avant).
Rsync (copy, mirror, move ; source et destination sur le disque) : parcourir la source avec `FileManager.enumerator(at:includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])` (sélection d'éléments respectée, exclusions de la tâche ignorées : un fichier exclu n'est de toute façon pas copié), chemins relatifs des fichiers de taille 0 ; pour chacun, la taille à la destination ; `protectedPaths`.
Rclone (copy, mirror, versioned, move) : `stream(["lsf", "-R", "--files-only", "--max-size", "0", "--format", "p", source.rcloneSpec] + filtres)` → chemins ; s'il y en a, écrire la liste dans un fichier et `collect(["lsjson", destination.rcloneSpec, "--files-from", fichier, "--no-traverse"])` → tailles ; `protectedPaths`.
Si des chemins sont protégés : `options.excludeFrom = EmptySourceGuard.excludeFile(paths)`, une ligne de journal par chemin (`onUpdate(.line("Fichier vide à la source, non copié : \(path)"))`), et le message final (si la réussite n'a pas déjà un message) est `EmptySourceGuard.message(count:)`. Supprimer le fichier d'exclusions à la fin.

- [ ] **Step 4: Run test to verify it passes**

Run: `SYNCMACPRO_RSYNC=/Applications/SyncMacPro.app/Contents/Resources/bin/rsync swift test --filter "EmptySourceGuardTests|RsyncRunnerTests|RcloneRunnerTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncKit Tests/SyncKitTests/EmptySourceGuardTests.swift
git commit -m "Garde-fou : un fichier vide à la source ne remplace jamais une version non vide"
```

### Task 9: Client XPC et `ctl` (file, débit)

**Files:**
- Modify: `Sources/SyncKit/Agent/AgentXPC.swift` (rien de nouveau : `perform` suffit ; `status` porte `queue` et `bandwidth`)
- Modify: `Sources/SyncKit/Agent/CtlParser.swift`, `Sources/SyncKit/Agent/CtlSupport.swift`, `Sources/syncmacpro-ctl/main.swift`
- Modify: `README.md`
- Test: `Tests/SyncKitTests/CtlQueueTests.swift`

**Interfaces:**
- Produces: `CtlCommand.queue`, `.queueAdd(String)`, `.queueRemove(String)`, `.queueMove(String, up: Bool)`, `.queueRun(Bool)`, `.bandwidth`, `.setBandwidth(down: String?, up: String?, local: String?)` ; `CtlParser.mbps(_ text: String) throws -> Double?` (`off` → `nil`)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SyncKit

final class CtlQueueTests: XCTestCase {
    func parse(_ a: String...) throws -> CtlCommand { try CtlParser.parse(a).command }

    func testQueueCommands() throws {
        XCTAssertEqual(try parse("queue"), .queue)
        XCTAssertEqual(try parse("file"), .queue)
        XCTAssertEqual(try parse("queue", "add", "COMMONS 05"), .queueAdd("COMMONS 05"))
        XCTAssertEqual(try parse("queue", "remove", "COMMONS 05"), .queueRemove("COMMONS 05"))
        XCTAssertEqual(try parse("queue", "up", "x"), .queueMove("x", up: true))
        XCTAssertEqual(try parse("queue", "down", "x"), .queueMove("x", up: false))
        XCTAssertEqual(try parse("queue", "start"), .queueRun(true))
        XCTAssertEqual(try parse("queue", "stop"), .queueRun(false))
        XCTAssertThrowsError(try parse("queue", "shuffle"))
    }

    func testBandwidthCommands() throws {
        XCTAssertEqual(try parse("bandwidth"), .bandwidth)
        XCTAssertEqual(try parse("debit", "--down", "200", "--up", "off"), .setBandwidth(down: "200", up: "off", local: nil))
        XCTAssertEqual(try CtlParser.mbps("12,5"), 12.5)
        XCTAssertNil(try CtlParser.mbps("off"))
        XCTAssertThrowsError(try CtlParser.mbps("-3"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CtlQueueTests`
Expected: FAIL (compilation)

- [ ] **Step 3: Write minimal implementation**

`CtlParser` : alias `"file": "queue"`, `"debit": "bandwidth"`, `"débit": "bandwidth"` ; `valued` gagne `"down", "up", "local"` ; usage :

```
  queue                          file d'attente (ordre, état)
  queue add | remove | up | down <tâche>
  queue start | stop             lancer ou suspendre la file
  bandwidth                      plafonds de débit (Mbit/s)
  bandwidth [--down N] [--up N] [--local N]   N en Mbit/s, « off » pour retirer
```

`case "queue"` : sans argument `.queue` ; `add|remove|up|down` exigent une tâche (`rest.dropFirst().joined(separator: " ")`) ; `start|stop` ; sinon `CtlParseError.invalid("queue attend : add, remove, up, down, start ou stop")`. `case "bandwidth"` : si aucune de `down/up/local` → `.bandwidth`, sinon `.setBandwidth(down:up:local:)`.

```swift
    /// « 200 », « 12,5 » ou « off » (sans plafond).
    public static func mbps(_ text: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "off" || trimmed == "aucun" { return nil }
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")), value > 0 else {
            throw CtlParseError.invalid("Débit attendu en Mbit/s (nombre positif) ou « off » : \(text)")
        }
        return value
    }
```

`main.swift` : `.queue` affiche « File : lancée / suspendue », puis une ligne par élément (`1. nom`, « en cours » pour `current`) ; `.queueAdd` résout la tâche puis `perform(.enqueue(id))` ; `.queueRemove` `perform(.dequeue(id))` ; `.queueMove` lit `status().queue`, calcule l'index (±1, borné) et `perform(.moveInQueue(id, to:))` ; `.queueRun` `perform(.setQueueRunning(_))` ; `.bandwidth` affiche les trois plafonds (« sans plafond » pour `nil`) ; `.setBandwidth` part de `status().bandwidth ?? BandwidthLimits()`, remplace chaque valeur fournie par `try CtlParser.mbps(...)`, puis `perform(.setBandwidth(limits))` et affiche le résultat.
README : ajouter ces lignes dans la liste des commandes.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "CtlQueueTests|CtlParserTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources Tests/SyncKitTests/CtlQueueTests.swift README.md
git commit -m "syncmacpro-ctl : file d'attente et plafonds de débit"
```

### Task 10: App — modèle et présentation

**Files:**
- Modify: `Sources/SyncMacProUI/Agent/AgentModel.swift`
- Create: `Sources/SyncMacProUI/Logic/ProgressPresentation.swift`
- Modify: `Sources/SyncMacProUI/Logic/CardText.swift` (`nextRunLine(info:task:) -> String?`)
- Modify: `Sources/SyncMacProUI/Resources/{fr,en}.lproj/Localizable.strings`
- Test: `Tests/SyncMacProUITests/QueueModelTests.swift`, `Tests/SyncMacProUITests/ProgressPresentationTests.swift`

**Interfaces:**
- Consumes: requêtes de la tâche 1, `AgentStatus.queue/bandwidth`
- Produces:
  - `AgentModel.queue: QueueInfo?`, `bandwidth: BandwidthLimits?`, `enqueue(_ id: UUID) async`, `enqueueOnce(_ tasks: [SyncTask]) async -> String?`, `dequeue(_ id: UUID) async`, `moveInQueue(_ id: UUID, by offset: Int) async`, `setQueueRunning(_ running: Bool) async`, `setBandwidth(_ limits: BandwidthLimits)` (envoi différé 0,6 s)
  - `ProgressPresentation(localizer:)` : `filesLine(done:total:) -> String`, `dirsLine(done:total:) -> String?`, `averageSpeedLine(_:) -> String?`, `elapsedLine(_:) -> String`, `summaryLines(_ summary: RunSummary) -> [String]`
  - `CardText.nextRunLine(info: AgentTaskInfo, task: SyncTask?) -> String?` (`nil` pour une tâche manuelle)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class QueueModelTests: XCTestCase {
    func testQueueActionsAreForwarded() async {
        let agent = FakeAgent()
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let a = UUID(), b = UUID()
        agent.setStatus(.success(AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [],
                                             queue: QueueInfo(running: false, items: [a, b], current: nil))))
        await model.refreshNow()
        await model.enqueue(a)
        await model.moveInQueue(b, by: -1)
        await model.setQueueRunning(true)
        await model.dequeue(a)
        XCTAssertEqual(agent.performed, [.enqueue(a), .moveInQueue(b, to: 0), .setQueueRunning(true), .dequeue(a)])
        model.shutdown()
    }

    func testBandwidthIsSentOnceTheUserStopsTyping() async {
        let agent = FakeAgent()
        let sleeper = ManualSleeper()
        let model = AgentModel(agent: agent, sleeper: sleeper)
        model.setBandwidth(BandwidthLimits(downloadMbps: 1))
        model.setBandwidth(BandwidthLimits(downloadMbps: 12))
        model.setBandwidth(BandwidthLimits(downloadMbps: 120))
        await sleeper.advanceAll()
        let sent = await eventually { agent.performed == [.setBandwidth(BandwidthLimits(downloadMbps: 120))] }
        XCTAssertTrue(sent, "\(agent.performed)")
        model.shutdown()
    }
}

final class ProgressPresentationTests: XCTestCase {
    let p = ProgressPresentation(localizer: Localizer(language: "fr"))

    func testLines() {
        XCTAssertEqual(p.filesLine(done: 120, total: 925), "Fichiers 120 / 925")
        XCTAssertEqual(p.dirsLine(done: 14, total: 136), "Dossiers 14 / 136")
        XCTAssertNil(p.dirsLine(done: 0, total: nil))
        XCTAssertEqual(p.elapsedLine(724), "Écoulé 12 min 04 s")
        XCTAssertNotNil(p.averageSpeedLine(25_300_000))
        XCTAssertNil(p.averageSpeedLine(nil))
    }

    func testManualTasksHaveNoNextRunLine() {
        let text = CardText(localizer: Localizer(language: "fr"))
        let manual = SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b"), schedule: .manual)
        XCTAssertNil(text.nextRunLine(info: AgentTaskInfo(id: manual.id, name: "t", state: .idle), task: manual))
        var nightly = manual
        nightly.schedule = .daily(hour: 3, minute: 0)
        XCTAssertNotNil(text.nextRunLine(info: AgentTaskInfo(id: manual.id, name: "t", state: .idle, nextDue: Date()), task: nightly))
    }
}
```

(Si `ManualSleeper.advanceAll()` n'existe pas, utiliser l'API de `ManualSleeper` présente dans `Tests/SyncMacProUITests` pour libérer les attentes ; l'envoi différé passe par `sleeper.sleep(...)` du modèle.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "QueueModelTests|ProgressPresentationTests"`
Expected: FAIL (compilation)

- [ ] **Step 3: Write minimal implementation**

`AgentModel` : `public private(set) var queue: QueueInfo?` et `bandwidth: BandwidthLimits?` mis à jour dans `apply(status:)` (`queue = new.queue; bandwidth = new.bandwidth`). Actions par `act(on:)` existant :

```swift
    public func enqueue(_ id: UUID) async { await act(on: id) { try await $0.perform(.enqueue(id)) } }
    public func dequeue(_ id: UUID) async { await act(on: id) { try await $0.perform(.dequeue(id)) } }
    public func setQueueRunning(_ running: Bool) async { await act(on: nil) { try await $0.perform(.setQueueRunning(running)) } }

    /// Monte (−1) ou descend (+1) un élément de la file.
    public func moveInQueue(_ id: UUID, by offset: Int) async {
        guard let items = queue?.items, let index = items.firstIndex(of: id) else { return }
        let target = max(0, min(items.count - 1, index + offset))
        await act(on: id) { try await $0.perform(.moveInQueue(id, to: target)) }
    }

    /// Copies ponctuelles mises en file : `nil` si l'agent les a toutes prises, sinon le premier refus.
    public func enqueueOnce(_ tasks: [SyncTask]) async -> String? {
        for task in tasks {
            do { try await agent.perform(.enqueueOnce(task)) } catch { await refreshNow(); return Self.describe(error) }
        }
        await refreshNow()
        return nil
    }

    @ObservationIgnored private var bandwidthSend: Task<Void, Never>?

    /// Envoyé 0,6 s après la dernière modification : une saisie ne relance pas rsync à chaque chiffre.
    public func setBandwidth(_ limits: BandwidthLimits) {
        bandwidth = limits
        bandwidthSend?.cancel()
        let agent = self.agent, sleeper = self.sleeper
        bandwidthSend = Task { [weak self] in
            await sleeper.sleep(seconds: 0.6)
            guard !Task.isCancelled else { return }
            do { try await agent.perform(.setBandwidth(limits)) } catch { self?.alertMessage = Self.describe(error) }
        }
    }
```

(Adapter `sleeper.sleep(seconds:)` au nom réel de l'API `Sleeping` du modèle.)
`ProgressPresentation.swift` :

```swift
import Foundation
import SyncKit

/// Les lignes de progression façon RsyncGUI, communes aux cartes, à la liste, à la miniature et au bilan.
public struct ProgressPresentation {
    public let localizer: Localizer
    public init(localizer: Localizer) { self.localizer = localizer }

    public func filesLine(done: Int, total: Int?) -> String {
        localizer.format("progress.files", localizer.number(done), total.map(localizer.number) ?? "?")
    }

    public func dirsLine(done: Int?, total: Int?) -> String? {
        guard let total, total > 0 else { return nil }
        return localizer.format("progress.dirs", localizer.number(done ?? 0), localizer.number(total))
    }

    public func averageSpeedLine(_ speed: Double?) -> String? {
        guard let speed, speed > 0 else { return nil }
        return localizer.format("progress.average", localizer.speed(speed))
    }

    public func elapsedLine(_ seconds: TimeInterval) -> String {
        localizer.format("progress.elapsed", localizer.longDuration(seconds))
    }

    /// Bilan d'une exécution terminée : fichiers, dossiers, volume, vitesse moyenne, durée.
    public func summaryLines(_ summary: RunSummary) -> [String] {
        var lines = [localizer.format("summary.files", summary.filesTransferred), localizer.bytes(summary.bytesTransferred)]
        if let dirs = summary.directories { lines.append(localizer.format("summary.dirs", dirs)) }
        if let speed = averageSpeedLine(summary.averageSpeed) { lines.append(speed) }
        lines.append(elapsedLine(summary.durationSeconds))
        return lines
    }
}
```

`Localizer` : ajouter `number(_:)` (séparateur de milliers de la langue) et `longDuration(_:)` (« 12 min 04 s », « 1 h 03 min ») s'ils n'existent pas.
Textes FR : `"progress.files" = "Fichiers %@ / %@";` `"progress.dirs" = "Dossiers %@ / %@";` `"progress.average" = "%@ en moyenne";` `"progress.elapsed" = "Écoulé %@";` `"summary.dirs" = "%d dossier(s)";` EN : `"Files %@ / %@"`, `"Folders %@ / %@"`, `"%@ average"`, `"Elapsed %@"`, `"%d folder(s)"`.
`CardText.nextRunLine` :

```swift
    /// Ligne « Prochaine : … » ; `nil` pour une tâche manuelle (elle n'a pas d'échéance à annoncer).
    public func nextRunLine(info: AgentTaskInfo, task: SyncTask?) -> String? {
        if info.isOneOff || task?.schedule == .manual { return nil }
        return localizer.format("card.next", nextRun(info.nextDue))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "QueueModelTests|ProgressPresentationTests|StringsCompletenessTests|AgentModelTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncMacProUI Tests/SyncMacProUITests
git commit -m "App : file et plafonds dans le modèle, lignes de progression façon RsyncGUI, pas de « Prochaine » pour une tâche manuelle"
```

### Task 11: Écrans — cartes, tâches, file, copie, barre de menus

**Files:**
- Modify: `Sources/SyncMacProUI/Views/TaskCard.swift` (lignes de progression, bilan, `Mettre en file`, `nextRunLine`)
- Create: `Sources/SyncMacProUI/Views/QueueSection.swift`
- Modify: `Sources/SyncMacProUI/Views/DashboardView.swift`, `TasksView.swift`, `MenuBarViews.swift`, `CopyView.swift` (ou `CopyConfirmationView.swift`)
- Modify: `Localizable.strings` (FR/EN)
- Test: `Tests/SyncMacProUITests/QueueRenderTests.swift`

**Interfaces:**
- Consumes: `AgentModel.queue`, `enqueue`, `dequeue`, `moveInQueue`, `setQueueRunning`, `enqueueOnce`, `ProgressPresentation`, `CardText.nextRunLine` (tâche 10)
- Produces: `QueueSection(model:localizer:)` (vue réutilisée par la miniature, tâche 13) ; `TaskProgressDetails(progress:presentation:)`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
import SyncKit
@testable import SyncMacProUI

@MainActor
final class QueueRenderTests: XCTestCase {
    func testQueueSectionAndCardsRender() throws {
        let a = UUID(), b = UUID()
        let model = AgentModel.preview(
            status: AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [
                AgentTaskInfo(id: a, name: "COMMONS 05 Visuels → NAS", state: .running, progress: {
                    var p = ProgressInfo(TransferSnapshot())
                    p.filesDone = 120; p.totalFiles = 925; p.dirsDone = 14; p.totalDirs = 136
                    p.doneBytes = 14_000_000_000; p.totalBytes = 59_800_000_000; p.averageSpeed = 25_300_000; p.activeTime = 724
                    return p
                }(), queuePosition: nil),
                AgentTaskInfo(id: b, name: "COMMONS 01 Charte → NAS", state: .idle, queuePosition: 1),
            ], queue: QueueInfo(running: true, items: [b], current: a)),
            tasks: []
        )
        for scheme in [ColorScheme.light, .dark] {
            _ = try render(QueueSection(model: model, localizer: Localizer(language: "fr")).glassThemed(), name: "file", size: CGSize(width: 420, height: 220), scheme: scheme)
            _ = try render(DashboardBody(model: model, installState: .enabled, text: CardText(localizer: Localizer(language: "fr")), onInstall: {}).glassThemed(), name: "tableau-file", size: CGSize(width: 1100, height: 800), scheme: scheme)
        }
    }
}
```

(`AgentModel.preview(status:tasks:)` existe-t-il ? Utiliser l'initialiseur de prévisualisation présent dans `AgentModel` — celui qui reçoit `progress`, `history`… ligne 54 — en ajoutant `queue` s'il le faut.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter QueueRenderTests`
Expected: FAIL (compilation : `QueueSection` inconnu)

- [ ] **Step 3: Write minimal implementation**

`TaskProgressDetails` (dans `TaskCard.swift`) : sous la barre, une grille de deux colonnes avec `filesLine`, `dirsLine`, `progressLine` (volume, débit, reste), `averageSpeedLine`, `elapsedLine(progress.activeTime)` ; police `.caption.monospacedDigit()`.
`TaskCard` : `actions.enqueue` (nouveau) : bouton « Mettre en file » (`text.bubble` → `"text.badge.plus"`) à côté de « Lancer » dans les états `.idle, .waiting, .disabled` ; si `info.queuePosition != nil`, pastille « En file (n) » et bouton « Retirer de la file » à la place de « Mettre en file ». Remplacer `Text(l.format("card.next", …))` par `if let next = text.nextRunLine(info: info, task: task) { Text(next) }`. Après la fin (`info.state` non actif et `info.lastRun?.summary` présent et `info.lastRun?.finishedAt` plus récent que l'ouverture de la carte), afficher `ProgressPresentation.summaryLines` en une ligne `" · "`.
`QueueSection` :

```swift
import SwiftUI
import SyncKit

/// La file d'attente : ordre, monter / descendre, retirer, lancer / suspendre.
@MainActor
public struct QueueSection: View {
    let model: AgentModel
    let localizer: Localizer
    public init(model: AgentModel, localizer: Localizer) { self.model = model; self.localizer = localizer }

    private var names: [UUID: String] {
        Dictionary((model.status?.tasks ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    public var body: some View {
        let queue = model.queue ?? QueueInfo(running: false, items: [], current: nil)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(localizer.text("queue.title"), systemImage: "list.number").font(.headline)
                Spacer()
                Button(queue.running ? localizer.text("queue.suspend") : localizer.text("queue.start")) {
                    Task { await model.setQueueRunning(!queue.running) }
                }
                .buttonStyle(GlassButtonStyle(prominent: !queue.running))
                .disabled(queue.items.isEmpty && !queue.running)
            }
            if let current = queue.current, let name = names[current] {
                Label(localizer.format("queue.current", name), systemImage: "arrow.triangle.2.circlepath").font(.callout)
            }
            if queue.items.isEmpty {
                Text(localizer.text("queue.empty")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(queue.items.enumerated()), id: \.element) { index, id in
                HStack {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(names[id] ?? id.uuidString).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { Task { await model.moveInQueue(id, by: -1) } } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0).help(localizer.text("queue.up"))
                    Button { Task { await model.moveInQueue(id, by: 1) } } label: { Image(systemName: "chevron.down") }
                        .disabled(index == queue.items.count - 1).help(localizer.text("queue.down"))
                    Button { Task { await model.dequeue(id) } } label: { Image(systemName: "xmark") }
                        .help(localizer.text("queue.remove"))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }
}
```

`DashboardBody` et `TasksView` : afficher `QueueSection` en tête quand `model.queue?.items.isEmpty == false || model.queue?.current != nil`. `TasksView` : section « Copies » pour `model.status?.tasks.filter(\.isOneOff)` (carte `TaskCard` compacte). Ligne de tâche de `TasksListBody` : pendant une exécution, `GlowProgressBar` + `text.progressLine`.
`MenuBarViews` : `planned` exclut les tâches `.manual` (`model.tasks[$0.id]?.schedule != .manual`).
Écran Copie : à côté de « Copier », « Mettre en file » qui appelle `model.enqueueOnce(tasks)` avec les mêmes `SyncTask` que la copie (même construction que `runOnce`).
Textes FR : `"queue.title" = "File d'attente"; "queue.start" = "Lancer la file"; "queue.suspend" = "Suspendre la file"; "queue.current" = "En cours : %@"; "queue.empty" = "Aucune tâche en file"; "queue.up" = "Monter"; "queue.down" = "Descendre"; "queue.remove" = "Retirer de la file"; "card.enqueue" = "Mettre en file"; "card.inqueue" = "En file (%d)"; "copy.enqueue" = "Mettre en file";` EN : `"Queue"`, `"Start queue"`, `"Pause queue"`, `"Running: %@"`, `"No task in the queue"`, `"Move up"`, `"Move down"`, `"Remove from queue"`, `"Add to queue"`, `"Queued (%d)"`, `"Add to queue"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "QueueRenderTests|DashboardRenderTests|MenuBarRenderTests|CopyRenderTests|StringsCompletenessTests"`
Expected: PASS ; regarder les images produites dans `$TMPDIR/syncmacpro-renders/file-*.png` et `tableau-file-*.png` (lisibles en clair et en sombre).

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncMacProUI Tests/SyncMacProUITests/QueueRenderTests.swift
git commit -m "Écrans : file d'attente, progression détaillée et bilan sur les cartes, Mettre en file (tâches et copies)"
```

### Task 12: Réglages › Réseau

**Files:**
- Create: `Sources/SyncMacProUI/Views/NetworkSettingsSection.swift`
- Modify: `Sources/SyncMacProUI/Views/SettingsView.swift` (section ajoutée), `Sources/SyncMacPro/SyncMacProApp.swift` (passer `model` à `SettingsView`)
- Create: `Sources/SyncMacProUI/Logic/BandwidthDraft.swift`
- Modify: `Localizable.strings`
- Test: `Tests/SyncMacProUITests/NetworkSettingsTests.swift`

**Interfaces:**
- Consumes: `AgentModel.bandwidth`, `setBandwidth(_:)` (tâche 10)
- Produces: `BandwidthDraft` (`init(_ limits: BandwidthLimits?)`, champs `downloadText/uploadText/localText: String`, interrupteurs `downloadOn/uploadOn/localOn`, `var limits: BandwidthLimits?` — `nil` si un champ activé est invalide)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
import SyncKit
@testable import SyncMacProUI

@MainActor
final class NetworkSettingsTests: XCTestCase {
    func testDraftParsesMegabitsWithCommaAndOffSwitches() {
        var draft = BandwidthDraft(BandwidthLimits(downloadMbps: 200, uploadMbps: nil, localMbps: 950))
        XCTAssertEqual(draft.downloadText, "200")
        XCTAssertTrue(draft.downloadOn)
        XCTAssertFalse(draft.uploadOn)
        draft.uploadOn = true
        draft.uploadText = "12,5"
        draft.localOn = false
        XCTAssertEqual(draft.limits, BandwidthLimits(downloadMbps: 200, uploadMbps: 12.5, localMbps: nil))
        draft.uploadText = "abc"
        XCTAssertNil(draft.limits, "valeur invalide : rien n'est envoyé")
    }

    func testSectionRenders() throws {
        let model = AgentModel(agent: UnavailableAgent())
        for scheme in [ColorScheme.light, .dark] {
            _ = try render(Form { NetworkSettingsSection(model: model, localizer: Localizer(language: "fr")) }.glassThemed(),
                           name: "reglages-reseau", size: CGSize(width: 520, height: 320), scheme: scheme)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NetworkSettingsTests`
Expected: FAIL (compilation)

- [ ] **Step 3: Write minimal implementation**

`BandwidthDraft.swift` :

```swift
import Foundation
import SyncKit

/// Saisie des plafonds (Mbit/s, virgule acceptée) ; interrupteur éteint = sans plafond.
public struct BandwidthDraft: Equatable {
    public var downloadOn: Bool, uploadOn: Bool, localOn: Bool
    public var downloadText: String, uploadText: String, localText: String

    public init(_ limits: BandwidthLimits?) {
        func text(_ value: Double?) -> String {
            guard let value else { return "" }
            return value.rounded() == value ? String(Int(value)) : String(value).replacingOccurrences(of: ".", with: ",")
        }
        downloadOn = limits?.downloadMbps != nil; downloadText = text(limits?.downloadMbps)
        uploadOn = limits?.uploadMbps != nil; uploadText = text(limits?.uploadMbps)
        localOn = limits?.localMbps != nil; localText = text(limits?.localMbps)
    }

    private static func value(_ on: Bool, _ text: String) -> Double?? {
        guard on else { return .some(nil) }
        guard let number = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              number > 0 else { return nil }
        return .some(number)
    }

    /// `nil` si un champ activé n'est pas un nombre positif.
    public var limits: BandwidthLimits? {
        guard let down = Self.value(downloadOn, downloadText), let up = Self.value(uploadOn, uploadText),
              let local = Self.value(localOn, localText) else { return nil }
        return BandwidthLimits(downloadMbps: down, uploadMbps: up, localMbps: local)
    }
}
```

`NetworkSettingsSection` : `Section(localizer.text("settings.network"))` avec trois lignes (`Toggle` + `TextField` « Mbit/s » désactivé quand l'interrupteur est éteint) : « Réception internet », « Envoi internet », « Réseau local » ; texte d'aide : « En Mbit/s, comme speedtest. Les copies d'un même sens se partagent le plafond ; un changement s'applique aux copies en cours. » ; `@State private var draft: BandwidthDraft` initialisé depuis `model.bandwidth` (`.onAppear` et `.onChange(of: model.bandwidth)` si la saisie n'a pas changé) ; `.onChange(of: draft) { if let limits = draft.limits { model.setBandwidth(limits) } }` ; champ invalide : texte rouge « Nombre positif attendu ».
`SettingsView` : paramètre `model: AgentModel` (ajouter à l'init et à l'appel dans `SyncMacProApp`), section insérée après « Agent ».
Textes FR/EN : `settings.network` (« Réseau » / « Network »), `network.download` (« Réception internet » / « Internet download »), `network.upload` (« Envoi internet » / « Internet upload »), `network.local` (« Réseau local » / « Local network »), `network.unit` (« Mbit/s »), `network.help`, `network.invalid`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "NetworkSettingsTests|DistributionRenderTests|StringsCompletenessTests"`
Expected: PASS ; regarder `reglages-reseau-*.png`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests/SyncMacProUITests/NetworkSettingsTests.swift
git commit -m "Réglages › Réseau : plafonds de réception, d'envoi et du réseau local en Mbit/s, appliqués à chaud"
```

### Task 13: Mode miniature

**Files:**
- Create: `Sources/SyncMacProUI/Views/MiniView.swift`
- Create: `Sources/SyncMacProUI/MiniPanelController.swift`
- Modify: `Sources/SyncMacPro/SyncMacProApp.swift` (commande « Mode miniature » ⌥⌘M), `Sources/SyncMacProUI/Views/RootView.swift` (bouton dans la barre d'outils)
- Modify: `Localizable.strings`
- Test: `Tests/SyncMacProUITests/MiniViewTests.swift`

**Interfaces:**
- Consumes: `QueueSection`, `TaskProgressDetails`, `ProgressPresentation` (tâches 10–11)
- Produces: `MiniView(model:localizer:onExpand:)` ; `MiniPanelController.shared` (`toggle(model:localizer:)`, `isShown: Bool`)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
import SyncKit
@testable import SyncMacProUI

@MainActor
final class MiniViewTests: XCTestCase {
    func testMiniShowsRunningTransfersAndTheQueue() throws {
        let running = UUID(), queued = UUID()
        var progress = ProgressInfo(TransferSnapshot())
        progress.currentName = "MULTI-DEVICES/visuel.tif"; progress.filesDone = 10; progress.totalFiles = 925
        progress.doneBytes = 3_000_000_000; progress.totalBytes = 59_800_000_000; progress.currentSpeed = 25_000_000
        let model = AgentModel.preview(
            status: AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [
                AgentTaskInfo(id: running, name: "COMMONS 05", state: .running, progress: progress),
                AgentTaskInfo(id: queued, name: "COMMONS 01", state: .idle, queuePosition: 1),
            ], queue: QueueInfo(running: true, items: [queued], current: running)),
            tasks: []
        )
        let view = MiniView(model: model, localizer: Localizer(language: "fr"), onExpand: {})
        XCTAssertEqual(MiniView.runningIDs(model.status), [running])
        for scheme in [ColorScheme.light, .dark] {
            _ = try render(view.glassThemed(), name: "miniature", size: CGSize(width: 380, height: 300), scheme: scheme)
        }
    }

    func testNothingRunningShowsAnEmptyState() {
        XCTAssertEqual(MiniView.runningIDs(AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [])), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MiniViewTests`
Expected: FAIL (compilation)

- [ ] **Step 3: Write minimal implementation**

`MiniView` :

```swift
import SwiftUI
import SyncKit

/// La miniature : une carte par transfert en cours, puis la file. Toujours au premier plan (voir `MiniPanelController`).
@MainActor
public struct MiniView: View {
    let model: AgentModel
    let localizer: Localizer
    let onExpand: () -> Void

    public init(model: AgentModel, localizer: Localizer, onExpand: @escaping () -> Void) {
        self.model = model; self.localizer = localizer; self.onExpand = onExpand
    }

    static func runningIDs(_ status: AgentStatus?) -> [UUID] {
        (status?.tasks ?? []).filter { $0.state == .running || $0.state == .paused }.map(\.id)
    }

    public var body: some View {
        let text = CardText(localizer: localizer)
        let infos = (model.status?.tasks ?? []).filter { Self.runningIDs(model.status).contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(localizer.text("mini.title")).font(.headline)
                    Spacer()
                    Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.borderless).help(localizer.text("mini.expand"))
                }
                if infos.isEmpty { Text(localizer.text("mini.idle")).font(.callout).foregroundStyle(.secondary) }
                ForEach(infos) { info in
                    TaskCard(info: info, task: model.tasks[info.id], progress: model.progress[info.id] ?? info.progress,
                             busy: model.busyTasks.contains(info.id), text: text, actions: TaskCardActions(
                                pause: { Task { await model.pause(info.id) } },
                                resume: { Task { await model.resume(info.id) } },
                                stop: { Task { await model.stop(info.id) } }))
                }
                if model.queue?.items.isEmpty == false { QueueSection(model: model, localizer: localizer) }
            }
            .padding(12)
        }
        .frame(minWidth: 340, minHeight: 160)
    }
}
```

(`model.progress` : utiliser la propriété réelle du modèle qui tient l'avancement par tâche.)
`MiniPanelController` :

```swift
import AppKit
import SwiftUI

/// Fenêtre flottante du mode miniature : au premier plan, sur tous les bureaux, position retenue (comme RsyncGUI).
@MainActor
public final class MiniPanelController {
    public static let shared = MiniPanelController()
    private var panel: NSPanel?
    public var isShown: Bool { panel?.isVisible == true }

    public func toggle(model: AgentModel, localizer: Localizer) {
        if isShown { hide() } else { show(model: model, localizer: localizer) }
    }

    public func show(model: AgentModel, localizer: Localizer) {
        let panel = self.panel ?? makePanel(model: model, localizer: localizer)
        self.panel = panel
        for window in NSApp.windows where window !== panel && window.identifier?.rawValue.hasPrefix("main") == true {
            window.orderOut(nil)
        }
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
        WindowReopener.shared.handleReopen(hasVisibleWindows: false)
    }

    private func makePanel(model: AgentModel, localizer: Localizer) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = localizer.text("mini.title")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: MiniView(model: model, localizer: localizer) { [weak self] in self?.hide() }
            .glassThemed())
        panel.setFrameAutosaveName("SyncMacProMini")
        if !panel.setFrameUsingName("SyncMacProMini"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 400, y: screen.maxY - 300))
        }
        return panel
    }
}
```

(Vérifier l'identifiant réel de la fenêtre principale `Window(id: "main")` : SwiftUI lui donne un identifiant commençant par `main` ; à défaut, masquer toutes les fenêtres qui ne sont ni le panneau ni la barre de menus — `window.className` contenant `MenuBarExtra` exclu.)
`SyncMacProApp` : `.commands { CommandGroup(after: .windowList) { Button(localizer.text("mini.toggle")) { MiniPanelController.shared.toggle(model: model, localizer: localizer) }.keyboardShortcut("m", modifiers: [.command, .option]) } }` sur la scène `Window`. `RootView` : bouton de barre d'outils (`rectangle.inset.bottomright.filled`) qui appelle `toggle`.
Textes FR/EN : `mini.title` (« Transferts » / « Transfers »), `mini.expand` (« Agrandir la fenêtre » / « Show full window »), `mini.idle` (« Aucun transfert en cours » / « No transfer running »), `mini.toggle` (« Mode miniature » / « Mini mode »).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "MiniViewTests|StringsCompletenessTests|RootViewTests"`
Expected: PASS ; regarder `miniature-*.png`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests/SyncMacProUITests/MiniViewTests.swift
git commit -m "Mode miniature : fenêtre flottante avec les transferts en cours et la file (⌥⌘M)"
```

### Task 14: Version, documentation, vérification réelle

**Files:**
- Modify: `VERSION` (1.3.0), `docs/release-notes.md`, `README.md`, `docs/manual-checks-ui.md`

- [ ] **Step 1: Suite complète**

Run: `SYNCMACPRO_RSYNC=/Applications/SyncMacPro.app/Contents/Resources/bin/rsync swift test 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`, aucun test ignoré.

- [ ] **Step 2: Notes de version et version**

`VERSION` → `1.3.0`. En tête de `docs/release-notes.md` :

```markdown
SyncMacPro 1.3.0 — file d'attente, progression détaillée, mode miniature et plafonds de débit.

**Nouveau (1.3.0)**
- File d'attente : « Mettre en file » sur une tâche ou une copie, « Lancer la file » ; les tâches partent une par une, dans l'ordre que vous choisissez (monter, descendre, retirer).
- Progression comme RsyncGUI : fichiers et dossiers faits sur le total, vitesse moyenne, temps écoulé ; le bilan reste affiché à la fin et dans l'historique.
- Mode miniature (⌥⌘M) : une petite fenêtre toujours visible avec les transferts en cours et la file.
- Réglages › Réseau : plafonds de réception et d'envoi internet et du réseau local, en Mbit/s comme speedtest, appliqués aux copies en cours.
- Garde-fou : un fichier vide à la source ne remplace plus une version non vide à la destination.

**Corrections (1.3.0)**
- Une tâche manuelle n'affiche plus « Prochaine : Sans échéance ».
- Le nombre d'erreurs ne compte plus plusieurs fois le même incident.
```

- [ ] **Step 3: Essai réel (app d'essai assemblée sans désenregistrer l'agent)**

```bash
swift build -c release && BIN=$(swift build -c release --show-bin-path)
scripts/assemble-app.sh "$BIN" "$TMPDIR/essai/SyncMacPro.app" 1.3.0 "$(git rev-list --count HEAD)" .build/vendor
```

Avec un agent de banc séparé (label `com.sylvain.syncmacpro.agent.bench`, données dans `~/Library/Application Support/SyncMacPro-bench`, comme dans la campagne 1.2.2) :
1. Trois tâches locales lentes (`bandwidthLimitKBps` 2000) en file, `queue start`, `queue up` de la dernière pendant la première : ordre respecté, une à la fois.
2. Copie rclone vers `:memory:` puis rsync locale, `bandwidth --local 8` puis `bandwidth --local off` en route : débit observé dans `status --json`, rsync relancé une fois, fichiers identiques (`cmp`).
3. Fichier vide à la source et plein à la destination : non copié, message du bilan.
4. App d'essai ouverte sur l'agent de banc (`SYNCMACPRO_AGENT_SERVICE=com.sylvain.syncmacpro.agent.bench`) : miniature (⌥⌘M), file, Réglages › Réseau ; capture de la fenêtre de l'app seulement, supprimée ensuite.
Nettoyer le banc, vérifier que l'agent installé de l'utilisateur répond (`syncmacpro-ctl agent status`).

- [ ] **Step 4: Commit**

```bash
git add VERSION docs README.md
git commit -m "Version 1.3.0 et notes de version"
```
