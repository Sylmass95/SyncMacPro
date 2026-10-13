# SyncMacPro — sous-projet 3b (créer) : plan d'implémentation

> **Pour les agents :** SOUS-COMPÉTENCE REQUISE : superpowers:executing-plans (exécution native choisie par l'auteur, en autonomie). Les étapes utilisent la syntaxe à cases (`- [ ]`).

**Objectif :** créer, modifier, dupliquer, activer et supprimer des tâches depuis l'app, avec un éditeur en 5 étapes, une simulation avant d'enregistrer, des modèles, et le journal détaillé de chaque exécution.

**Architecture :** l'agent devient le seul à écrire `tasks.json` (commandes XPC `saveTask` / `removeTask`, contrat en version 2), exécute les simulations hors de la file et écrit un journal par exécution. L'app ajoute un brouillon de tâche pur et testable (`TaskDraft`), un générateur de phrases (`TaskSummaryText`), l'éditeur, l'écran Tâches et la feuille du journal.

**Stack :** Swift 5.9 (mode 5), SwiftUI, Observation, XCTest, `NSOpenPanel`.

**Spec :** `docs/superpowers/specs/2026-10-13-syncmacpro-tasks-editor-design.md`

## Contraintes globales

- macOS 14, swift-tools 5.9, mode Swift 5, aucune dépendance externe.
- **CI Swift 5.10 / SDK macOS 14** : toute vue SwiftUI est marquée `@MainActor` ; jamais de `var` ni de `weak self` capturés dans une closure `@Sendable` / `Task` imbriquée (copies `let`, boîte faible) ; expressions de test longues découpées. La PR brouillon #4 est poussée après **chaque** tâche.
- Contrat XPC : `agentProtocolVersion = 2`.
- Journal : `logs/<id de l'exécution>.log`, plafond **5 000 000 octets**, lecture des **262 144** derniers octets, purge avec l'historique (90 jours).
- Simulation : délai client **900 s**, aucune écriture dans l'historique.
- Textes de l'app : `Localizer`, clés dans `fr.lproj` et `en.lproj` ; les messages de l'agent restent en français.
- Les 321 tests existants restent verts : `SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync" swift test`.
- Commits terminés par `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Décisions prises en rédigeant le plan

- **Ruling : `TaskValidator` dans SyncKit**, partagé par l'agent (refus de `saveTask`) et l'app (validation par étape) ; il renvoie des `TaskProblem` que chacun met en mots.
- **Ruling : dossiers imbriqués refusés** (destination dans la source ou l'inverse) : rsync recopierait la destination dans elle-même, un miroir effacerait la source.
- **Ruling : une simulation ne demande pas de nom** (on simule un brouillon).
- **Ruling : `ctl` gagne `simulate <tâche>` et `log <tâche>`** : ils servent l'essai réel de bout en bout (l'éditeur, lui, ne se pilote pas sans clics).
- **Ruling : les éléments choisis (`sourceItems`) sont conservés mais pas modifiables dans l'éditeur** (YAGNI, ils viendront avec la copie à deux panneaux en 3c).

## Points de revue

1. Destination dans la source (ou l'inverse) : refusée avec un message clair. → tâche 1.
2. Modifier une tâche pendant qu'elle tourne : l'exécution continue, la nouvelle version vaut pour la suivante. → tâche 2.
3. Agent injoignable éditeur ouvert : Enregistrer et Simuler désactivés ; un refus de l'agent reste affiché dans l'éditeur. → tâches 6, 9.
4. Journal énorme, fichier absent, exécution antérieure à 3b (`logPath` vide) : message clair, pas de plantage. → tâches 4, 11.
5. Miroir qui supprimerait beaucoup : la simulation le dit en clair avant l'enregistrement. → tâches 3, 8.

---

### Tâche 1 : validation des tâches (`TaskValidator`)

**Fichiers :** créer `Sources/SyncKit/TaskValidator.swift` ; tester `Tests/SyncKitTests/TaskValidatorTests.swift`.

**Interfaces :** produit `enum TaskProblem: String, Codable, CaseIterable, Sendable` (`emptyName`, `missingSource`, `missingDestination`, `sameSourceAndDestination`, `nestedFolders`, `engineMismatch`, `invalidThreshold`, `invalidSchedule`) avec `message` (français) ; `enum TaskValidator { static func problems(in: SyncTask) -> [TaskProblem] }`.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncKitTests/TaskValidatorTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class TaskValidatorTests: XCTestCase {
    func task(
        _ name: String = "t", source: Endpoint = .local(path: "/a"), destination: Endpoint = .local(path: "/b"),
        mode: SyncMode = .copy, schedule: Schedule = .manual
    ) -> SyncTask {
        SyncTask(name: name, source: source, destination: destination, mode: mode, schedule: schedule)
    }

    func testAValidTaskHasNoProblem() {
        XCTAssertEqual(TaskValidator.problems(in: task()), [])
        XCTAssertEqual(TaskValidator.problems(in: task(destination: .cloud(remote: "drive", path: "x"))), [])
    }

    func testNameAndEndpointsAreRequired() {
        XCTAssertEqual(TaskValidator.problems(in: task("  ")), [.emptyName])
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: ""))), [.missingSource])
        XCTAssertEqual(TaskValidator.problems(in: task(destination: .cloud(remote: " ", path: "x"))), [.missingDestination])
    }

    func testSameFolderIsRefusedEvenWrittenDifferently() {
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: "/a/b"), destination: .local(path: "/a/b/"))),
                       [.sameSourceAndDestination])
        XCTAssertEqual(TaskValidator.problems(in: task(source: .cloud(remote: "d", path: "x"), destination: .cloud(remote: "d", path: "x"))),
                       [.sameSourceAndDestination])
    }

    func testNestedFoldersAreRefusedInBothDirections() {
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: "/Users/moi/Photos"),
                                                       destination: .local(path: "/Users/moi/Photos/Sauvegarde"))), [.nestedFolders])
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: "/Volumes/NAS/a/b"),
                                                       destination: .network(url: "smb://nas/a", mountPath: "/Volumes/NAS/a"))), [.nestedFolders])
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: "/a/photos"), destination: .local(path: "/a/photos-old"))), [],
                       "un préfixe de nom n'est pas un dossier parent")
    }

    func testEngineMismatchIsReported() {
        var forced = task(mode: .bidirectional)
        forced.options.forcedEngine = .rsync
        XCTAssertEqual(TaskValidator.problems(in: forced), [.engineMismatch])
    }

    func testThresholdAndScheduleAreChecked() {
        var bad = task(schedule: .weekdays(days: [], hour: 8, minute: 0))
        bad.options.deleteThresholdPercent = 0
        XCTAssertEqual(TaskValidator.problems(in: bad), [.invalidThreshold, .invalidSchedule])
        XCTAssertEqual(TaskValidator.problems(in: task(schedule: .daily(hour: 24, minute: 0))), [.invalidSchedule])
        XCTAssertEqual(TaskValidator.problems(in: task(schedule: .everyMinutes(0))), [.invalidSchedule])
        XCTAssertEqual(TaskValidator.problems(in: task(schedule: .weekdays(days: [8], hour: 8, minute: 0))), [.invalidSchedule])
    }

    func testEveryProblemHasAFrenchMessage() {
        for problem in TaskProblem.allCases { XCTAssertFalse(problem.message.isEmpty, problem.rawValue) }
    }
}
```

- [ ] **Étape 2 : vérifier l'échec** — `swift test --filter TaskValidatorTests 2>&1 | grep -E "error:" | head -2` → erreur de compilation (`TaskValidator` inconnu).

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/TaskValidator.swift` :

```swift
import Foundation

/// Ce qui empêche d'enregistrer une tâche. L'agent refuse `saveTask` avec le message ; l'app traduit chaque cas.
public enum TaskProblem: String, Codable, CaseIterable, Equatable, Sendable {
    case emptyName
    case missingSource
    case missingDestination
    case sameSourceAndDestination
    /// La destination est dans la source, ou l'inverse : rsync recopierait la destination dans elle-même,
    /// un miroir effacerait la source.
    case nestedFolders
    case engineMismatch
    case invalidThreshold
    case invalidSchedule

    public var message: String {
        switch self {
        case .emptyName: return "Donnez un nom à la tâche."
        case .missingSource: return "Choisissez une source."
        case .missingDestination: return "Choisissez une destination."
        case .sameSourceAndDestination: return "La source et la destination sont le même dossier."
        case .nestedFolders: return "La destination ne peut pas être dans la source, ni la source dans la destination."
        case .engineMismatch: return "Le moteur choisi ne sait pas faire ce mode."
        case .invalidThreshold: return "Le seuil de suppression doit être compris entre 1 et 100 %."
        case .invalidSchedule: return "La planification est incomplète (heure, jours ou intervalle)."
        }
    }
}

public enum TaskValidator {
    /// Tous les problèmes, dans l'ordre des étapes de l'éditeur.
    public static func problems(in task: SyncTask) -> [TaskProblem] {
        var found: [TaskProblem] = []
        if task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(.emptyName) }
        let sourceMissing = isEmpty(task.source)
        let destinationMissing = isEmpty(task.destination)
        if sourceMissing { found.append(.missingSource) }
        if destinationMissing { found.append(.missingDestination) }
        if !sourceMissing && !destinationMissing {
            let source = key(task.source), destination = key(task.destination)
            if source == destination {
                found.append(.sameSourceAndDestination)
            } else if task.source.isCloud == task.destination.isCloud,
                      source.hasPrefix(destination + "/") || destination.hasPrefix(source + "/") {
                found.append(.nestedFolders)
            }
        }
        if (try? EngineSelector.engine(for: task)) == nil { found.append(.engineMismatch) }
        if !(1...100).contains(task.options.deleteThresholdPercent) { found.append(.invalidThreshold) }
        if !isValid(task.schedule) { found.append(.invalidSchedule) }
        return found
    }

    static func isEmpty(_ endpoint: Endpoint) -> Bool {
        switch endpoint {
        case .local(let path): return path.trimmingCharacters(in: .whitespaces).isEmpty
        case .network(_, let mountPath): return mountPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .cloud(let remote, _): return remote.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Forme comparable : chemin normalisé sans « / » final, ou « remote:chemin ».
    static func key(_ endpoint: Endpoint) -> String {
        if let path = endpoint.filesystemPath {
            var standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            while standardized.count > 1 && standardized.hasSuffix("/") { standardized.removeLast() }
            return standardized
        }
        var spec = endpoint.rcloneSpec
        while spec.hasSuffix("/") { spec.removeLast() }
        return spec
    }

    static func isValid(_ schedule: Schedule) -> Bool {
        func time(_ hour: Int, _ minute: Int) -> Bool { (0..<24).contains(hour) && (0..<60).contains(minute) }
        switch schedule {
        case .manual, .whenAvailable: return true
        case .everyMinutes(let minutes): return minutes >= 1
        case .daily(let hour, let minute): return time(hour, minute)
        case .weekdays(let days, let hour, let minute):
            return !days.isEmpty && days.allSatisfy { (1...7).contains($0) } && time(hour, minute)
        }
    }
}
```

- [ ] **Étape 4 : vérifier** — `swift test --filter TaskValidatorTests 2>&1 | grep -E "error:|Executed .* tests" | tail -2` → 7 tests passent.

- [ ] **Étape 5 : commit et push**

```bash
git add Sources/SyncKit/TaskValidator.swift Tests/SyncKitTests/TaskValidatorTests.swift
git commit -m "Validation des tâches (dossiers imbriqués, planification, moteur)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 2 : l'agent enregistre et supprime les tâches (XPC v2)

**Fichiers :** modifier `Sources/SyncKit/Agent/AgentProtocol.swift`, `AgentRouter.swift`, `AgentTypes.swift`, `Tests/SyncKitTests/AgentProtocolTests.swift` ; créer `Sources/SyncKit/Agent/AgentCore+Tasks.swift`, `Tests/SyncKitTests/AgentTaskEditingTests.swift`.

**Interfaces :**
- Consomme : `TaskValidator` (tâche 1).
- Produit : `agentProtocolVersion = 2` ; `AgentRequest.saveTask(SyncTask)`, `.removeTask(UUID)` ; `AgentError.invalidTask(String)`, `.unknownRun` ; `AgentCore.saveTask(_:) throws`, `AgentCore.removeTask(_:) throws`.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncKitTests/AgentTaskEditingTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentTaskEditingTests: XCTestCase {
    func testSaveCreatesTheTaskOnDiskAndTheAgentSeesIt() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let events = Locked<[AgentEvent]>([])
        _ = await core.addObserver { events.set(events.get() + [$0]) }
        let task = makeTask("Nouvelle", schedule: .manual)
        try await core.saveTask(task)
        let listed = await core.listTasks()
        XCTAssertEqual(listed.map(\.name), ["Nouvelle"])
        XCTAssertEqual(try h.taskStore.load().map(\.id), [task.id])
        XCTAssertTrue(events.get().contains(.stateChanged))
    }

    func testSaveReplacesAnExistingTask() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        var task = makeTask("Avant", schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        task.name = "Après"
        try await core.saveTask(task)
        XCTAssertEqual(try h.taskStore.load().map(\.name), ["Après"])
    }

    func testInvalidTaskIsRefusedWithTheReason() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let bad = SyncTask(name: "", source: .local(path: "/a"), destination: .local(path: "/a/b"))
        do {
            try await core.saveTask(bad)
            XCTFail("un refus était attendu")
        } catch {
            XCTAssertEqual(error as? AgentError, .invalidTask(TaskProblem.emptyName.message))
        }
        XCTAssertTrue(try h.taskStore.load().isEmpty, "rien n'est écrit")
    }

    func testEditingARunningTaskDoesNotDisturbTheRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        var task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        task.name = "Renommée"
        try await core.saveTask(task)
        let state = await core.status().tasks.first?.state
        XCTAssertEqual(state, .running)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .succeeded)
    }

    func testRemoveDeletesButRefusesARunningTask() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let busy = makeTask("Occupée", schedule: .manual), idle = makeTask("Libre", schedule: .manual)
        try h.save([busy, idle])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(busy.id)
        do { try await core.removeTask(busy.id); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .alreadyRunning) }
        do { try await core.removeTask(UUID()); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .unknownTask) }
        try await core.removeTask(idle.id)
        XCTAssertEqual(try h.taskStore.load().map(\.name), ["Occupée"])
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testRouterSavesAndRefusesOldProtocolVersions() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let task = makeTask("Par XPC", schedule: .manual)
        let saved = try JSONDecoder().decode(
            AgentResponseEnvelope.self,
            from: await AgentRouter.handle(JSONEncoder().encode(AgentRequestEnvelope(request: .saveTask(task))), core: core)
        )
        XCTAssertEqual(saved.response, .ok)
        XCTAssertEqual(saved.version, 2)
        let old = Data(#"{"version":1,"request":"status"}"#.utf8)
        let refused = try JSONDecoder().decode(AgentResponseEnvelope.self, from: await AgentRouter.handle(old, core: core))
        XCTAssertEqual(refused.response, .error(.versionMismatch(agent: 2, client: 1)))
    }
}
```

Dans `Tests/SyncKitTests/AgentProtocolTests.swift`, remplacer chaque `encode(version: 1,` par `encode(version: agentProtocolVersion,` (les requêtes « actuelles » suivent la version courante) ; ajouter `.saveTask(makeTask("x"))` et `.removeTask(id)` à la liste de `testEveryRequestSurvivesEncoding`, et `.error(.invalidTask("raison"))`, `.error(.unknownRun)` à `testResponsesSurviveEncoding`.

- [ ] **Étape 2 : vérifier l'échec** — `swift test --filter "AgentTaskEditingTests|AgentProtocolTests" 2>&1 | grep -E "error:" | head -3` → erreur de compilation (`saveTask` inconnu).

- [ ] **Étape 3 : implémenter**

`AgentProtocol.swift` : `public let agentProtocolVersion = 2` ; ajouter à `AgentRequest` les cas `case saveTask(SyncTask)` et `case removeTask(UUID)`.

`AgentTypes.swift`, enum `AgentError` : ajouter `case invalidTask(String)` et `case unknownRun`, et dans `errorDescription` : `case .invalidTask(let reason): return reason` et `case .unknownRun: return "Exécution inconnue."`.

`AgentRouter.swift` : dans le `switch envelope.request`, ajouter `case .saveTask(let task): try await core.saveTask(task)` et `case .removeTask(let id): try await core.removeTask(id)` ; dans `reply`, remplacer le littéral `"version":1` de la réponse de secours par `"version":\(agentProtocolVersion)` (chaîne interpolée normale, non brute).

`Sources/SyncKit/Agent/AgentCore+Tasks.swift` :

```swift
import Foundation

extension AgentCore {
    /// Crée ou remplace une tâche. Seul l'agent écrit `tasks.json`. Une exécution en cours continue avec l'ancienne
    /// version ; la nouvelle vaut pour la suivante.
    public func saveTask(_ task: SyncTask) throws {
        if let problem = TaskValidator.problems(in: task).first { throw AgentError.invalidTask(problem.message) }
        do { try taskStore.upsert(task) } catch { throw AgentError.internalFailure("tasks.json non enregistré : \(error)") }
        loadTasks()
        persist()
        emit(.stateChanged)
    }

    /// Supprime une tâche ; refusé tant qu'elle tourne ou attend en file. L'historique est conservé.
    public func removeTask(_ id: UUID) throws {
        guard tasks.contains(where: { $0.id == id }) else { throw AgentError.unknownTask }
        guard jobs[id] == nil, !queue.contains(where: { $0.id == id }) else { throw AgentError.alreadyRunning }
        do { try taskStore.remove(id: id) } catch { throw AgentError.internalFailure("tasks.json non enregistré : \(error)") }
        loadTasks()
        persist()
        emit(.stateChanged)
    }
}
```

- [ ] **Étape 4 : vérifier** — `swift test --filter "AgentTaskEditingTests|AgentProtocolTests|AgentXPCTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -2` → tous passent ; puis la suite complète → verte.

- [ ] **Étape 5 : commit et push**

```bash
git add Sources/SyncKit Tests/SyncKitTests
git commit -m "Agent : enregistrement et suppression des tâches par XPC (contrat v2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 3 : simulation par l'agent

**Fichiers :** modifier `AgentProtocol.swift`, `AgentRouter.swift`, `AgentTypes.swift`, `AgentCore.swift` (propriété `simulations`), `AgentXPC.swift` (délai par requête, `simulate`), `Tests/SyncKitTests/AgentTestSupport.swift` (`dryRuns`) ; créer `Sources/SyncKit/Agent/AgentCore+Simulation.swift`, `Tests/SyncKitTests/AgentSimulationTests.swift`.

**Interfaces :**
- Produit : `struct SimulationResult: Codable, Equatable, Sendable` (`status`, `filesToTransfer`, `bytesToTransfer`, `deletions`, `message`) + `init(_ result: RunResult)` ; `AgentRequest.simulate(SyncTask)`, `.cancelSimulation(UUID)` ; `AgentResponse.simulation(SimulationResult)` ; `AgentCore.simulate(_:) async throws -> SimulationResult`, `cancelSimulation(_:)` ; `AgentClient.send(_:timeout:)`, `AgentClient.simulate(_:) async throws -> SimulationResult` (délai 900 s).

- [ ] **Étape 1 : écrire les tests qui échouent**

Dans `Tests/SyncKitTests/AgentTestSupport.swift`, `FakeRunner` : ajouter `let dryRuns = Locked<[Bool]>([])` et, au début de `run`, `dryRuns.set(dryRuns.get() + [dryRun])`.

`Tests/SyncKitTests/AgentSimulationTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentSimulationTests: XCTestCase {
    func testSimulationRunsADryRunAndLeavesNoTrace() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let draft = makeTask("", schedule: .manual)   // un brouillon sans nom peut être simulé
        let result = try await core.simulate(draft)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.filesToTransfer, 1)
        XCTAssertEqual(h.factory.runners.get().first?.dryRuns.get(), [true])
        XCTAssertTrue(try h.history.list().isEmpty, "une simulation n'entre pas dans l'historique")
        XCTAssertTrue(try h.taskStore.load().isEmpty, "ni dans tasks.json")
    }

    func testInvalidDraftIsRefused() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let nested = SyncTask(name: "", source: .local(path: "/a"), destination: .local(path: "/a/b"))
        do { _ = try await core.simulate(nested); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .invalidTask(TaskProblem.nestedFolders.message))
        }
    }

    func testSimulationCanBeCancelled() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let draft = makeTask(schedule: .manual)
        let pending = Task { try await core.simulate(draft) }
        _ = await eventually { h.factory.runners.get().count == 1 }
        await core.cancelSimulation(draft.id)
        let result = try await pending.value
        XCTAssertEqual(result.status, .stopped)
    }

    func testSimulationGoesThroughXPC() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let delegate = AgentListenerDelegate(core: core)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        let client = AgentClient(timeout: 5) { NSXPCConnection(listenerEndpoint: endpoint) }
        let result = try await client.simulate(makeTask(schedule: .manual))
        XCTAssertEqual(result.status, .succeeded)
        withExtendedLifetime((listener, delegate)) {}
    }
}
```

- [ ] **Étape 2 : vérifier l'échec** — `swift test --filter AgentSimulationTests 2>&1 | grep -E "error:" | head -2` → compilation (`simulate` inconnu).

- [ ] **Étape 3 : implémenter**

`AgentTypes.swift` : ajouter

```swift
/// Ce que ferait une exécution, sans rien modifier.
public struct SimulationResult: Codable, Equatable, Sendable {
    public var status: RunStatus
    public var filesToTransfer: Int
    public var bytesToTransfer: Int64
    public var deletions: Int
    public var message: String?

    public init(status: RunStatus, filesToTransfer: Int, bytesToTransfer: Int64, deletions: Int, message: String?) {
        self.status = status
        self.filesToTransfer = filesToTransfer
        self.bytesToTransfer = bytesToTransfer
        self.deletions = deletions
        self.message = message
    }

    public init(_ result: RunResult) {
        self.init(
            status: result.status, filesToTransfer: result.summary.filesTransferred,
            bytesToTransfer: result.summary.bytesTransferred, deletions: result.summary.deletions,
            message: result.summary.message
        )
    }
}
```

`AgentProtocol.swift` : `AgentRequest` + `case simulate(SyncTask)`, `case cancelSimulation(UUID)` ; `AgentResponse` + `case simulation(SimulationResult)`.

`AgentCore.swift` : ajouter la propriété `var simulations: [UUID: TaskRunning] = [:]` (après `observers`).

`Sources/SyncKit/Agent/AgentCore+Simulation.swift` :

```swift
import Foundation

extension AgentCore {
    /// Simulation hors de la file : rien n'est écrit dans l'historique ni dans `tasks.json`.
    /// Une nouvelle simulation de la même tâche remplace la précédente.
    public func simulate(_ task: SyncTask) async throws -> SimulationResult {
        if let problem = TaskValidator.problems(in: task).first(where: { $0 != .emptyName }) {
            throw AgentError.invalidTask(problem.message)
        }
        simulations[task.id]?.stop()
        let runner = makeRunner()
        simulations[task.id] = runner
        let outcome: SimulationResult
        do {
            outcome = SimulationResult(try await runner.run(task, dryRun: true, onUpdate: { _ in }))
        } catch {
            outcome = SimulationResult(status: .failed, filesToTransfer: 0, bytesToTransfer: 0, deletions: 0, message: "\(error)")
        }
        if simulations[task.id] === runner { simulations[task.id] = nil }
        return outcome
    }

    public func cancelSimulation(_ id: UUID) {
        simulations[id]?.stop()
    }
}
```

`AgentRouter.swift` : dans le `switch`, `case .simulate(let task): return .simulation(try await core.simulate(task))` et `case .cancelSimulation(let id): await core.cancelSimulation(id)`.

`AgentXPC.swift`, `AgentClient` : changer les signatures en `public func send(_ request: AgentRequest, timeout: TimeInterval? = nil)` et `func sendRaw(_ data: Data, timeout: TimeInterval? = nil)` ; dans `send`, appeler `sendRaw(payload, timeout: timeout)` ; dans `sendRaw`, remplacer `let timeout = self.timeout` par `let timeout = timeout ?? self.timeout`. Ajouter :

```swift
    /// Une simulation peut durer : 15 minutes avant d'abandonner.
    public func simulate(_ task: SyncTask) async throws -> SimulationResult {
        guard case .simulation(let result) = try await send(.simulate(task), timeout: 900) else {
            throw AgentClientError.badReply
        }
        return result
    }
```

Dans `AgentProtocolTests.testEveryRequestSurvivesEncoding`, ajouter `.simulate(makeTask("x"))` et `.cancelSimulation(id)`.

- [ ] **Étape 4 : vérifier** — `swift test --filter "AgentSimulationTests|AgentProtocolTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -2` → passent, 5 relances sans échec ; suite complète verte.

- [ ] **Étape 5 : commit et push**

```bash
git add Sources/SyncKit Tests/SyncKitTests
git commit -m "Agent : simulation hors file, annulable, délai client de 15 minutes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 4 : journal de chaque exécution

**Fichiers :** créer `Sources/SyncKit/Agent/RunLogWriter.swift`, `Tests/SyncKitTests/AgentRunLogTests.swift` ; modifier `AgentCore.swift` (paramètre `logDirectory`, `Job.logWriter`, `startJob`, `finish`, purge), `AgentPaths.swift` (`logs`), `AgentProtocol.swift`, `AgentRouter.swift`, `AgentXPC.swift` (`runLog`), `AgentTypes.swift` (`RunLogText`), `Sources/syncmacpro-agent/main.swift`, `Tests/SyncKitTests/AgentTestSupport.swift` (`lines`), `Tests/SyncKitTests/AgentCoreTests.swift` (harnais).

**Interfaces :**
- Produit : `final class RunLogWriter` (`init(url:limit:now:)`, `append(_:)`, `close()`, `static readTail(url:maxBytes:) throws -> RunLogText`) ; `struct RunLogText: Codable, Equatable, Sendable { text: String; truncated: Bool }` ; `AgentCore.init(..., logDirectory: URL? = nil, makeRunner:)` ; `AgentCore.runLog(runID:maxBytes:) throws -> RunLogText` ; `AgentRequest.runLog(runID: UUID, maxBytes: Int)` ; `AgentResponse.log(RunLogText)` ; `AgentClient.runLog(runID:maxBytes:)` ; `AgentPaths.logs`.

- [ ] **Étape 1 : écrire les tests qui échouent**

`AgentTestSupport.swift` : `FakeRunner` + `let lines = Locked<[String]>([])` et, dans `run` après l'éventuel instantané, `for line in lines.get() { onUpdate(.line(line)) }` ; `RunnerFactory` + `let lines = Locked<[String]>([])` et dans `make()` `runner.lines.set(lines.get())`.

`AgentCoreTests.swift`, `AgentHarness` : ajouter la propriété `let logs: URL` (initialisée à `directory.appendingPathComponent("logs")` dans `init`) et passer `logDirectory: logs` à `AgentCore(...)` dans `makeCore` (avant `makeRunner:`).

`Tests/SyncKitTests/AgentRunLogTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentRunLogTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testWriterTimestampsLinesAndStopsAtTheLimit() throws {
        let url = folder.appendingPathComponent("a.log")
        let writer = RunLogWriter(url: url, limit: 60, now: { Date(timeIntervalSince1970: 0) })
        writer.append("première ligne")
        writer.append("deuxième ligne qui dépasse le plafond de soixante octets")
        writer.append("jamais écrite")
        writer.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("] première ligne"))
        XCTAssertTrue(text.contains("journal tronqué"))
        XCTAssertFalse(text.contains("jamais écrite"))
    }

    func testReadTailKeepsWholeLinesAndSaysItWasCut() throws {
        let url = folder.appendingPathComponent("b.log")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let body = (1...200).map { "ligne \($0)" }.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        let tail = try RunLogWriter.readTail(url: url, maxBytes: 100)
        XCTAssertTrue(tail.truncated)
        XCTAssertTrue(tail.text.hasPrefix("ligne "), "pas de ligne coupée au début")
        XCTAssertTrue(tail.text.hasSuffix("ligne 200\n"))
        let whole = try RunLogWriter.readTail(url: url, maxBytes: 1_000_000)
        XCTAssertFalse(whole.truncated)
        XCTAssertEqual(whole.text, body)
    }

    func testEachRunGetsItsOwnLog() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.lines.set(["sending incremental file list", "photo.jpg"])
        let task = makeTask("Photos", schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        let record = try XCTUnwrap(try h.history.list(taskID: task.id).first)
        let path = try XCTUnwrap(record.logPath)
        XCTAssertTrue(path.hasPrefix(h.logs.path))
        let log = try await core.runLog(runID: record.id, maxBytes: 262_144)
        XCTAssertTrue(log.text.contains("Photos"))
        XCTAssertTrue(log.text.contains("photo.jpg"))
        XCTAssertTrue(log.text.contains("succeeded"))
        XCTAssertFalse(log.truncated)
    }

    func testMissingLogIsReportedAsUnknownRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let old = RunRecord(taskID: UUID(), taskName: "avant 3b", engine: .rsync, mode: .copy,
                            startedAt: Date(timeIntervalSince1970: 0), status: .succeeded)
        try h.history.save(old)
        do { _ = try await core.runLog(runID: old.id, maxBytes: 1_000); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .unknownRun)
        }
        do { _ = try await core.runLog(runID: UUID(), maxBytes: 1_000); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .unknownRun)
        }
    }

    func testOldLogsArePurgedWithTheHistory() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(Date(timeIntervalSince1970: 2_000_000_000))
        try FileManager.default.createDirectory(at: h.logs, withIntermediateDirectories: true)
        let old = h.logs.appendingPathComponent("ancien.log"), fresh = h.logs.appendingPathComponent("recent.log")
        try "x".write(to: old, atomically: true, encoding: .utf8)
        try "y".write(to: fresh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: h.clock.now().addingTimeInterval(-100 * 86_400)], ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes([.modificationDate: h.clock.now()], ofItemAtPath: fresh.path)
        let core = h.makeCore()
        await core.start()
        await core.tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
```

- [ ] **Étape 2 : vérifier l'échec** — `swift test --filter AgentRunLogTests 2>&1 | grep -E "error:" | head -2` → compilation (`RunLogWriter` inconnu).

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/Agent/RunLogWriter.swift` :

```swift
import Foundation

/// Journal d'une exécution : les lignes du moteur, horodatées, plafonné pour ne pas remplir le disque.
public final class RunLogWriter: @unchecked Sendable {
    public static let defaultLimit = 5_000_000

    private let lock = NSLock()
    private let handle: FileHandle?
    private let limit: Int
    private let now: @Sendable () -> Date
    private var written = 0
    private var truncated = false

    public init(url: URL, limit: Int = RunLogWriter.defaultLimit, now: @escaping @Sendable () -> Date = { Date() }) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        self.limit = limit
        self.now = now
    }

    public func append(_ line: String) {
        write("[\(Self.clock(now()))] \(line)\n")
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
    }

    private func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !truncated else { return }
        let data = Data(text.utf8)
        if written + data.count > limit {
            truncated = true
            handle.write(Data("… journal tronqué (limite de \(limit) octets atteinte)\n".utf8))
            return
        }
        handle.write(data)
        written += data.count
    }

    static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Les `maxBytes` derniers octets, sans ligne coupée au début.
    public static func readTail(url: URL, maxBytes: Int) throws -> RunLogText {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let limit = UInt64(max(1, maxBytes))
        let start = size > limit ? size - limit : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return RunLogText(text: text, truncated: start > 0)
    }
}
```

`AgentTypes.swift` : ajouter

```swift
public struct RunLogText: Codable, Equatable, Sendable {
    public var text: String
    /// Vrai si le début du journal n'est pas inclus.
    public var truncated: Bool

    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated
    }
}
```

`AgentPaths.swift` : `public var logs: URL { root.appendingPathComponent("logs") }`.

`AgentCore.swift` :
1. Propriété `let logDirectory: URL?` ; paramètre `logDirectory: URL? = nil,` dans `init` juste avant `makeRunner:` et `self.logDirectory = logDirectory`.
2. `struct Job` : ajouter `var logWriter: RunLogWriter?`.
3. Dans `startJob`, remplacer les deux lignes qui créent et enregistrent `record` par :

```swift
        var record = RunRecord(taskID: task.id, taskName: task.name, engine: engine, mode: task.mode, startedAt: now)
        var writer: RunLogWriter?
        if let logDirectory {
            let url = logDirectory.appendingPathComponent("\(record.id.uuidString).log")
            record.logPath = url.path
            let clock = self.clock
            let created = RunLogWriter(url: url, now: { clock.now() })
            created.append("Tâche « \(task.name) » — moteur \(engine.rawValue), mode \(task.mode.rawValue)")
            writer = created
        }
        try? history.save(record)
```

remplacer `jobs[task.id] = Job(task: task, runner: runner, record: record)` par `jobs[task.id] = Job(task: task, runner: runner, record: record, logWriter: writer)`, ajouter `let logWriter = writer` à côté de `let frozenTask = runTask`, et remplacer la closure `onUpdate` par :

```swift
                outcome = .success(try await runner.run(frozenTask, dryRun: false) { update in
                    switch update {
                    case .snapshot(let snapshot): Task { await core.progress(id, snapshot) }
                    case .line(let text): logWriter?.append(text)
                    case .phase: break
                    }
                })
```

4. Dans `finish`, juste après `try? history.save(job.record)` :

```swift
        job.logWriter?.append("Fin : \(status.rawValue)" + (summary.message.map { " — \($0)" } ?? ""))
        job.logWriter?.close()
```

5. Dans `purgeHistoryIfNeeded`, après `_ = try? history.purge(finishedBefore: limit)` : `if let logDirectory { removeLogs(in: logDirectory, olderThan: limit) }`, et ajouter :

```swift
    func removeLogs(in folder: URL, olderThan limit: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < limit { try? FileManager.default.removeItem(at: file) }
        }
    }

    public func runLog(runID: UUID, maxBytes: Int) throws -> RunLogText {
        guard let record = try history.record(id: runID), let path = record.logPath,
              FileManager.default.fileExists(atPath: path) else { throw AgentError.unknownRun }
        return try RunLogWriter.readTail(url: URL(fileURLWithPath: path), maxBytes: maxBytes)
    }
```

`AgentProtocol.swift` : `AgentRequest` + `case runLog(runID: UUID, maxBytes: Int)` ; `AgentResponse` + `case log(RunLogText)`. `AgentRouter.swift` : `case .runLog(let id, let maxBytes): return .log(try await core.runLog(runID: id, maxBytes: maxBytes))`. `AgentXPC.swift`, `AgentClient` :

```swift
    public func runLog(runID: UUID, maxBytes: Int = 262_144) async throws -> RunLogText {
        guard case .log(let text) = try await send(.runLog(runID: runID, maxBytes: maxBytes)) else {
            throw AgentClientError.badReply
        }
        return text
    }
```

`Sources/syncmacpro-agent/main.swift` : passer `logDirectory: paths.logs,` à `AgentCore(...)` avant `makeRunner:`.

Dans `AgentProtocolTests.testEveryRequestSurvivesEncoding`, ajouter `.runLog(runID: id, maxBytes: 10)`.

- [ ] **Étape 4 : vérifier** — `swift test --filter "AgentRunLogTests|AgentProtocolTests|AgentSchedulingTests|AgentControlTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -2` → tous passent ; suite complète verte.

- [ ] **Étape 5 : commit et push**

```bash
git add Sources Tests/SyncKitTests
git commit -m "Agent : journal de chaque exécution (plafond 5 Mo, lecture de la fin, purge à 90 jours)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 5 : `syncmacpro-ctl` passe par l'agent (add, remove, simulate, log)

**Fichiers :** modifier `Sources/SyncKit/Agent/CtlParser.swift`, `Sources/syncmacpro-ctl/main.swift`, `Tests/SyncKitTests/CtlTests.swift`.

**Interfaces :** `CtlCommand` + `.simulate(String)`, `.log(String)` ; alias `simuler`, `journal`.

- [ ] **Étape 1 : tests qui échouent** — dans `CtlParserTests`, ajouter :

```swift
    func testSimulateAndLogCommands() throws {
        XCTAssertEqual(try parse("simulate", "nuit").command, .simulate("nuit"))
        XCTAssertEqual(try parse("simuler", "nuit").command, .simulate("nuit"))
        XCTAssertEqual(try parse("log", "nuit").command, .log("nuit"))
        XCTAssertEqual(try parse("journal", "nuit").command, .log("nuit"))
        XCTAssertThrowsError(try parse("log"))
    }
```

Exécuter `swift test --filter CtlParserTests 2>&1 | grep -E "error:" | head -2` → compilation (`.simulate` inconnu).

- [ ] **Étape 2 : implémenter**

`CtlParser.swift` : `CtlCommand` + `case simulate(String), log(String)` ; dans `aliases` : `"simuler": "simulate", "journal": "log"` ; dans le `switch name` : `case "simulate": return invocation(.simulate(try single()))` et `case "log": return invocation(.log(try single()))` ; dans `usage`, ajouter les lignes `  simulate <tâche>               ce que ferait la tâche, sans rien modifier` et `  log <tâche>                    journal de la dernière exécution`.

`Sources/syncmacpro-ctl/main.swift` : remplacer les cas `.add` et `.remove` par :

```swift
    case .add(let new):
        var task = SyncTask(
            name: new.name, source: new.source, destination: new.destination, mode: new.mode, schedule: new.schedule
        )
        task.conditions.requiresACPower = new.requiresACPower
        do {
            try await client.perform(.saveTask(task))
            print("Tâche « \(task.name) » ajoutée (\(CtlFormatter.scheduleDescription(task.schedule))).")
        } catch AgentClientError.unreachable {
            // Sans agent (pas encore installé) : on écrit le fichier, l'agent le lira au démarrage.
            if let problem = TaskValidator.problems(in: task).first { fail(problem.message) }
            try TaskStore(url: paths.tasks).upsert(task)
            print("Tâche « \(task.name) » ajoutée dans tasks.json (agent injoignable : il la lira au démarrage).")
        }

    case .remove(let text):
        do {
            let task = try await resolve(text)
            try await client.perform(.removeTask(task.id))
            print("Tâche « \(task.name) » supprimée.")
        } catch AgentClientError.unreachable {
            let store = TaskStore(url: paths.tasks)
            let task = try TaskReference.resolve(text, in: try store.load())
            try store.remove(id: task.id)
            print("Tâche « \(task.name) » supprimée de tasks.json (agent injoignable).")
        }

    case .simulate(let text):
        let task = try await resolve(text)
        print("Simulation de « \(task.name) »…")
        let result = try await client.simulate(task)
        print("\(CtlFormatter.statusLabel(result.status)) : \(result.filesToTransfer) fichier(s) à transférer "
            + "(\(Formatting.bytes(result.bytesToTransfer))), \(result.deletions) suppression(s)."
            + (result.message.map { "\n\($0)" } ?? ""))

    case .log(let text):
        let task = try await resolve(text)
        guard let last = try await client.history(taskID: task.id, limit: 1).first else {
            fail("« \(task.name) » n'a encore jamais tourné.")
        }
        let log = try await client.runLog(runID: last.id)
        if log.truncated { print("(début du journal non affiché)") }
        print(log.text, terminator: "")
```

- [ ] **Étape 3 : vérifier** — `swift test --filter CtlParserTests 2>&1 | grep -E "error:|Executed .* tests" | tail -1` → passent ; `swift build 2>&1 | grep -E "error|Build" | tail -2` → compilation propre. (Les commandes sont essayées pour de vrai à la tâche 12.)

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests/SyncKitTests
git commit -m "ctl : ajout et suppression par l'agent, commandes simulate et log" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 6 : l'app parle à l'agent pour éditer (AgentModel)

**Fichiers :** modifier `Sources/SyncMacProUI/Agent/AgentConnecting.swift`, `Sources/SyncMacProUI/Agent/AgentModel.swift`, `Tests/SyncMacProUITests/FakeAgent.swift` ; créer `Tests/SyncMacProUITests/AgentModelEditingTests.swift`.

**Interfaces :**
- Consomme : `AgentClient.simulate(_:)`, `AgentClient.runLog(runID:maxBytes:)` (tâches 3, 4).
- Produit : `AgentConnecting.simulate(_:)`, `AgentConnecting.runLog(runID:)` ; `enum SimulationOutcome { finished(SimulationResult), failed(String) }`, `enum LogOutcome { loaded(RunLogText), missing, failed(String) }` ; `AgentModel.saveTask(_:) async -> String?`, `setEnabled(_:_:)`, `removeTask(_:)`, `simulate(_:) async -> SimulationOutcome`, `cancelSimulation(_:)`, `runLog(_:) async -> LogOutcome`.

- [ ] **Étape 1 : doubles et tests qui échouent**

`FakeAgent.swift` : ajouter les propriétés privées `_simulation: Result<SimulationResult, Error> = .success(SimulationResult(status: .succeeded, filesToTransfer: 3, bytesToTransfer: 1_000, deletions: 0, message: nil))`, `_log: Result<RunLogText, Error> = .success(RunLogText(text: "ligne\n", truncated: false))`, `_simulated: [SyncTask] = []`, `_logRequests: [UUID] = []` ; les réglages `func setSimulation(_ result: Result<SimulationResult, Error>) { locked { _simulation = result } }` et `func setLog(_ result: Result<RunLogText, Error>) { locked { _log = result } }` ; les lectures `var simulated: [SyncTask] { locked { _simulated } }` et `var logRequests: [UUID] { locked { _logRequests } }` ; et :

```swift
    func simulate(_ task: SyncTask) async throws -> SimulationResult {
        let result = locked { () -> Result<SimulationResult, Error> in
            _simulated.append(task)
            return _simulation
        }
        return try result.get()
    }

    func runLog(runID: UUID) async throws -> RunLogText {
        let result = locked { () -> Result<RunLogText, Error> in
            _logRequests.append(runID)
            return _log
        }
        return try result.get()
    }
```

`Tests/SyncMacProUITests/AgentModelEditingTests.swift` :

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class AgentModelEditingTests: XCTestCase {
    var agent: FakeAgent!
    var model: AgentModel!
    let task = SyncTask(name: "Photos", source: .local(path: "/a"), destination: .local(path: "/b"))

    override func setUp() async throws {
        agent = FakeAgent()
        agent.setTasks([task])
        agent.setStatus(.success(makeStatus([AgentTaskInfo(id: task.id, name: "Photos", state: .idle)])))
        model = AgentModel(agent: agent, sleeper: ManualSleeper())
        model.start()
        _ = await eventually { self.model.connection == .connected && self.model.tasks[self.task.id] != nil }
    }

    override func tearDown() async throws { model.shutdown() }

    func testSaveSendsTheTaskThenRefreshes() async {
        let before = agent.statusCalls
        let message = await model.saveTask(task)
        XCTAssertNil(message)
        XCTAssertEqual(agent.performed.last, .saveTask(task))
        XCTAssertEqual(agent.statusCalls, before + 1)
    }

    func testRefusalIsReturnedToTheEditorNotAlerted() async {
        agent.setPerformError(AgentClientError.agent(.invalidTask("Donnez un nom à la tâche.")))
        let message = await model.saveTask(task)
        XCTAssertEqual(message, "Donnez un nom à la tâche.")
        XCTAssertNil(model.alertMessage)
    }

    func testToggleSavesACopyWithTheNewFlag() async {
        await model.setEnabled(task.id, false)
        guard case .saveTask(let saved)? = agent.performed.last else { return XCTFail("saveTask attendu") }
        XCTAssertFalse(saved.isEnabled)
        XCTAssertEqual(saved.id, task.id)
    }

    func testRemoveFailureShowsAnAlert() async {
        agent.setPerformError(AgentClientError.agent(.alreadyRunning))
        await model.removeTask(task.id)
        XCTAssertEqual(agent.performed.last, .removeTask(task.id))
        XCTAssertEqual(model.alertMessage, AgentError.alreadyRunning.errorDescription)
    }

    func testSimulationOutcomes() async {
        let ok = await model.simulate(task)
        XCTAssertEqual(ok, .finished(SimulationResult(status: .succeeded, filesToTransfer: 3, bytesToTransfer: 1_000, deletions: 0, message: nil)))
        agent.setSimulation(.failure(AgentClientError.unreachable))
        let failed = await model.simulate(task)
        guard case .failed = failed else { return XCTFail("échec attendu") }
        await model.cancelSimulation(task.id)
        XCTAssertEqual(agent.performed.last, .cancelSimulation(task.id))
    }

    func testRunLogOutcomes() async {
        let id = UUID()
        let loaded = await model.runLog(id)
        XCTAssertEqual(loaded, .loaded(RunLogText(text: "ligne\n", truncated: false)))
        agent.setLog(.failure(AgentClientError.agent(.unknownRun)))
        let missing = await model.runLog(id)
        XCTAssertEqual(missing, .missing)
        agent.setLog(.failure(AgentClientError.badReply))
        let failed = await model.runLog(id)
        guard case .failed = failed else { return XCTFail("échec attendu") }
        XCTAssertEqual(agent.logRequests, [id, id, id])
    }
}
```

- [ ] **Étape 2 : vérifier l'échec** — `swift test --filter AgentModelEditingTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 3 : implémenter**

`AgentConnecting.swift` : ajouter au protocole `func simulate(_ task: SyncTask) async throws -> SimulationResult` et `func runLog(runID: UUID) async throws -> RunLogText` ; dans `extension AgentClient: AgentConnecting`, ajouter :

```swift
    public func runLog(runID: UUID) async throws -> RunLogText {
        try await runLog(runID: runID, maxBytes: 262_144)
    }
```

(`simulate(_:)` existe déjà dans `AgentClient`). Dans `UnavailableAgent`, ajouter les deux méthodes qui lèvent `AgentClientError.unreachable`. Ajouter à la fin du fichier :

```swift
public enum SimulationOutcome: Equatable, Sendable {
    case finished(SimulationResult)
    case failed(String)
}

public enum LogOutcome: Equatable, Sendable {
    case loaded(RunLogText)
    /// Exécution antérieure au journal, ou fichier purgé.
    case missing
    case failed(String)
}
```

`AgentModel.swift` : dans la classe, avant `static func describe`, ajouter :

```swift
    // MARK: tâches

    /// `nil` si l'agent a enregistré la tâche ; sinon le message, affiché dans l'éditeur (qui reste ouvert).
    public func saveTask(_ task: SyncTask) async -> String? {
        do {
            try await agent.perform(.saveTask(task))
            await refreshNow()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard var task = tasks[id], task.isEnabled != enabled else { return }
        task.isEnabled = enabled
        if let message = await saveTask(task) { alertMessage = message }
    }

    public func removeTask(_ id: UUID) async {
        await act(on: id) { try await $0.perform(.removeTask(id)) }
    }

    public func simulate(_ task: SyncTask) async -> SimulationOutcome {
        do { return .finished(try await agent.simulate(task)) } catch { return .failed(Self.describe(error)) }
    }

    public func cancelSimulation(_ id: UUID) async {
        try? await agent.perform(.cancelSimulation(id))
    }

    public func runLog(_ runID: UUID) async -> LogOutcome {
        do {
            return .loaded(try await agent.runLog(runID: runID))
        } catch AgentClientError.agent(.unknownRun) {
            return .missing
        } catch {
            return .failed(Self.describe(error))
        }
    }
```

- [ ] **Étape 4 : vérifier** — `swift test --filter "AgentModelEditingTests|AgentModelTests|ReviewFixTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -2` → passent, 5 relances stables.

- [ ] **Étape 5 : commit et push**

```bash
git add Sources/SyncMacProUI Tests/SyncMacProUITests
git commit -m "Interface : enregistrer, supprimer, simuler et lire le journal depuis le modèle" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 7 : brouillon de tâche, planification, dossiers réseau, modèles

**Fichiers :** créer `Sources/SyncMacProUI/Editing/TaskDraft.swift`, `Sources/SyncMacProUI/Editing/EndpointResolver.swift` ; tester `Tests/SyncMacProUITests/TaskDraftTests.swift`.

**Interfaces :**
- Produit : `struct EndpointResolver` (`volumeInfo`, `.system`, `.localOnly`, `endpoint(forPath:)`) ; `enum EditorStep: Int, CaseIterable` (`endpoints`, `mode`, `options`, `schedule`, `summary`) ; `extension TaskProblem { var step: EditorStep }` ; `enum SideKind` (`folder`, `cloud`) ; `struct SideDraft` ; `enum ScheduleKind` ; `struct ScheduleDraft` ; `enum TaskTemplate: CaseIterable, Identifiable` (`copyToNAS`, `syncTwoFolders`, `backupToDrive`) ; `struct TaskDraft` (`init(id:)`, `init(task:)`, `duplicate(of:suffix:)`, `template(_:)`, `task(resolver:)`, `problems(resolver:)`, `problems(for:resolver:)`, `excludesText`, `bandwidthText`, `retentionText`, `maxTransferText`, `suggestedName()`, `fillNameIfNeeded()`).

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncMacProUITests/TaskDraftTests.swift` :

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

final class TaskDraftTests: XCTestCase {
    let nas = EndpointResolver { url in
        url.path.hasPrefix("/Volumes/NAS")
            ? .init(isLocal: false, remountURL: URL(string: "smb://nas/partage"))
            : .init(isLocal: true, remountURL: nil)
    }

    func fullTask() -> SyncTask {
        var options = TaskOptions(excludes: ["*.tmp", ".DS_Store"], bandwidthLimitKBps: 500, verifyAfterCopy: true,
                                  deleteThresholdPercent: 40, archiveFolder: "_OLD", retentionDays: 30, maxTransferGB: 750)
        options.extraArguments = ["--checksum"]
        return SyncTask(name: "Photos", source: .local(path: "/Users/moi/Photos"),
                        destination: .cloud(remote: "drive", path: "Sauvegardes"), sourceItems: ["2024"],
                        mode: .mirror, options: options, schedule: .weekdays(days: [2, 6], hour: 8, minute: 30),
                        notifications: .errorsOnly,
                        conditions: TaskConditions(requiresACPower: true, requiresNetwork: true, allowedHours: HourRange(start: 22, end: 6)),
                        isEnabled: false)
    }

    func testRoundTripKeepsEveryField() {
        let task = fullTask()
        XCTAssertEqual(TaskDraft(task: task).task(resolver: .localOnly), task)
    }

    func testFolderOnANetworkVolumeBecomesANetworkEndpoint() {
        var draft = TaskDraft()
        draft.source.path = "/Users/moi/Photos"
        draft.destination.path = "/Volumes/NAS/Photos"
        let task = draft.task(resolver: nas)
        XCTAssertEqual(task.source, .local(path: "/Users/moi/Photos"))
        XCTAssertEqual(task.destination, .network(url: "smb://nas/partage", mountPath: "/Volumes/NAS/Photos"))
        XCTAssertEqual(TaskDraft(task: task).destination, SideDraft(kind: .folder, path: "/Volumes/NAS/Photos"))
    }

    func testDuplicateGetsANewIdentityAndName() {
        let task = fullTask()
        let copy = TaskDraft.duplicate(of: task, suffix: "(copie)")
        XCTAssertNotEqual(copy.id, task.id)
        XCTAssertEqual(copy.name, "Photos (copie)")
        XCTAssertEqual(copy.mode, task.mode)
        XCTAssertEqual(copy.options, task.options)
    }

    func testTemplates() {
        let nasCopy = TaskDraft.template(.copyToNAS)
        XCTAssertEqual(nasCopy.mode, .copy)
        XCTAssertEqual(nasCopy.scheduleDraft.schedule, .daily(hour: 3, minute: 0))
        XCTAssertTrue(nasCopy.conditions.requiresNetwork)
        let sync = TaskDraft.template(.syncTwoFolders)
        XCTAssertEqual(sync.mode, .bidirectional)
        XCTAssertEqual(sync.scheduleDraft.schedule, .everyMinutes(60))
        let drive = TaskDraft.template(.backupToDrive)
        XCTAssertEqual(drive.destination, SideDraft(kind: .cloud, path: "SyncMacPro", remote: "drive"))
        XCTAssertEqual(drive.options.maxTransferGB, 750)
        XCTAssertEqual(TaskTemplate.allCases.count, 3)
    }

    func testScheduleDraftRoundTrips() {
        let schedules: [Schedule] = [.manual, .whenAvailable, .everyMinutes(15), .daily(hour: 3, minute: 5),
                                     .weekdays(days: [1, 7], hour: 22, minute: 0)]
        for schedule in schedules { XCTAssertEqual(ScheduleDraft(schedule).schedule, schedule) }
        var draft = ScheduleDraft(.manual)
        draft.kind = .daily
        XCTAssertEqual(draft.schedule, .daily(hour: 3, minute: 0), "valeurs par défaut sensées")
    }

    func testProblemsAreSortedByStep() {
        var draft = TaskDraft()
        XCTAssertEqual(draft.problems(for: .endpoints, resolver: .localOnly), [.missingSource, .missingDestination])
        XCTAssertEqual(draft.problems(for: .mode, resolver: .localOnly), [])
        XCTAssertEqual(draft.problems(for: .summary, resolver: .localOnly), [.emptyName])
        draft.source.path = "/a"
        draft.destination.path = "/a/b"
        XCTAssertEqual(draft.problems(for: .endpoints, resolver: .localOnly), [.nestedFolders])
        draft.destination.path = "/b"
        draft.scheduleDraft.kind = .weekdays
        draft.scheduleDraft.days = []
        XCTAssertEqual(draft.problems(for: .schedule, resolver: .localOnly), [.invalidSchedule])
    }

    func testTextFields() {
        var draft = TaskDraft()
        draft.excludesText = "*.tmp\n\n  cache/  \n"
        XCTAssertEqual(draft.options.excludes, ["*.tmp", "cache/"])
        draft.bandwidthText = "200"
        XCTAssertEqual(draft.options.bandwidthLimitKBps, 200)
        draft.bandwidthText = "abc"
        XCTAssertNil(draft.options.bandwidthLimitKBps)
        draft.bandwidthText = "0"
        XCTAssertNil(draft.options.bandwidthLimitKBps)
        draft.maxTransferText = "750"
        XCTAssertEqual(draft.options.maxTransferGB, 750)
        draft.retentionText = "30"
        XCTAssertEqual(draft.retentionText, "30")
    }

    func testNameIsSuggestedOnlyWhenEmpty() {
        var draft = TaskDraft()
        draft.source.path = "/Users/moi/Photos"
        draft.destination = SideDraft(kind: .cloud, path: "Sauvegardes", remote: "drive")
        draft.fillNameIfNeeded()
        XCTAssertEqual(draft.name, "Photos → drive:Sauvegardes")
        draft.name = "Mon nom"
        draft.fillNameIfNeeded()
        XCTAssertEqual(draft.name, "Mon nom")
    }
}
```

- [ ] **Étape 2 : vérifier l'échec** — `swift test --filter TaskDraftTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 3 : implémenter**

`Sources/SyncMacProUI/Editing/EndpointResolver.swift` :

```swift
import Foundation
import SyncKit

/// Transforme un chemin choisi en `Endpoint` : un dossier sur un partage réseau monté devient une destination « réseau »
/// (on garde l'adresse de remontage). La lecture du volume est injectable pour les tests.
public struct EndpointResolver: Sendable {
    public struct VolumeInfo: Equatable, Sendable {
        public var isLocal: Bool
        public var remountURL: URL?

        public init(isLocal: Bool, remountURL: URL?) {
            self.isLocal = isLocal
            self.remountURL = remountURL
        }
    }

    public let volumeInfo: @Sendable (URL) -> VolumeInfo

    public init(volumeInfo: @escaping @Sendable (URL) -> VolumeInfo) {
        self.volumeInfo = volumeInfo
    }

    public static let system = EndpointResolver { url in
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeURLForRemountingKey])
        return VolumeInfo(isLocal: values?.volumeIsLocal ?? true, remountURL: values?.volumeURLForRemounting)
    }

    public static let localOnly = EndpointResolver { _ in VolumeInfo(isLocal: true, remountURL: nil) }

    public func endpoint(forPath path: String) -> Endpoint {
        let info = volumeInfo(URL(fileURLWithPath: path))
        if !info.isLocal, let remount = info.remountURL {
            return .network(url: remount.absoluteString, mountPath: path)
        }
        return .local(path: path)
    }
}
```

`Sources/SyncMacProUI/Editing/TaskDraft.swift` :

```swift
import Foundation
import SyncKit

public enum EditorStep: Int, CaseIterable, Sendable {
    case endpoints, mode, options, schedule, summary
}

extension TaskProblem {
    /// L'étape de l'éditeur où l'utilisateur corrige ce problème.
    public var step: EditorStep {
        switch self {
        case .missingSource, .missingDestination, .sameSourceAndDestination, .nestedFolders: return .endpoints
        case .engineMismatch: return .mode
        case .invalidThreshold: return .options
        case .invalidSchedule: return .schedule
        case .emptyName: return .summary
        }
    }
}

public enum SideKind: String, CaseIterable, Sendable {
    case folder, cloud
}

/// Un côté de la tâche tel que l'utilisateur le saisit.
public struct SideDraft: Equatable, Sendable {
    public var kind: SideKind
    public var path: String
    public var remote: String

    public init(kind: SideKind = .folder, path: String = "", remote: String = "") {
        self.kind = kind
        self.path = path
        self.remote = remote
    }

    init(_ endpoint: Endpoint) {
        switch endpoint {
        case .local(let path): self.init(kind: .folder, path: path)
        case .network(_, let mountPath): self.init(kind: .folder, path: mountPath)
        case .cloud(let remote, let path): self.init(kind: .cloud, path: path, remote: remote)
        }
    }

    func endpoint(_ resolver: EndpointResolver) -> Endpoint {
        let path = self.path.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .folder: return path.isEmpty ? .local(path: "") : resolver.endpoint(forPath: path)
        case .cloud: return .cloud(remote: remote.trimmingCharacters(in: .whitespaces), path: path)
        }
    }
}

public enum ScheduleKind: String, CaseIterable, Sendable {
    case manual, daily, weekdays, everyMinutes, whenAvailable
}

/// Planification éditable : chaque genre garde ses réglages quand on passe de l'un à l'autre.
public struct ScheduleDraft: Equatable, Sendable {
    public var kind: ScheduleKind = .manual
    public var hour = 3
    public var minute = 0
    public var days: Set<Int> = [2, 3, 4, 5, 6]
    public var interval = 60

    public init() {}

    public init(_ schedule: Schedule) {
        self.init()
        switch schedule {
        case .manual: kind = .manual
        case .whenAvailable: kind = .whenAvailable
        case .everyMinutes(let minutes):
            kind = .everyMinutes
            interval = minutes
        case .daily(let hour, let minute):
            kind = .daily
            self.hour = hour
            self.minute = minute
        case .weekdays(let days, let hour, let minute):
            kind = .weekdays
            self.days = days
            self.hour = hour
            self.minute = minute
        }
    }

    public var schedule: Schedule {
        switch kind {
        case .manual: return .manual
        case .whenAvailable: return .whenAvailable
        case .everyMinutes: return .everyMinutes(interval)
        case .daily: return .daily(hour: hour, minute: minute)
        case .weekdays: return .weekdays(days: days, hour: hour, minute: minute)
        }
    }
}

public enum TaskTemplate: String, CaseIterable, Identifiable, Sendable {
    case copyToNAS, syncTwoFolders, backupToDrive
    public var id: String { rawValue }
}

/// Brouillon d'une tâche dans l'éditeur : tout ce que l'utilisateur modifie, sans vue ni agent.
public struct TaskDraft: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var source: SideDraft
    public var destination: SideDraft
    /// Conservés tels quels : ils seront modifiables avec la copie à deux panneaux.
    public var sourceItems: [String]
    public var mode: SyncMode
    public var options: TaskOptions
    public var conditions: TaskConditions
    public var scheduleDraft: ScheduleDraft
    public var notifications: NotificationPolicy
    public var isEnabled: Bool

    public init(id: UUID = UUID()) {
        self.id = id
        name = ""
        source = SideDraft()
        destination = SideDraft()
        sourceItems = []
        mode = .copy
        options = TaskOptions()
        conditions = TaskConditions()
        scheduleDraft = ScheduleDraft()
        notifications = .always
        isEnabled = true
    }

    public init(task: SyncTask) {
        id = task.id
        name = task.name
        source = SideDraft(task.source)
        destination = SideDraft(task.destination)
        sourceItems = task.sourceItems
        mode = task.mode
        options = task.options
        conditions = task.conditions
        scheduleDraft = ScheduleDraft(task.schedule)
        notifications = task.notifications
        isEnabled = task.isEnabled
    }

    public static func duplicate(of task: SyncTask, suffix: String) -> TaskDraft {
        var draft = TaskDraft(task: task)
        draft.id = UUID()
        draft.name = "\(task.name) \(suffix)"
        return draft
    }

    public static func template(_ template: TaskTemplate) -> TaskDraft {
        var draft = TaskDraft()
        switch template {
        case .copyToNAS:
            draft.mode = .copy
            draft.scheduleDraft = ScheduleDraft(.daily(hour: 3, minute: 0))
            draft.conditions.requiresNetwork = true
            draft.notifications = .errorsOnly
        case .syncTwoFolders:
            draft.mode = .bidirectional
            draft.scheduleDraft = ScheduleDraft(.everyMinutes(60))
        case .backupToDrive:
            draft.mode = .copy
            draft.destination = SideDraft(kind: .cloud, path: "SyncMacPro", remote: "drive")
            draft.scheduleDraft = ScheduleDraft(.daily(hour: 2, minute: 0))
            draft.conditions.requiresNetwork = true
            draft.options.maxTransferGB = 750
            draft.notifications = .errorsOnly
        }
        return draft
    }

    public func task(resolver: EndpointResolver = .system) -> SyncTask {
        SyncTask(
            id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source.endpoint(resolver), destination: destination.endpoint(resolver), sourceItems: sourceItems,
            mode: mode, options: options, schedule: scheduleDraft.schedule, notifications: notifications,
            conditions: conditions, isEnabled: isEnabled
        )
    }

    public func problems(resolver: EndpointResolver = .system) -> [TaskProblem] {
        TaskValidator.problems(in: task(resolver: resolver))
    }

    public func problems(for step: EditorStep, resolver: EndpointResolver = .system) -> [TaskProblem] {
        problems(resolver: resolver).filter { $0.step == step }
    }

    // MARK: champs texte

    /// Une exclusion par ligne ; lignes vides ignorées.
    public var excludesText: String {
        get { options.excludes.joined(separator: "\n") }
        set {
            options.excludes = newValue.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    public var bandwidthText: String {
        get { options.bandwidthLimitKBps.map(String.init) ?? "" }
        set { options.bandwidthLimitKBps = Self.positive(newValue) }
    }

    public var retentionText: String {
        get { options.retentionDays.map(String.init) ?? "" }
        set { options.retentionDays = Self.positive(newValue) }
    }

    public var maxTransferText: String {
        get { options.maxTransferGB.map(String.init) ?? "" }
        set { options.maxTransferGB = Self.positive(newValue) }
    }

    static func positive(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    // MARK: nom

    /// « Photos → drive:Sauvegardes ».
    public func suggestedName() -> String {
        func label(_ side: SideDraft) -> String {
            switch side.kind {
            case .folder:
                let last = URL(fileURLWithPath: side.path).lastPathComponent
                return last.isEmpty || last == "/" ? side.path : last
            case .cloud:
                return side.path.isEmpty ? side.remote : "\(side.remote):\(side.path)"
            }
        }
        return "\(label(source)) → \(label(destination))"
    }

    public mutating func fillNameIfNeeded() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = suggestedName() }
    }
}
```

- [ ] **Étape 4 : vérifier** — `swift test --filter TaskDraftTests 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | tail -4` → 8 tests passent.

- [ ] **Étape 5 : commit et push**

```bash
git add Sources/SyncMacProUI/Editing Tests/SyncMacProUITests/TaskDraftTests.swift
git commit -m "Interface : brouillon de tâche, planification éditable, dossiers réseau, modèles" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 8 : phrases de l'éditeur (`TaskSummaryText`) et chaînes de 3b

**Fichiers :** créer `Sources/SyncMacProUI/Editing/TaskSummaryText.swift`, `Tests/SyncMacProUITests/TaskSummaryTextTests.swift` ; modifier les deux `Localizable.strings` et `Tests/SyncMacProUITests/StringsCompletenessTests.swift` (préfixes).

**Interfaces :** produit `struct TaskSummaryText(localizer:calendar:now:)` : `endpointLabel(_:)`, `sentence(for:)`, `warnings(for:)`, `nextRun(for:)`, `simulation(_:)`, `deletionsWarning(_:)`, `problem(_:)`, `modeTitle(_:)`, `modeDescription(_:)`, `modeWarning(_:)`, `modeNote(_:)`, `scheduleKind(_:)`, `notification(_:)`, `templateTitle(_:)`, `templateDescription(_:)`, `stepTitle(_:)`.

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncMacProUITests/TaskSummaryTextTests.swift` :

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

final class TaskSummaryTextTests: XCTestCase {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    func text(_ language: String) -> TaskSummaryText {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10))!
        return TaskSummaryText(localizer: Localizer(language: language), calendar: calendar, now: now)
    }

    func task(_ mode: SyncMode, schedule: Schedule = .daily(hour: 3, minute: 0)) -> SyncTask {
        SyncTask(name: "n", source: .local(path: "/Users/moi/Photos"), destination: .network(url: "smb://nas/p", mountPath: "/Volumes/NAS/Archives"),
                 mode: mode, schedule: schedule)
    }

    func testSentences() {
        XCTAssertEqual(text("fr").sentence(for: task(.copy)),
                       "Copie les nouveautés de « Photos » vers « Archives », tous les jours à 03:00. Rien n’est supprimé.")
        XCTAssertEqual(text("fr").sentence(for: task(.mirror, schedule: .manual)),
                       "Rend « Archives » identique à « Photos », à la demande.")
        XCTAssertEqual(text("en").sentence(for: task(.copy)),
                       "Copies what is new or changed from “Photos” to “Archives”, every day at 03:00. Nothing is deleted.")
        XCTAssertTrue(text("fr").sentence(for: task(.verify)).hasSuffix("Rien n’est modifié."))
    }

    func testWarningsForDestructiveModesAndDisabledTasks() {
        XCTAssertEqual(text("fr").warnings(for: task(.copy)), [])
        XCTAssertEqual(text("fr").warnings(for: task(.mirror)).count, 1)
        XCTAssertTrue(text("fr").warnings(for: task(.mirror))[0].contains("_ARCHIVE"))
        var disabled = task(.move)
        disabled.isEnabled = false
        XCTAssertEqual(text("fr").warnings(for: disabled).count, 2)
    }

    func testEndpointLabels() {
        XCTAssertEqual(text("fr").endpointLabel(.local(path: "/")), "/")
        XCTAssertEqual(text("fr").endpointLabel(.cloud(remote: "drive", path: "")), "drive:")
        XCTAssertEqual(text("fr").endpointLabel(.cloud(remote: "drive", path: "a/b")), "drive:a/b")
    }

    func testNextRun() {
        XCTAssertEqual(text("fr").nextRun(for: task(.copy)), "demain à 03:00")
        XCTAssertEqual(text("fr").nextRun(for: task(.copy, schedule: .manual)), "Sans échéance")
        XCTAssertEqual(text("fr").nextRun(for: task(.copy, schedule: .whenAvailable)), "Dès que disponible")
    }

    func testSimulationTexts() {
        let ok = SimulationResult(status: .succeeded, filesToTransfer: 12, bytesToTransfer: 5_242_880, deletions: 3, message: nil)
        XCTAssertEqual(text("fr").simulation(ok), "12 fichier(s) à transférer (5,0 Mo), 3 suppression(s).")
        XCTAssertEqual(text("fr").deletionsWarning(ok), "Attention : 3 fichier(s) seraient supprimés.")
        XCTAssertNil(text("fr").deletionsWarning(SimulationResult(status: .succeeded, filesToTransfer: 1, bytesToTransfer: 1, deletions: 0, message: nil)))
        let failed = SimulationResult(status: .failed, filesToTransfer: 0, bytesToTransfer: 0, deletions: 0, message: "source introuvable")
        XCTAssertEqual(text("fr").simulation(failed), "La simulation a échoué : source introuvable")
        let stopped = SimulationResult(status: .stopped, filesToTransfer: 0, bytesToTransfer: 0, deletions: 0, message: nil)
        XCTAssertEqual(text("en").simulation(stopped), "Simulation cancelled.")
    }

    func testEveryProblemModeTemplateAndStepHasAText() {
        for language in ["fr", "en"] {
            let t = text(language)
            for problem in TaskProblem.allCases { XCTAssertFalse(t.problem(problem).hasPrefix("⚠︎"), problem.rawValue) }
            for mode in SyncMode.allCases {
                XCTAssertFalse(t.modeDescription(mode).hasPrefix("⚠︎"))
                XCTAssertFalse(t.modeTitle(mode).hasPrefix("⚠︎"))
            }
            for template in TaskTemplate.allCases {
                XCTAssertFalse(t.templateTitle(template).hasPrefix("⚠︎"))
                XCTAssertFalse(t.templateDescription(template).hasPrefix("⚠︎"))
            }
            for step in EditorStep.allCases { XCTAssertFalse(t.stepTitle(step).hasPrefix("⚠︎")) }
            for kind in ScheduleKind.allCases { XCTAssertFalse(t.scheduleKind(kind).hasPrefix("⚠︎")) }
            for policy in NotificationPolicy.allCases { XCTAssertFalse(t.notification(policy).hasPrefix("⚠︎")) }
        }
        XCTAssertNotNil(text("fr").modeWarning(.mirror))
        XCTAssertNil(text("fr").modeWarning(.copy))
        XCTAssertNotNil(text("fr").modeNote(.versioned))
        XCTAssertNil(text("fr").modeNote(.mirror))
    }
}
```

Dans `StringsCompletenessTests.testEveryKeyUsedInTheCodeExists`, ajouter aux préfixes de l'expression régulière : `editor|notify|warning|simulation|problem|template|tasks|log`.

- [ ] **Étape 2 : vérifier l'échec** — `swift test --filter TaskSummaryTextTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 3 : implémenter**

`Sources/SyncMacProUI/Editing/TaskSummaryText.swift` :

```swift
import Foundation
import SyncKit

/// Les textes de l'éditeur : résumé en clair, avertissements, simulation, noms des modes, des étapes et des modèles.
public struct TaskSummaryText {
    public let localizer: Localizer
    public let calendar: Calendar
    public let now: Date

    public init(localizer: Localizer = .system, calendar: Calendar = .current, now: Date = Date()) {
        self.localizer = localizer
        self.calendar = calendar
        self.now = now
    }

    private var cards: CardText { CardText(localizer: localizer, calendar: calendar, now: now) }

    /// Dernier dossier du chemin, ou « remote:chemin ».
    public func endpointLabel(_ endpoint: Endpoint) -> String {
        switch endpoint {
        case .cloud(let remote, let path):
            return path.isEmpty ? "\(remote):" : "\(remote):\(path)"
        case .local, .network:
            let path = endpoint.filesystemPath ?? ""
            let last = URL(fileURLWithPath: path).lastPathComponent
            return last.isEmpty || last == "/" ? path : last
        }
    }

    public func sentence(for task: SyncTask) -> String {
        let source = endpointLabel(task.source), destination = endpointLabel(task.destination)
        let when: String
        switch task.schedule {
        case .manual:
            when = localizer.text("summary.when.manual")
        case .weekdays:
            when = cards.schedule(task.schedule)
        case .daily, .everyMinutes, .whenAvailable:
            let schedule = cards.schedule(task.schedule)
            when = schedule.prefix(1).lowercased() + schedule.dropFirst()
        }
        var text: String
        switch task.mode {
        case .copy: text = localizer.format("summary.sentence.copy", source, destination, when)
        case .mirror: text = localizer.format("summary.sentence.mirror", source, destination, when)
        case .bidirectional: text = localizer.format("summary.sentence.bidirectional", source, destination, when)
        case .move: text = localizer.format("summary.sentence.move", source, destination, when)
        case .versioned: text = localizer.format("summary.sentence.versioned", source, destination, when)
        case .verify: text = localizer.format("summary.sentence.verify", source, destination, when)
        }
        switch task.mode {
        case .copy, .versioned: text += " " + localizer.text("summary.safe")
        case .verify: text += " " + localizer.text("summary.readonly")
        case .mirror, .bidirectional, .move: break
        }
        return text
    }

    public func warnings(for task: SyncTask) -> [String] {
        var list: [String] = []
        switch task.mode {
        case .mirror: list.append(localizer.format("warning.mirror", task.options.archiveFolder))
        case .bidirectional: list.append(localizer.text("warning.bidirectional"))
        case .move: list.append(localizer.text("warning.move"))
        case .copy, .versioned, .verify: break
        }
        if !task.isEnabled { list.append(localizer.text("warning.disabled")) }
        return list
    }

    public func nextRun(for task: SyncTask) -> String {
        if task.schedule == .whenAvailable { return localizer.text("schedule.whenAvailable") }
        return cards.nextRun(Scheduler.nextDue(for: task.schedule, after: nil, now: now, calendar: calendar))
    }

    public func simulation(_ result: SimulationResult) -> String {
        switch result.status {
        case .succeeded:
            return localizer.format(
                "simulation.result", result.filesToTransfer, localizer.bytes(result.bytesToTransfer), result.deletions
            )
        case .stopped:
            return localizer.text("simulation.stopped")
        default:
            return localizer.format("simulation.failed", result.message ?? cards.status(result.status))
        }
    }

    /// Mis en avant quand la simulation prévoit des suppressions.
    public func deletionsWarning(_ result: SimulationResult) -> String? {
        guard result.status == .succeeded, result.deletions > 0 else { return nil }
        return localizer.format("simulation.deletions", result.deletions)
    }

    public func problem(_ problem: TaskProblem) -> String {
        switch problem {
        case .emptyName: return localizer.text("problem.emptyName")
        case .missingSource: return localizer.text("problem.missingSource")
        case .missingDestination: return localizer.text("problem.missingDestination")
        case .sameSourceAndDestination: return localizer.text("problem.sameSourceAndDestination")
        case .nestedFolders: return localizer.text("problem.nestedFolders")
        case .engineMismatch: return localizer.text("problem.engineMismatch")
        case .invalidThreshold: return localizer.text("problem.invalidThreshold")
        case .invalidSchedule: return localizer.text("problem.invalidSchedule")
        }
    }

    public func modeTitle(_ mode: SyncMode) -> String { cards.mode(mode) }

    public func modeDescription(_ mode: SyncMode) -> String {
        switch mode {
        case .copy: return localizer.text("mode.copy.description")
        case .mirror: return localizer.text("mode.mirror.description")
        case .bidirectional: return localizer.text("mode.bidirectional.description")
        case .move: return localizer.text("mode.move.description")
        case .versioned: return localizer.text("mode.versioned.description")
        case .verify: return localizer.text("mode.verify.description")
        }
    }

    public func modeWarning(_ mode: SyncMode) -> String? {
        switch mode {
        case .mirror: return localizer.text("mode.mirror.warning")
        case .bidirectional: return localizer.text("mode.bidirectional.warning")
        case .move: return localizer.text("mode.move.warning")
        case .copy, .versioned, .verify: return nil
        }
    }

    public func modeNote(_ mode: SyncMode) -> String? {
        mode.requiresRclone ? localizer.text("mode.rclone.note") : nil
    }

    public func scheduleKind(_ kind: ScheduleKind) -> String {
        switch kind {
        case .manual: return localizer.text("schedule.kind.manual")
        case .daily: return localizer.text("schedule.kind.daily")
        case .weekdays: return localizer.text("schedule.kind.weekdays")
        case .everyMinutes: return localizer.text("schedule.kind.everyMinutes")
        case .whenAvailable: return localizer.text("schedule.kind.whenAvailable")
        }
    }

    public func notification(_ policy: NotificationPolicy) -> String {
        switch policy {
        case .always: return localizer.text("notify.always")
        case .errorsOnly: return localizer.text("notify.errorsOnly")
        case .never: return localizer.text("notify.never")
        }
    }

    public func templateTitle(_ template: TaskTemplate) -> String {
        switch template {
        case .copyToNAS: return localizer.text("template.copyToNAS.title")
        case .syncTwoFolders: return localizer.text("template.syncTwoFolders.title")
        case .backupToDrive: return localizer.text("template.backupToDrive.title")
        }
    }

    public func templateDescription(_ template: TaskTemplate) -> String {
        switch template {
        case .copyToNAS: return localizer.text("template.copyToNAS.description")
        case .syncTwoFolders: return localizer.text("template.syncTwoFolders.description")
        case .backupToDrive: return localizer.text("template.backupToDrive.description")
        }
    }

    public func stepTitle(_ step: EditorStep) -> String {
        switch step {
        case .endpoints: return localizer.text("editor.step.endpoints")
        case .mode: return localizer.text("editor.step.mode")
        case .options: return localizer.text("editor.step.options")
        case .schedule: return localizer.text("editor.step.schedule")
        case .summary: return localizer.text("editor.step.summary")
        }
    }
}
```

Ajouter à la fin de `Sources/SyncMacProUI/Resources/fr.lproj/Localizable.strings`, et remplacer la valeur de `"dashboard.empty.body"` par `"Créez votre première tâche, ou partez d’un modèle."` :

```
"sidebar.tasks" = "Tâches";
"dashboard.create" = "Créer une tâche";

"tasks.title" = "Tâches";
"tasks.new" = "Nouvelle tâche";
"tasks.templates" = "Modèles";
"tasks.edit" = "Modifier";
"tasks.duplicate" = "Dupliquer";
"tasks.delete" = "Supprimer";
"tasks.enabled" = "Activée";
"tasks.copy.suffix" = "(copie)";
"tasks.delete.confirm" = "Supprimer la tâche « %@ » ?";
"tasks.delete.body" = "Les fichiers déjà copiés ne sont pas touchés et l’historique est conservé.";
"tasks.empty" = "Aucune tâche. Créez-en une, ou partez d’un modèle.";

"template.copyToNAS.title" = "Copier vers un NAS";
"template.copyToNAS.description" = "Chaque nuit, ajoute vos nouveaux fichiers sur le NAS, sans rien y supprimer.";
"template.syncTwoFolders.title" = "Synchroniser deux dossiers";
"template.syncTwoFolders.description" = "Garde deux dossiers identiques dans les deux sens, toutes les heures.";
"template.backupToDrive.title" = "Sauvegarder vers Google Drive";
"template.backupToDrive.description" = "Chaque nuit, copie un dossier vers Google Drive (remote rclone « drive »).";

"editor.title.new" = "Nouvelle tâche";
"editor.title.edit" = "Modifier la tâche";
"editor.step.endpoints" = "Source et destination";
"editor.step.mode" = "Mode";
"editor.step.options" = "Options";
"editor.step.schedule" = "Planification";
"editor.step.summary" = "Résumé";
"editor.cancel" = "Annuler";
"editor.back" = "Précédent";
"editor.next" = "Suivant";
"editor.save" = "Enregistrer";
"editor.saving" = "Enregistrement…";
"editor.offline" = "L’agent ne répond pas : impossible d’enregistrer ou de simuler pour l’instant.";
"editor.source" = "Source";
"editor.destination" = "Destination";
"editor.side.folder" = "Dossier ou disque";
"editor.side.cloud" = "Service en ligne";
"editor.path" = "Chemin";
"editor.choose" = "Choisir…";
"editor.remote" = "Service";
"editor.remote.help" = "Le nom du service dans rclone, par exemple « drive ». L’assistant de connexion arrive bientôt.";
"editor.name" = "Nom de la tâche";
"editor.next.run" = "Prochaine exécution : %@";
"editor.simulate" = "Simuler";
"editor.simulate.help" = "Calcule ce que ferait la tâche, sans rien copier ni supprimer.";
"editor.simulating" = "Simulation en cours…";
"editor.simulate.cancel" = "Annuler la simulation";
"editor.simulate.again" = "Simuler à nouveau";
"editor.options.transfer" = "Transfert";
"editor.options.excludes" = "Exclusions (une par ligne)";
"editor.options.bandwidth" = "Limite de débit (Ko/s, vide = illimité)";
"editor.options.verify" = "Vérifier après la copie";
"editor.options.quota" = "Quota par exécution (Go)";
"editor.options.safety" = "Sécurité";
"editor.options.threshold" = "Bloquer au-delà de %d %% de suppressions";
"editor.options.archive" = "Dossier d’archive";
"editor.options.retention" = "Garder les anciennes versions (jours)";
"editor.options.conditions" = "Conditions";
"editor.options.ac" = "Seulement sur secteur";
"editor.options.network" = "Seulement avec le réseau";
"editor.options.hours" = "Seulement dans une plage horaire";
"editor.options.hours.start" = "De %d h";
"editor.options.hours.end" = "à %d h";
"editor.options.notifications" = "Notifications";
"editor.schedule.kind" = "Quand lancer la tâche";
"editor.schedule.time" = "Heure";
"editor.schedule.every" = "Toutes les %d min";

"schedule.kind.manual" = "À la demande";
"schedule.kind.daily" = "Tous les jours";
"schedule.kind.weekdays" = "Certains jours";
"schedule.kind.everyMinutes" = "Régulièrement";
"schedule.kind.whenAvailable" = "Dès que la destination est disponible";

"notify.always" = "Toujours";
"notify.errorsOnly" = "En cas de problème";
"notify.never" = "Jamais";

"mode.copy.description" = "Ajoute ce qui est nouveau ou modifié. Ne supprime jamais rien.";
"mode.mirror.description" = "La destination devient identique à la source. Ce qui est supprimé ou remplacé est archivé.";
"mode.bidirectional.description" = "Les deux côtés restent à jour, dans les deux sens.";
"mode.move.description" = "Copie, puis retire les fichiers de la source.";
"mode.versioned.description" = "Copie et garde les anciennes versions pendant un nombre de jours choisi.";
"mode.verify.description" = "Compare les deux côtés sans rien modifier.";
"mode.mirror.warning" = "Supprime de la destination ce qui n’est plus dans la source.";
"mode.bidirectional.warning" = "Une suppression d’un côté se propage de l’autre.";
"mode.move.warning" = "Les fichiers disparaissent de la source.";
"mode.rclone.note" = "Utilise rclone.";

"summary.sentence.copy" = "Copie les nouveautés de « %1$@ » vers « %2$@ », %3$@.";
"summary.sentence.mirror" = "Rend « %2$@ » identique à « %1$@ », %3$@.";
"summary.sentence.bidirectional" = "Garde « %1$@ » et « %2$@ » identiques dans les deux sens, %3$@.";
"summary.sentence.move" = "Déplace le contenu de « %1$@ » vers « %2$@ », %3$@.";
"summary.sentence.versioned" = "Copie « %1$@ » vers « %2$@ » en gardant les anciennes versions, %3$@.";
"summary.sentence.verify" = "Compare « %1$@ » et « %2$@ », %3$@.";
"summary.when.manual" = "à la demande";
"summary.safe" = "Rien n’est supprimé.";
"summary.readonly" = "Rien n’est modifié.";

"warning.mirror" = "Les fichiers absents de la source seront retirés de la destination et archivés dans « %@ ».";
"warning.bidirectional" = "Une suppression d’un côté se propagera de l’autre.";
"warning.move" = "Les fichiers seront retirés de la source une fois copiés.";
"warning.disabled" = "La tâche est désactivée : elle ne se lancera pas toute seule.";

"simulation.result" = "%1$d fichier(s) à transférer (%2$@), %3$d suppression(s).";
"simulation.deletions" = "Attention : %d fichier(s) seraient supprimés.";
"simulation.failed" = "La simulation a échoué : %@";
"simulation.stopped" = "Simulation annulée.";

"problem.emptyName" = "Donnez un nom à la tâche.";
"problem.missingSource" = "Choisissez une source.";
"problem.missingDestination" = "Choisissez une destination.";
"problem.sameSourceAndDestination" = "La source et la destination sont le même dossier.";
"problem.nestedFolders" = "La destination ne peut pas être dans la source, ni la source dans la destination.";
"problem.engineMismatch" = "Le moteur choisi ne sait pas faire ce mode.";
"problem.invalidThreshold" = "Le seuil de suppression doit être compris entre 1 et 100 %.";
"problem.invalidSchedule" = "La planification est incomplète.";

"history.log.show" = "Voir le journal";
"log.title" = "Journal de « %@ »";
"log.copy" = "Copier";
"log.close" = "Fermer";
"log.truncated" = "Début du journal non affiché (trop long).";
"log.none" = "Aucun journal pour cette exécution.";
"log.loading" = "Chargement du journal…";
```

Ajouter à la fin de `Sources/SyncMacProUI/Resources/en.lproj/Localizable.strings`, et remplacer `"dashboard.empty.body"` par `"Create your first task, or start from a template."` :

```
"sidebar.tasks" = "Tasks";
"dashboard.create" = "Create a task";

"tasks.title" = "Tasks";
"tasks.new" = "New task";
"tasks.templates" = "Templates";
"tasks.edit" = "Edit";
"tasks.duplicate" = "Duplicate";
"tasks.delete" = "Delete";
"tasks.enabled" = "Enabled";
"tasks.copy.suffix" = "(copy)";
"tasks.delete.confirm" = "Delete the task “%@”?";
"tasks.delete.body" = "Files already copied are not touched and the history is kept.";
"tasks.empty" = "No tasks. Create one, or start from a template.";

"template.copyToNAS.title" = "Copy to a NAS";
"template.copyToNAS.description" = "Every night, adds your new files to the NAS without deleting anything there.";
"template.syncTwoFolders.title" = "Sync two folders";
"template.syncTwoFolders.description" = "Keeps two folders identical in both directions, every hour.";
"template.backupToDrive.title" = "Back up to Google Drive";
"template.backupToDrive.description" = "Every night, copies a folder to Google Drive (rclone remote “drive”).";

"editor.title.new" = "New task";
"editor.title.edit" = "Edit task";
"editor.step.endpoints" = "Source and destination";
"editor.step.mode" = "Mode";
"editor.step.options" = "Options";
"editor.step.schedule" = "Schedule";
"editor.step.summary" = "Summary";
"editor.cancel" = "Cancel";
"editor.back" = "Back";
"editor.next" = "Next";
"editor.save" = "Save";
"editor.saving" = "Saving…";
"editor.offline" = "The agent is not responding: saving and simulating are unavailable for now.";
"editor.source" = "Source";
"editor.destination" = "Destination";
"editor.side.folder" = "Folder or disk";
"editor.side.cloud" = "Online service";
"editor.path" = "Path";
"editor.choose" = "Choose…";
"editor.remote" = "Service";
"editor.remote.help" = "The service name in rclone, for example “drive”. The connection assistant is coming soon.";
"editor.name" = "Task name";
"editor.next.run" = "Next run: %@";
"editor.simulate" = "Simulate";
"editor.simulate.help" = "Works out what the task would do, without copying or deleting anything.";
"editor.simulating" = "Simulating…";
"editor.simulate.cancel" = "Cancel simulation";
"editor.simulate.again" = "Simulate again";
"editor.options.transfer" = "Transfer";
"editor.options.excludes" = "Exclusions (one per line)";
"editor.options.bandwidth" = "Bandwidth limit (KB/s, empty = unlimited)";
"editor.options.verify" = "Verify after copying";
"editor.options.quota" = "Quota per run (GB)";
"editor.options.safety" = "Safety";
"editor.options.threshold" = "Block above %d %% deletions";
"editor.options.archive" = "Archive folder";
"editor.options.retention" = "Keep old versions (days)";
"editor.options.conditions" = "Conditions";
"editor.options.ac" = "Only on AC power";
"editor.options.network" = "Only with network";
"editor.options.hours" = "Only within a time window";
"editor.options.hours.start" = "From %d h";
"editor.options.hours.end" = "to %d h";
"editor.options.notifications" = "Notifications";
"editor.schedule.kind" = "When to run the task";
"editor.schedule.time" = "Time";
"editor.schedule.every" = "Every %d min";

"schedule.kind.manual" = "On demand";
"schedule.kind.daily" = "Every day";
"schedule.kind.weekdays" = "Some days";
"schedule.kind.everyMinutes" = "Regularly";
"schedule.kind.whenAvailable" = "As soon as the destination is available";

"notify.always" = "Always";
"notify.errorsOnly" = "On problems";
"notify.never" = "Never";

"mode.copy.description" = "Adds what is new or changed. Never deletes anything.";
"mode.mirror.description" = "The destination becomes identical to the source. What is deleted or replaced is archived.";
"mode.bidirectional.description" = "Both sides stay up to date, in both directions.";
"mode.move.description" = "Copies, then removes the files from the source.";
"mode.versioned.description" = "Copies and keeps old versions for a chosen number of days.";
"mode.verify.description" = "Compares both sides without changing anything.";
"mode.mirror.warning" = "Deletes from the destination what is no longer in the source.";
"mode.bidirectional.warning" = "A deletion on one side is carried over to the other.";
"mode.move.warning" = "Files disappear from the source.";
"mode.rclone.note" = "Uses rclone.";

"summary.sentence.copy" = "Copies what is new or changed from “%1$@” to “%2$@”, %3$@.";
"summary.sentence.mirror" = "Makes “%2$@” identical to “%1$@”, %3$@.";
"summary.sentence.bidirectional" = "Keeps “%1$@” and “%2$@” identical in both directions, %3$@.";
"summary.sentence.move" = "Moves the content of “%1$@” to “%2$@”, %3$@.";
"summary.sentence.versioned" = "Copies “%1$@” to “%2$@” keeping old versions, %3$@.";
"summary.sentence.verify" = "Compares “%1$@” and “%2$@”, %3$@.";
"summary.when.manual" = "on demand";
"summary.safe" = "Nothing is deleted.";
"summary.readonly" = "Nothing is changed.";

"warning.mirror" = "Files missing from the source will be removed from the destination and archived in “%@”.";
"warning.bidirectional" = "A deletion on one side will be carried over to the other.";
"warning.move" = "Files will be removed from the source once copied.";
"warning.disabled" = "The task is disabled: it will not run by itself.";

"simulation.result" = "%1$d file(s) to transfer (%2$@), %3$d deletion(s).";
"simulation.deletions" = "Warning: %d file(s) would be deleted.";
"simulation.failed" = "The simulation failed: %@";
"simulation.stopped" = "Simulation cancelled.";

"problem.emptyName" = "Give the task a name.";
"problem.missingSource" = "Choose a source.";
"problem.missingDestination" = "Choose a destination.";
"problem.sameSourceAndDestination" = "The source and the destination are the same folder.";
"problem.nestedFolders" = "The destination cannot be inside the source, nor the source inside the destination.";
"problem.engineMismatch" = "The chosen engine cannot do this mode.";
"problem.invalidThreshold" = "The deletion threshold must be between 1 and 100 %.";
"problem.invalidSchedule" = "The schedule is incomplete.";

"history.log.show" = "Show log";
"log.title" = "Log of “%@”";
"log.copy" = "Copy";
"log.close" = "Close";
"log.truncated" = "Beginning of the log not shown (too long).";
"log.none" = "No log for this run.";
"log.loading" = "Loading the log…";
```

- [ ] **Étape 4 : vérifier** — `swift test --filter "TaskSummaryTextTests|StringsCompletenessTests|LocalizerTests" 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | sed -E 's|/Users/[^ ]*/||' | tail -6` → tous passent.

- [ ] **Étape 5 : commit et push**

```bash
git add Sources/SyncMacProUI Tests/SyncMacProUITests
git commit -m "Interface : phrases de l'éditeur (résumé, avertissements, simulation) et chaînes fr / en" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 9 : l'éditeur en 5 étapes

**Fichiers :** créer `Sources/SyncMacProUI/Views/TaskEditorView.swift`, `Sources/SyncMacProUI/Views/EditorSteps.swift` ; tester `Tests/SyncMacProUITests/EditorRenderTests.swift`.

**Interfaces :**
- Consomme : `TaskDraft`, `EditorStep`, `TaskSummaryText`, `EndpointResolver`, `AgentModel.saveTask/simulate/cancelSimulation`.
- Produit : `enum SimulationState: Equatable { idle, running, finished(SimulationOutcome) }` ; `public struct TaskEditorView(model:draft:isNew:localizer:resolver:onClose:)` ; `EditorStepContent(draft:step:text:resolver:simulation:saveError:offline:onSimulate:onCancelSimulation:)` (interne, rendu sans `ScrollView`).

- [ ] **Étape 1 : tests de rendu qui échouent**

`Tests/SyncMacProUITests/EditorRenderTests.swift` :

```swift
import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class EditorRenderTests: XCTestCase {
    func filledDraft() -> TaskDraft {
        var draft = TaskDraft.template(.copyToNAS)
        draft.source.path = "/Users/moi/Photos"
        draft.destination.path = "/Volumes/NAS/Photos"
        draft.mode = .mirror
        draft.name = "Photos vers le NAS"
        return draft
    }

    func content(
        _ step: EditorStep, draft: TaskDraft, simulation: SimulationState = .idle, offline: Bool = false,
        language: String = "fr"
    ) -> some View {
        EditorStepContent(
            draft: .constant(draft), step: step,
            text: TaskSummaryText(localizer: Localizer(language: language), now: UIFixtures.now),
            resolver: .localOnly, simulation: simulation, saveError: nil, offline: offline,
            onSimulate: {}, onCancelSimulation: {}
        )
        .padding(20)
    }

    func testEveryStepRenders() throws {
        for step in EditorStep.allCases {
            let image = try render(content(step, draft: filledDraft()), name: "editor-\(step.rawValue)",
                                   size: CGSize(width: 720, height: 560), scheme: .light)
            assertNotBlank(image)
        }
    }

    func testEmptyDraftAndEnglishRender() throws {
        let image = try render(content(.endpoints, draft: TaskDraft(), language: "en"), name: "editor-empty-en",
                               size: CGSize(width: 720, height: 400), scheme: .dark)
        assertNotBlank(image)
    }

    func testSummaryWithASimulationThatDeletesRenders() throws {
        let result = SimulationResult(status: .succeeded, filesToTransfer: 128, bytesToTransfer: 3_400_000_000, deletions: 42, message: nil)
        let image = try render(content(.summary, draft: filledDraft(), simulation: .finished(.finished(result))),
                               name: "editor-summary-simulated", size: CGSize(width: 720, height: 560), scheme: .light)
        assertNotBlank(image)
        let failed = try render(content(.summary, draft: filledDraft(), simulation: .finished(.failed("source introuvable")), offline: true),
                                name: "editor-summary-failed", size: CGSize(width: 720, height: 560), scheme: .dark)
        assertNotBlank(failed)
    }
}
```

`swift test --filter EditorRenderTests 2>&1 | grep -E "error:" | head -2` → compilation (`EditorStepContent` inconnu).

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Views/EditorSteps.swift` :

```swift
import AppKit
import SwiftUI
import SyncKit

public enum SimulationState: Equatable, Sendable {
    case idle
    case running
    case finished(SimulationOutcome)
}

/// Le contenu d'une étape, sans défilement (rendu par les tests).
@MainActor
struct EditorStepContent: View {
    @Binding var draft: TaskDraft
    let step: EditorStep
    let text: TaskSummaryText
    let resolver: EndpointResolver
    let simulation: SimulationState
    let saveError: String?
    let offline: Bool
    let onSimulate: () -> Void
    let onCancelSimulation: () -> Void

    var body: some View {
        switch step {
        case .endpoints: EndpointsStepView(draft: $draft, localizer: text.localizer)
        case .mode: ModeStepView(draft: $draft, text: text)
        case .options: OptionsStepView(draft: $draft, text: text)
        case .schedule: ScheduleStepView(draft: $draft, text: text, resolver: resolver)
        case .summary:
            SummaryStepView(
                draft: $draft, text: text, resolver: resolver, simulation: simulation, saveError: saveError,
                offline: offline, onSimulate: onSimulate, onCancel: onCancelSimulation
            )
        }
    }
}

// MARK: 1. source et destination

@MainActor
struct EndpointsStepView: View {
    @Binding var draft: TaskDraft
    let localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SideEditor(title: localizer.text("editor.source"), side: $draft.source, localizer: localizer)
            SideEditor(title: localizer.text("editor.destination"), side: $draft.destination, localizer: localizer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct SideEditor: View {
    let title: String
    @Binding var side: SideDraft
    let localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Picker("", selection: $side.kind) {
                Text(localizer.text("editor.side.folder")).tag(SideKind.folder)
                Text(localizer.text("editor.side.cloud")).tag(SideKind.cloud)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            if side.kind == .folder {
                HStack {
                    TextField(localizer.text("editor.path"), text: $side.path).textFieldStyle(.roundedBorder)
                    Button(localizer.text("editor.choose")) {
                        if let path = FolderPicker.choose() { side.path = path }
                    }
                }
            } else {
                HStack {
                    TextField(localizer.text("editor.remote"), text: $side.remote)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    TextField(localizer.text("editor.path"), text: $side.path).textFieldStyle(.roundedBorder)
                }
                Text(localizer.text("editor.remote.help")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum FolderPicker {
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: 2. mode

@MainActor
struct ModeStepView: View {
    @Binding var draft: TaskDraft
    let text: TaskSummaryText

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
            ForEach(SyncMode.allCases, id: \.self) { mode in
                ModeCard(
                    title: text.modeTitle(mode), description: text.modeDescription(mode),
                    warning: text.modeWarning(mode), note: text.modeNote(mode), selected: draft.mode == mode
                )
                .onTapGesture { draft.mode = mode }
            }
        }
    }
}

@MainActor
struct ModeCard: View {
    let title: String
    let description: String
    let warning: String?
    let note: String?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: 3. options

@MainActor
struct OptionsStepView: View {
    @Binding var draft: TaskDraft
    let text: TaskSummaryText

    private var l: Localizer { text.localizer }
    private var touchesCloud: Bool { draft.source.kind == .cloud || draft.destination.kind == .cloud }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group(l.text("editor.options.transfer")) {
                Text(l.text("editor.options.excludes")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.excludesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                field(l.text("editor.options.bandwidth"), text: $draft.bandwidthText)
                Toggle(l.text("editor.options.verify"), isOn: $draft.options.verifyAfterCopy)
                if touchesCloud { field(l.text("editor.options.quota"), text: $draft.maxTransferText) }
            }
            if draft.mode.deletesData || draft.mode == .versioned {
                group(l.text("editor.options.safety")) {
                    Stepper(
                        l.format("editor.options.threshold", draft.options.deleteThresholdPercent),
                        value: $draft.options.deleteThresholdPercent, in: 1...100, step: 5
                    )
                    if draft.mode == .mirror { field(l.text("editor.options.archive"), text: $draft.options.archiveFolder) }
                    if draft.mode == .versioned { field(l.text("editor.options.retention"), text: $draft.retentionText) }
                }
            }
            group(l.text("editor.options.conditions")) {
                Toggle(l.text("editor.options.ac"), isOn: $draft.conditions.requiresACPower)
                Toggle(l.text("editor.options.network"), isOn: $draft.conditions.requiresNetwork)
                Toggle(l.text("editor.options.hours"), isOn: hoursEnabled)
                if let range = draft.conditions.allowedHours {
                    HStack(spacing: 16) {
                        Stepper(l.format("editor.options.hours.start", range.start), value: hour(\.start), in: 0...23)
                        Stepper(l.format("editor.options.hours.end", range.end), value: hour(\.end), in: 0...23)
                    }
                }
            }
            group(l.text("editor.options.notifications")) {
                Picker("", selection: $draft.notifications) {
                    ForEach(NotificationPolicy.allCases, id: \.self) { Text(text.notification($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var hoursEnabled: Binding<Bool> {
        Binding(
            get: { draft.conditions.allowedHours != nil },
            set: { draft.conditions.allowedHours = $0 ? HourRange(start: 22, end: 6) : nil }
        )
    }

    private func hour(_ keyPath: WritableKeyPath<HourRange, Int>) -> Binding<Int> {
        Binding(
            get: { draft.conditions.allowedHours?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard var range = draft.conditions.allowedHours else { return }
                range[keyPath: keyPath] = value
                draft.conditions.allowedHours = range
            }
        )
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: text).textFieldStyle(.roundedBorder).frame(width: 160)
        }
    }
}

// MARK: 4. planification

@MainActor
struct ScheduleStepView: View {
    @Binding var draft: TaskDraft
    let text: TaskSummaryText
    let resolver: EndpointResolver

    private var l: Localizer { text.localizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(l.text("editor.schedule.kind"), selection: $draft.scheduleDraft.kind) {
                ForEach(ScheduleKind.allCases, id: \.self) { Text(text.scheduleKind($0)).tag($0) }
            }
            .pickerStyle(.radioGroup)
            switch draft.scheduleDraft.kind {
            case .daily:
                timePicker
            case .weekdays:
                weekdayPicker
                timePicker
            case .everyMinutes:
                Stepper(
                    l.format("editor.schedule.every", draft.scheduleDraft.interval),
                    value: $draft.scheduleDraft.interval, in: 1...1440, step: 5
                )
            case .manual, .whenAvailable:
                EmptyView()
            }
            Text(l.format("editor.next.run", text.nextRun(for: draft.task(resolver: resolver))))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timePicker: some View {
        DatePicker(l.text("editor.schedule.time"), selection: time, displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .frame(maxWidth: 240)
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                Toggle(isOn: weekday(day)) { Text(l.text("weekday.\(day)")) }.toggleStyle(.button)
            }
        }
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                text.calendar.date(
                    bySettingHour: draft.scheduleDraft.hour, minute: draft.scheduleDraft.minute, second: 0, of: text.now
                ) ?? text.now
            },
            set: { date in
                let parts = text.calendar.dateComponents([.hour, .minute], from: date)
                draft.scheduleDraft.hour = parts.hour ?? 0
                draft.scheduleDraft.minute = parts.minute ?? 0
            }
        )
    }

    private func weekday(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { draft.scheduleDraft.days.contains(day) },
            set: { on in
                if on { draft.scheduleDraft.days.insert(day) } else { draft.scheduleDraft.days.remove(day) }
            }
        )
    }
}

// MARK: 5. résumé

@MainActor
struct SummaryStepView: View {
    @Binding var draft: TaskDraft
    let text: TaskSummaryText
    let resolver: EndpointResolver
    let simulation: SimulationState
    let saveError: String?
    let offline: Bool
    let onSimulate: () -> Void
    let onCancel: () -> Void

    private var l: Localizer { text.localizer }

    var body: some View {
        let task = draft.task(resolver: resolver)
        VStack(alignment: .leading, spacing: 14) {
            TextField(l.text("editor.name"), text: $draft.name).textFieldStyle(.roundedBorder).font(.title3)
            Text(text.sentence(for: task)).font(.title3).fixedSize(horizontal: false, vertical: true)
            ForEach(text.warnings(for: task), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(l.format("editor.next.run", text.nextRun(for: task))).foregroundStyle(.secondary)
            Divider()
            simulationSection
            if let saveError {
                Label(saveError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var simulationSection: some View {
        switch simulation {
        case .idle:
            Button(action: onSimulate) { Label(l.text("editor.simulate"), systemImage: "eye") }.disabled(offline)
            Text(l.text("editor.simulate.help")).font(.caption).foregroundStyle(.secondary)
        case .running:
            HStack {
                ProgressView().controlSize(.small)
                Text(l.text("editor.simulating"))
                Button(l.text("editor.simulate.cancel"), action: onCancel)
            }
        case .finished(let outcome):
            switch outcome {
            case .finished(let result):
                Label(
                    text.simulation(result),
                    systemImage: result.status == .succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(result.status == .succeeded ? Color.green : Color.red)
                if let warning = text.deletionsWarning(result) {
                    Label(warning, systemImage: "trash").foregroundStyle(.orange).font(.headline)
                }
            case .failed(let message):
                Label(l.format("simulation.failed", message), systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            Button(l.text("editor.simulate.again"), action: onSimulate).disabled(offline)
        }
    }
}
```

`Sources/SyncMacProUI/Views/TaskEditorView.swift` :

```swift
import SwiftUI
import SyncKit

/// Éditeur de tâche en 5 étapes, présenté en feuille.
@MainActor
public struct TaskEditorView: View {
    let model: AgentModel
    let isNew: Bool
    let localizer: Localizer
    let resolver: EndpointResolver
    let onClose: () -> Void
    @State private var draft: TaskDraft
    @State private var step: EditorStep = .endpoints
    @State private var simulation: SimulationState = .idle
    @State private var saveError: String?
    @State private var saving = false

    public init(
        model: AgentModel, draft: TaskDraft, isNew: Bool, localizer: Localizer = .system,
        resolver: EndpointResolver = .system, onClose: @escaping () -> Void
    ) {
        self.model = model
        self.isNew = isNew
        self.localizer = localizer
        self.resolver = resolver
        self.onClose = onClose
        _draft = State(initialValue: draft)
    }

    private var text: TaskSummaryText { TaskSummaryText(localizer: localizer) }
    private var offline: Bool { model.connection != .connected }
    private var stepProblems: [TaskProblem] { draft.problems(for: step, resolver: resolver) }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                EditorStepContent(
                    draft: $draft, step: step, text: text, resolver: resolver, simulation: simulation,
                    saveError: saveError, offline: offline,
                    onSimulate: { Task { await simulate() } },
                    onCancelSimulation: { Task { await model.cancelSimulation(draft.id) } }
                )
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 740, height: 620)
        .onChange(of: draft) { _, _ in
            // Une simulation ne vaut que pour la version simulée.
            if case .finished = simulation { simulation = .idle }
            saveError = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? localizer.text("editor.title.new") : localizer.text("editor.title.edit")).font(.title2.bold())
            HStack(spacing: 6) {
                ForEach(EditorStep.allCases, id: \.self) { item in
                    Button { go(to: item) } label: {
                        Text("\(item.rawValue + 1). \(text.stepTitle(item))")
                            .font(.callout.weight(item == step ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(item == step ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!reachable(item))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(localizer.text("editor.cancel"), action: onClose).keyboardShortcut(.cancelAction)
            if offline {
                Text(localizer.text("editor.offline")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let problem = stepProblems.first {
                Text(text.problem(problem)).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if step != .endpoints {
                Button(localizer.text("editor.back")) { go(to: EditorStep(rawValue: step.rawValue - 1) ?? .endpoints) }
            }
            if step == .summary {
                Button(saving ? localizer.text("editor.saving") : localizer.text("editor.save")) {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || offline || !draft.problems(resolver: resolver).isEmpty)
            } else {
                Button(localizer.text("editor.next")) { go(to: EditorStep(rawValue: step.rawValue + 1) ?? .summary) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!stepProblems.isEmpty)
            }
        }
        .padding(14)
    }

    /// Une étape est accessible quand toutes les précédentes sont correctes.
    private func reachable(_ target: EditorStep) -> Bool {
        EditorStep.allCases.filter { $0.rawValue < target.rawValue }
            .allSatisfy { draft.problems(for: $0, resolver: resolver).isEmpty }
    }

    private func go(to target: EditorStep) {
        guard reachable(target) else { return }
        if target == .summary { draft.fillNameIfNeeded() }
        step = target
    }

    private func save() async {
        saving = true
        let message = await model.saveTask(draft.task(resolver: resolver))
        saving = false
        if let message { saveError = message } else { onClose() }
    }

    private func simulate() async {
        simulation = .running
        let outcome = await model.simulate(draft.task(resolver: resolver))
        simulation = .finished(outcome)
    }
}
```

- [ ] **Étape 3 : vérifier** — `swift build 2>&1 | grep -E "error|Build" | head -5` puis `swift test --filter "EditorRenderTests|StringsCompletenessTests" 2>&1 | grep -E "error:|Executed .* tests|skipped" | sed -E 's|/Users/[^ ]*/||' | tail -4` → passent.

- [ ] **Étape 4 : inspecter** les PNG `editor-0-light.png` à `editor-4-light.png` et `editor-summary-simulated-light.png` (dossier `$TMPDIR/syncmacpro-renders/`) : chaque étape lisible ; les cartes de mode avec avertissement orange ; le résumé avec la phrase, l'avertissement du miroir et « Attention : 42 fichier(s) seraient supprimés ». Les champs, interrupteurs et sélecteurs AppKit apparaissent comme des symboles de remplacement (limite connue d'`ImageRenderer`).

- [ ] **Étape 5 : commit et push**

```bash
git add Sources/SyncMacProUI/Views Tests/SyncMacProUITests/EditorRenderTests.swift
git commit -m "Interface : éditeur de tâche en 5 étapes (dossiers, modes, options, planification, résumé et simulation)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 10 : écran Tâches, modèles, ouverture de l'éditeur

**Fichiers :** créer `Sources/SyncMacProUI/Views/TasksView.swift`, `Tests/SyncMacProUITests/TasksRenderTests.swift` ; modifier `Sources/SyncMacProUI/Views/RootView.swift`, `Sources/SyncMacProUI/Views/DashboardView.swift`, `Tests/SyncMacProUITests/RootViewTests.swift`.

**Interfaces :**
- Produit : `public struct TasksView(model:localizer:onEdit:)` ; `TasksListBody` (interne) ; `SidebarItem` (`dashboard`, `tasks`, `history`, `settings`) ; `EditorSession: Identifiable` ; `DashboardBody` / `DashboardContent` / `DashboardView` gagnent `onCreate: (TaskDraft) -> Void` (par défaut sans effet).

- [ ] **Étape 1 : tests qui échouent**

Dans `RootViewTests.testSidebarHasThreeEntries`, remplacer l'attendu par `[.dashboard, .tasks, .history, .settings]` (et renommer le test `testSidebarEntries`).

`Tests/SyncMacProUITests/TasksRenderTests.swift` :

```swift
import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class TasksRenderTests: XCTestCase {
    func testTaskListRendersInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let list = TasksListBody(
                tasks: UIFixtures.tasks, selection: UIFixtures.ids[1], text: UIFixtures.french,
                onToggle: { _, _ in }, onEdit: { _ in }, onDuplicate: { _ in }, onDelete: { _ in }, onSelect: { _ in }
            )
            let image = try render(list, name: "tasks", size: CGSize(width: 820, height: 520), scheme: scheme)
            assertNotBlank(image)
        }
    }

    func testDashboardEmptyStateOffersCreation() throws {
        let body = DashboardBody(model: UIFixtures.model(empty: true), installState: .enabled, text: UIFixtures.french,
                                 onInstall: {}, onCreate: { _ in })
        let image = try render(body, name: "dashboard-empty-create", size: CGSize(width: 820, height: 380), scheme: .light)
        assertNotBlank(image)
    }
}
```

`swift test --filter "TasksRenderTests|RootViewTests" 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Views/TasksView.swift` :

```swift
import SwiftUI
import SyncKit

/// Liste des tâches : activer, modifier, dupliquer, supprimer, créer (vide ou depuis un modèle).
@MainActor
public struct TasksView: View {
    let model: AgentModel
    let localizer: Localizer
    let onEdit: (TaskDraft, Bool) -> Void
    @State private var selection: UUID?
    @State private var pendingDelete: SyncTask?

    public init(model: AgentModel, localizer: Localizer = .system, onEdit: @escaping (TaskDraft, Bool) -> Void) {
        self.model = model
        self.localizer = localizer
        self.onEdit = onEdit
    }

    private var tasks: [SyncTask] {
        model.tasks.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var body: some View {
        let text = CardText(localizer: localizer)
        VStack(spacing: 0) {
            HStack {
                Text(localizer.text("tasks.title")).font(.largeTitle.bold())
                Spacer()
                TemplatesMenu(localizer: localizer) { onEdit(.template($0), true) }
                Button { onEdit(TaskDraft(), true) } label: { Label(localizer.text("tasks.new"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.connection != .connected)
            }
            .padding(20)
            Divider()
            if tasks.isEmpty {
                Spacer()
                Text(localizer.text("tasks.empty")).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    TasksListBody(
                        tasks: tasks, selection: selection, text: text,
                        onToggle: { task, on in Task { await model.setEnabled(task.id, on) } },
                        onEdit: { onEdit(TaskDraft(task: $0), false) },
                        onDuplicate: { onEdit(.duplicate(of: $0, suffix: localizer.text("tasks.copy.suffix")), true) },
                        onDelete: { pendingDelete = $0 },
                        onSelect: { selection = $0 }
                    )
                }
            }
        }
        .confirmationDialog(
            pendingDelete.map { localizer.format("tasks.delete.confirm", $0.name) } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { task in
            Button(localizer.text("tasks.delete"), role: .destructive) { Task { await model.removeTask(task.id) } }
        } message: { _ in
            Text(localizer.text("tasks.delete.body"))
        }
    }
}

@MainActor
struct TemplatesMenu: View {
    let localizer: Localizer
    let onPick: (TaskTemplate) -> Void

    var body: some View {
        let text = TaskSummaryText(localizer: localizer)
        Menu(localizer.text("tasks.templates")) {
            ForEach(TaskTemplate.allCases) { template in
                Button {
                    onPick(template)
                } label: {
                    Text(text.templateTitle(template))
                    Text(text.templateDescription(template))
                }
            }
        }
        .fixedSize()
    }
}

/// Les lignes de la liste, sans défilement (rendu par les tests).
@MainActor
struct TasksListBody: View {
    let tasks: [SyncTask]
    let selection: UUID?
    let text: CardText
    let onToggle: (SyncTask, Bool) -> Void
    let onEdit: (SyncTask) -> Void
    let onDuplicate: (SyncTask) -> Void
    let onDelete: (SyncTask) -> Void
    let onSelect: (UUID) -> Void

    private var l: Localizer { text.localizer }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(tasks) { task in
                row(task)
                Divider()
            }
        }
    }

    private func row(_ task: SyncTask) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name).font(.headline).lineLimit(1)
                Text("\(text.mode(task.mode)) · \(text.schedule(task.schedule))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Toggle(l.text("tasks.enabled"), isOn: Binding(get: { task.isEnabled }, set: { onToggle(task, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
            Menu {
                Button(l.text("tasks.edit")) { onEdit(task) }
                Button(l.text("tasks.duplicate")) { onDuplicate(task) }
                Divider()
                Button(l.text("tasks.delete"), role: .destructive) { onDelete(task) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(selection == task.id ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit(task) }
        .onTapGesture { onSelect(task.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.name)
    }
}
```

`DashboardView.swift` :
1. Dans `DashboardContent` et `DashboardBody`, ajouter la dernière propriété `var onCreate: (TaskDraft) -> Void = { _ in }` ; `DashboardContent` la transmet : `DashboardBody(model: model, installState: installState, text: text, onInstall: onInstall, onCreate: onCreate)`.
2. Dans l'état vide de `DashboardBody` (après le texte `dashboard.empty.body`), ajouter :

```swift
                    HStack {
                        Button { onCreate(TaskDraft()) } label: {
                            Label(l.text("dashboard.create"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.connection != .connected)
                        TemplatesMenu(localizer: l) { onCreate(.template($0)) }
                    }
                    .padding(.top, 8)
```

3. `DashboardView` : propriété `let onCreate: (TaskDraft) -> Void`, paramètre `onCreate: @escaping (TaskDraft) -> Void = { _ in }` dans l'`init`, transmis à `DashboardContent(..., onCreate: onCreate)`.

`RootView.swift` :
1. `SidebarItem` : `case dashboard, tasks, history, settings`.
2. Ajouter avant `RootView` :

```swift
struct EditorSession: Identifiable {
    let id = UUID()
    let draft: TaskDraft
    let isNew: Bool
}
```

3. Dans `RootView` : `@State private var editor: EditorSession?` ; dans `detail`, `case .dashboard: DashboardView(model: model, installer: installer, localizer: localizer, onCreate: { open($0, isNew: true) })` et `case .tasks: TasksView(model: model, localizer: localizer) { open($0, isNew: $1) }` ; après `.alert(...)` :

```swift
        .sheet(item: $editor) { session in
            TaskEditorView(model: model, draft: session.draft, isNew: session.isNew, localizer: localizer) {
                editor = nil
            }
        }
```

et la méthode :

```swift
    private func open(_ draft: TaskDraft, isNew: Bool) {
        editor = EditorSession(draft: draft, isNew: isNew)
    }
```

4. `title(_:)` : `case .tasks: return localizer.text("sidebar.tasks")` ; `icon(_:)` : `case .tasks: return "list.bullet.rectangle"`.

- [ ] **Étape 3 : vérifier** — `swift test --filter "TasksRenderTests|RootViewTests|DashboardRenderTests|StringsCompletenessTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -2` → passent ; lire `tasks-light.png` et `dashboard-empty-create-light.png`.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources/SyncMacProUI/Views Tests/SyncMacProUITests
git commit -m "Interface : écran Tâches (activer, modifier, dupliquer, supprimer), modèles, création depuis le tableau de bord" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 11 : journal dans l'historique

**Fichiers :** créer `Sources/SyncMacProUI/Views/RunLogSheet.swift`, `Tests/SyncMacProUITests/RunLogRenderTests.swift` ; modifier `Sources/SyncMacProUI/Views/HistoryView.swift`.

**Interfaces :** produit `RunLogSheet(model:record:localizer:onClose:)`, `RunLogContent(outcome:localizer:)` (interne).

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncMacProUITests/RunLogRenderTests.swift` :

```swift
import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class RunLogRenderTests: XCTestCase {
    func testEveryLogStateRenders() throws {
        let lines = (1...30).map { "[10:0\($0 % 10):00] >f+++++++++ Vacances/IMG_\($0).jpg" }.joined(separator: "\n")
        let states: [(String, LogOutcome?)] = [
            ("loading", nil),
            ("loaded", .loaded(RunLogText(text: lines, truncated: true))),
            ("missing", .missing),
            ("failed", .failed("L'agent ne répond pas.")),
        ]
        for (name, outcome) in states {
            let view = RunLogContent(outcome: outcome, localizer: Localizer(language: "fr")).padding(16)
            let image = try render(view, name: "log-\(name)", size: CGSize(width: 760, height: 420), scheme: .light)
            assertNotBlank(image)
        }
    }
}
```

`swift test --filter RunLogRenderTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Views/RunLogSheet.swift` :

```swift
import AppKit
import SwiftUI
import SyncKit

@MainActor
struct RunLogSheet: View {
    let model: AgentModel
    let record: RunRecord
    let localizer: Localizer
    let onClose: () -> Void
    @State private var outcome: LogOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizer.format("log.title", record.taskName)).font(.headline)
            ScrollView { RunLogContent(outcome: outcome, localizer: localizer) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(localizer.text("log.copy")) {
                    if case .loaded(let log) = outcome {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.text, forType: .string)
                    }
                }
                .disabled(!isLoaded)
                Spacer()
                Button(localizer.text("log.close"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 780, height: 540)
        .task { outcome = await model.runLog(record.id) }
    }

    private var isLoaded: Bool {
        if case .loaded = outcome { return true }
        return false
    }
}

/// Le contenu du journal, sans défilement (rendu par les tests).
@MainActor
struct RunLogContent: View {
    let outcome: LogOutcome?
    let localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch outcome {
            case nil:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(localizer.text("log.loading"))
                }
            case .loaded(let log)?:
                if log.truncated {
                    Text(localizer.text("log.truncated")).font(.caption).foregroundStyle(.secondary)
                }
                Text(log.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .missing?:
                Text(localizer.text("log.none")).foregroundStyle(.secondary)
            case .failed(let message)?:
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

`HistoryView.swift` :
1. Propriété `@State private var logRecord: RunRecord?`.
2. Dans `detail(_:_:)`, entourer le `Grid(...)` d'un `VStack(alignment: .leading, spacing: 10) { … }` et ajouter après la grille :

```swift
                    if record.logPath != nil {
                        Button(localizer.text("history.log.show")) { logRecord = record }
                    }
```

3. Sur le `VStack` principal de `body`, ajouter :

```swift
        .sheet(item: $logRecord) { record in
            RunLogSheet(model: model, record: record, localizer: localizer) { logRecord = nil }
        }
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "RunLogRenderTests|HistoryRenderTests|StringsCompletenessTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -2` → passent ; lire `log-loaded-light.png`.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources/SyncMacProUI/Views Tests/SyncMacProUITests
git commit -m "Interface : journal d'une exécution depuis l'historique" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 12 : essai réel et documentation

**Fichiers :** modifier `README.md`, `docs/manual-checks-ui.md`.

- [ ] **Étape 1 : essai de bout en bout (agent de développement, sans toucher aux données réelles)**

```bash
export SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync"
scripts/dev-launchd.sh install
C=.build/debug/syncmacpro-ctl; S=com.sylvain.syncmacpro.agent.dev; D="$HOME/Library/Application Support/SyncMacPro-dev"
mkdir -p /tmp/smp-3b/src /tmp/smp-3b/dst && echo un > /tmp/smp-3b/src/a.txt && echo deux > /tmp/smp-3b/dst/ancien.txt
$C add --service $S --state-dir "$D" --name essai --source /tmp/smp-3b/src --dest /tmp/smp-3b/dst --mode mirror
$C add --service $S --state-dir "$D" --name imbriquee --source /tmp/smp-3b/src --dest /tmp/smp-3b/src/x; echo "code $?"
$C simulate essai --service $S
$C run essai --service $S
n=0; until $C history essai --service $S | grep -q "réussie"; do n=$((n+1)); [ $n -gt 30 ] && break; sleep 1; done
$C log essai --service $S | tail -5
$C remove essai --service $S
```
Attendu : la tâche « essai » est ajoutée par l'agent ; « imbriquee » est refusée (« La destination ne peut pas être dans la source… », code non nul) ; la simulation annonce 1 fichier et **1 suppression** (`ancien.txt`) ; l'exécution réussit ; le journal contient l'en-tête « Tâche « essai » », les lignes de rsync et « Fin : succeeded » ; la suppression répond « supprimée ».

Nettoyage : `scripts/dev-launchd.sh uninstall; rm -rf /tmp/smp-3b "$D"`.

- [ ] **Étape 2 : documenter**

`docs/manual-checks-ui.md`, ajouter une section :

```markdown
## Tâches et éditeur (3b)
- [ ] Nouvelle tâche : choisir la source et la destination avec « Choisir… » ; un dossier d'un volume réseau monté est reconnu.
- [ ] Une destination dans la source est refusée dès l'étape 1, avec le message.
- [ ] Les cartes de mode montrent l'avertissement des modes qui suppriment.
- [ ] Planification : « Prochaine exécution » change en direct.
- [ ] Résumé : la phrase est juste ; Simuler annonce les fichiers et les suppressions ; Annuler la simulation fonctionne.
- [ ] Enregistrer : la tâche apparaît au tableau de bord et dans Tâches ; un refus de l'agent reste affiché dans l'éditeur.
- [ ] Activer / désactiver, modifier, dupliquer, supprimer (confirmation) depuis l'écran Tâches.
- [ ] Modèles depuis le tableau de bord vide et depuis Tâches.
- [ ] Historique : « Voir le journal » montre les lignes du moteur ; Copier fonctionne ; une exécution antérieure à 3b affiche « Aucun journal ».
```

`README.md` : dans le tableau d'état, ligne 3 → « 3a et 3b livrées (tableau de bord, barre de menus, historique, réglages, tâches, éditeur, simulation, journal) ; 3c (copie à deux panneaux) à venir » ; dans la section « Interface », remplacer la phrase sur la création en 3b par : « Les tâches se créent dans l'app (écran Tâches ou « Créer une tâche »), avec un éditeur en 5 étapes qui simule avant d'enregistrer. L'agent est le seul à écrire `tasks.json` ; `syncmacpro-ctl add / remove / simulate / log` passent par lui. » ; ajouter dans la liste des commandes `simulate <tâche>` et `log <tâche>`.

- [ ] **Étape 3 : suite complète, commit et push**

```bash
git add README.md docs/manual-checks-ui.md
git commit -m "Documentation de 3b et vérifications manuelles" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

## Auto-revue du plan

- **Couverture du spec :** écriture par l'agent et contrat v2 (2), simulation (3), journal (4), `ctl` (5), modèle (6), brouillon, réseau, modèles (7), phrases et chaînes (8), éditeur (9), écran Tâches et ouverture (10), journal dans l'historique (11), essai réel et documentation (12), PR brouillon poussée à chaque tâche (contraintes).
- **Cohérence des types :** `TaskProblem` (1) est utilisé par `AgentCore.saveTask` (2), `simulate` (3), `TaskDraft.problems` (7) et `TaskSummaryText.problem` (8) ; `SimulationResult` (3) → `SimulationOutcome` (6) → `SimulationState` (9) ; `RunLogText` (4) → `LogOutcome` (6) → `RunLogContent` (11) ; `TaskTemplate` (7) → `TemplatesMenu` (10).
- **Risques restants :** rendu des contrôles AppKit (champs, interrupteurs) par `ImageRenderer` ; `NSOpenPanel` seulement vérifiable à la main ; CI Swift 5.10 (vues `@MainActor`, pas de `var` capturée).
