# SyncMacPro — sous-projet 3c (copie à deux panneaux) : plan d'implémentation

> **Pour les agents :** SOUS-COMPÉTENCE REQUISE : superpowers:executing-plans (exécution native, en autonomie). Les étapes utilisent la syntaxe à cases (`- [ ]`).

**Objectif :** deux panneaux de fichiers (source à gauche, destination à droite) pour copier une sélection, synchroniser un dossier, simuler avant, ou enregistrer comme tâche ; les copies sont exécutées par l'agent comme des tâches ponctuelles.

**Architecture :** l'agent gagne `runOnce` (tâche exécutée sans être enregistrée, visible dans l'état le temps de l'exécution). L'app ajoute une couche de navigation pure et testable (`DirectoryLister`, `PathCrumbs`, `FavoritesStore`, `FolderSizer`, `PaneModel`, `OneOffPlanner`) et l'écran Copie.

**Stack :** Swift 5.9 (mode 5), SwiftUI, Observation, XCTest.

**Spec :** `docs/superpowers/specs/2026-10-13-syncmacpro-two-panes-design.md`

## Contraintes globales

- macOS 14, swift-tools 5.9, mode Swift 5, aucune dépendance externe.
- CI Swift 5.10 / SDK macOS 14 : toute vue `@MainActor` ; jamais de `var` ni de `weak self` capturés dans une closure `@Sendable` / `Task` imbriquée ; expressions de test longues découpées. PR brouillon #6 poussée après **chaque** tâche.
- Contrat XPC : `agentProtocolVersion = 3`.
- Textes : `Localizer`, clés en français et en anglais ; préfixes nouveaux `copy`, `confirm`, `oneoff` ajoutés au test de complétude.
- Les 390 tests existants restent verts : `SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync" swift test`.
- Commits terminés par `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Décisions prises en rédigeant le plan

- **Ruling : validation des éléments choisis.** Avec `sourceItems`, l'imbrication se juge élément par élément (copier `/a/x.txt` vers `/a/b` est légitime ; copier le dossier `/a/b` vers `/a/b/c` ne l'est pas). Le contrôle actuel, sur le dossier source entier, refuserait à tort la première copie.
- **Ruling : glisser un seul élément à la fois** (l'élément glissé) ; la sélection multiple se copie par le bouton ou le menu. Déposer accepte plusieurs fichiers (depuis le Finder). Le glisser multiple demanderait un type de données exporté, hors de portée de SwiftUI simple.
- **Ruling : une synchronisation bloquée par le garde-fou** peut être relancée en cochant « J'ai vu la simulation : accepter les suppressions » (actif seulement après une simulation réussie) : seuil à 100 % pour cette seule exécution. Une copie ponctuelle bloquée n'a pas de validation possible ensuite (elle n'existe plus).
- **Ruling : `ctl copy`** (exécution ponctuelle en ligne de commande) sert à l'essai réel et aux scripts.
- **Ruling : sélection** gérée par `PaneModel.click(_:command:shift:)` (clic simple, ⌘ bascule, ⇧ plage), testable sans vue.

## Points de revue

1. Copier un dossier dans lui-même (ou dans un de ses sous-dossiers) : refusé avec un message clair. → tâche 6.
2. Dossier illisible, ou démonté pendant la navigation : message dans le panneau, pas de plantage. → tâche 5.
3. Sélection qui change pendant le calcul de taille : l'ancien calcul est annulé. → tâches 4, 7.
4. Copie ponctuelle interrompue par l'arrêt de l'agent : marquée interrompue, jamais relancée seule. → tâche 1.
5. Dépôt de fichiers venant de dossiers différents : une copie par dossier d'origine. → tâche 6.

---

### Tâche 1 : l'agent exécute des tâches ponctuelles (`runOnce`, contrat v3)

**Fichiers :** modifier `Sources/SyncKit/Agent/AgentProtocol.swift`, `AgentRouter.swift`, `AgentTypes.swift`, `AgentCore.swift`, `Tests/SyncKitTests/AgentProtocolTests.swift`, `Tests/SyncKitTests/AgentTaskEditingTests.swift` ; créer `Sources/SyncKit/Agent/AgentCore+OneOff.swift`, `Tests/SyncKitTests/AgentOneOffTests.swift`.

**Interfaces :** produit `agentProtocolVersion = 3` ; `AgentRequest.runOnce(SyncTask)` ; `AgentTaskInfo.isOneOff: Bool` (paramètre `isOneOff: Bool = false`, dernier de l'`init`) ; `AgentCore.runOnce(_:) throws` ; `AgentCore.lookupTask(_:) -> SyncTask?`.

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncKitTests/AgentOneOffTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentOneOffTests: XCTestCase {
    func testOneOffRunsShowsInTheStatusThenLeaves() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let copy = makeTask("Copie de 3 éléments", schedule: .manual)
        try await core.runOnce(copy)
        let running = await core.status().tasks
        XCTAssertEqual(running.map(\.name), ["Copie de 3 éléments"])
        XCTAssertEqual(running.first?.isOneOff, true)
        XCTAssertEqual(running.first?.state, .running)
        XCTAssertTrue(try h.taskStore.load().isEmpty, "une copie ponctuelle n'est pas enregistrée")
        let listed = await core.listTasks()
        XCTAssertTrue(listed.isEmpty)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        let after = await core.status().tasks
        XCTAssertTrue(after.isEmpty, "elle disparaît de l'état une fois terminée")
        XCTAssertEqual(try h.history.list(taskID: copy.id).first?.status, .succeeded)
    }

    func testOneOffCanBeStopped() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let copy = makeTask(schedule: .manual)
        try await core.runOnce(copy)
        try await core.stop(copy.id)
        await core.waitForIdle()
        XCTAssertEqual(try h.history.list(taskID: copy.id).first?.status, .stopped)
    }

    func testRefusals() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let saved = makeTask("Enregistrée", schedule: .manual)
        try h.save([saved])
        let core = h.makeCore()
        await core.start()
        do { try await core.runOnce(saved); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .alreadyRunning) }
        let copy = makeTask(schedule: .manual)
        try await core.runOnce(copy)
        do { try await core.runOnce(copy); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .alreadyRunning) }
        let nested = SyncTask(name: "n", source: .local(path: "/a"), destination: .local(path: "/a/b"))
        do { try await core.runOnce(nested); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .invalidTask(TaskProblem.nestedFolders.message))
        }
        await core.setGlobalPause(true)
        do { try await core.runOnce(makeTask(schedule: .manual)); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .globallyPaused)
        }
        await core.setGlobalPause(false)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testInterruptedOneOffIsNeverCaughtUp() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let copy = makeTask(schedule: .manual)
        try await core.runOnce(copy)
        await core.shutdown()
        XCTAssertEqual(try h.history.list(taskID: copy.id).first?.status, .interrupted)
        let next = h.makeCore()
        await next.start()
        await next.tick()
        XCTAssertEqual(h.factory.created, 1, "une copie ponctuelle n'est pas rattrapée")
        let status = await next.status().tasks
        XCTAssertTrue(status.isEmpty)
    }

    func testRunOnceThroughTheRouter() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let request = try JSONEncoder().encode(AgentRequestEnvelope(request: .runOnce(makeTask(schedule: .manual))))
        let reply = try JSONDecoder().decode(AgentResponseEnvelope.self, from: await AgentRouter.handle(request, core: core))
        XCTAssertEqual(reply.response, .ok)
        XCTAssertEqual(reply.version, 3)
        await core.waitForIdle()
    }
}
```

Dans `AgentTaskEditingTests.testRouterSavesAndRefusesOldProtocolVersions`, remplacer `XCTAssertEqual(saved.version, 2)` par `XCTAssertEqual(saved.version, agentProtocolVersion)` et `.versionMismatch(agent: 2, client: 1)` par `.versionMismatch(agent: agentProtocolVersion, client: 1)`. Dans `AgentProtocolTests.testEveryRequestSurvivesEncoding`, ajouter `.runOnce(makeTask("x"))`.

`swift test --filter AgentOneOffTests 2>&1 | grep -E "error:" | head -2` → compilation (`runOnce` inconnu).

- [ ] **Étape 2 : implémenter**

`AgentProtocol.swift` : `public let agentProtocolVersion = 3` ; `AgentRequest` + `case runOnce(SyncTask)`. `AgentRouter.swift` : `case .runOnce(let task): try await core.runOnce(task)`.

`AgentTypes.swift`, `AgentTaskInfo` : propriété `public var isOneOff: Bool` ; paramètre `isOneOff: Bool = false` à la fin de l'`init` et `self.isOneOff = isOneOff`.

`AgentCore.swift` :
1. Propriété `var oneOffs: [UUID: SyncTask] = [:]` (après `simulations`).
2. Dans `startQueued`, remplacer `guard let task = tasks.first(where: { $0.id == next.id }), jobs[task.id] == nil else { continue }` par `guard let task = lookupTask(next.id), jobs[task.id] == nil else { continue }`.
3. Dans `finish`, juste après le `persist()` qui suit `state.tasks[key] = entry` :

```swift
        // Une copie ponctuelle n'existe que le temps de son exécution : elle n'est jamais rattrapée.
        if oneOffs.removeValue(forKey: id) != nil {
            state.tasks[key] = nil
            persist()
        }
```

4. Dans `status()`, remplacer `let infos = tasks.map { task -> AgentTaskInfo in` par

```swift
        let ponctual = oneOffs.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let infos = (tasks + ponctual).map { task -> AgentTaskInfo in
```

et ajouter `isOneOff: oneOffs[task.id] != nil` à l'`AgentTaskInfo(...)` construit.

`Sources/SyncKit/Agent/AgentCore+OneOff.swift` :

```swift
import Foundation

extension AgentCore {
    /// Exécute une tâche sans l'enregistrer (copie manuelle) : même file, mêmes garde-fous, même journal ;
    /// elle figure dans l'état le temps de l'exécution, puis seulement dans l'historique.
    public func runOnce(_ task: SyncTask) throws {
        if let problem = TaskValidator.problems(in: task).first { throw AgentError.invalidTask(problem.message) }
        guard !state.paused else { throw AgentError.globallyPaused }
        guard lookupTask(task.id) == nil else { throw AgentError.alreadyRunning }
        oneOffs[task.id] = task
        queue.insert(QueuedRun(id: task.id, dueDate: .distantPast, manual: true), at: 0)
        startQueued()
        emit(.stateChanged)
    }

    /// Une tâche enregistrée ou une copie ponctuelle en cours.
    func lookupTask(_ id: UUID) -> SyncTask? {
        tasks.first(where: { $0.id == id }) ?? oneOffs[id]
    }
}
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "AgentOneOffTests|AgentProtocolTests|AgentTaskEditingTests|AgentControlTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -2` → passent ; suite complète verte.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources/SyncKit Tests/SyncKitTests
git commit -m "Agent : exécutions ponctuelles (runOnce), visibles le temps de l'exécution, jamais rattrapées (contrat v3)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 2 : `ctl copy` et `AgentModel.runOnce`

**Fichiers :** modifier `Sources/SyncKit/Agent/CtlParser.swift`, `Sources/syncmacpro-ctl/main.swift`, `Sources/SyncMacProUI/Agent/AgentModel.swift`, `Tests/SyncKitTests/CtlTests.swift` ; créer `Tests/SyncMacProUITests/AgentModelOneOffTests.swift`.

**Interfaces :** `CtlCommand.copy(OneOffRequest)` avec `struct OneOffRequest: Equatable, Sendable { source: String; destination: String; items: [String]; mirror: Bool }` ; `AgentModel.runOnce(_ tasks: [SyncTask]) async -> String?`.

- [ ] **Étape 1 : tests qui échouent**

Dans `CtlParserTests` :

```swift
    func testCopyCommand() throws {
        let invocation = try parse("copy", "--source", "/a", "--dest", "/b", "--item", "x.txt", "--item", "photos")
        XCTAssertEqual(invocation.command, .copy(OneOffRequest(source: "/a", destination: "/b", items: ["x.txt", "photos"], mirror: false)))
        XCTAssertEqual(try parse("copier", "--source", "/a", "--dest", "/b", "--mirror").command,
                       .copy(OneOffRequest(source: "/a", destination: "/b", items: [], mirror: true)))
        XCTAssertThrowsError(try parse("copy", "--source", "/a"))
    }
```

`Tests/SyncMacProUITests/AgentModelOneOffTests.swift` :

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class AgentModelOneOffTests: XCTestCase {
    func testEveryTaskIsSentThenStateIsRefreshed() async {
        let agent = FakeAgent()
        agent.setStatus(.success(makeStatus()))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let a = SyncTask(name: "a", source: .local(path: "/a"), destination: .local(path: "/c"))
        let b = SyncTask(name: "b", source: .local(path: "/b"), destination: .local(path: "/c"))
        let message = await model.runOnce([a, b])
        XCTAssertNil(message)
        XCTAssertEqual(agent.performed, [.runOnce(a), .runOnce(b)])
        XCTAssertEqual(agent.statusCalls, 1)
    }

    func testRefusalStopsAndIsReturned() async {
        let agent = FakeAgent()
        agent.setPerformError(AgentClientError.agent(.invalidTask("La destination ne peut pas être dans la source.")))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let a = SyncTask(name: "a", source: .local(path: "/a"), destination: .local(path: "/a/b"))
        let message = await model.runOnce([a, a])
        XCTAssertEqual(message, "La destination ne peut pas être dans la source.")
        XCTAssertEqual(agent.performed.count, 1, "on s'arrête au premier refus")
    }
}
```

`swift test --filter "CtlParserTests|AgentModelOneOffTests" 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`CtlParser.swift` :
1. Avant `public enum CtlCommand`, ajouter :

```swift
public struct OneOffRequest: Equatable, Sendable {
    public var source: String
    public var destination: String
    public var items: [String]
    public var mirror: Bool

    public init(source: String, destination: String, items: [String], mirror: Bool) {
        self.source = source
        self.destination = destination
        self.items = items
        self.mirror = mirror
    }
}
```

2. `CtlCommand` + `case copy(OneOffRequest)` ; alias `"copier": "copy"` ; `valued` + `"item"` ; `flags` + `"mirror"`.
3. Les options répétées : remplacer `var values: [String: String] = [:]` par `var values: [String: String] = [:]` **et** `var items: [String] = []`, et dans la boucle, quand `name == "item"`, faire `items.append(arguments[index])` au lieu de `values[name] = …` (puis `index += 1`).
4. Dans le `switch name` : 

```swift
        case "copy":
            guard let source = values["source"] else { throw CtlParseError.missingValue("--source") }
            guard let destination = values["dest"] else { throw CtlParseError.missingValue("--dest") }
            return invocation(.copy(OneOffRequest(
                source: (source as NSString).expandingTildeInPath, destination: (destination as NSString).expandingTildeInPath,
                items: items, mirror: flagged.contains("mirror")
            )))
```

5. `usage` + `  copy --source DOSSIER --dest DOSSIER [--item NOM]... [--mirror]   copie ponctuelle par l'agent`.

`Sources/syncmacpro-ctl/main.swift`, nouveau cas :

```swift
    case .copy(let request):
        let source = URL(fileURLWithPath: request.source), destination = URL(fileURLWithPath: request.destination)
        let what = request.items.isEmpty ? source.lastPathComponent : request.items.joined(separator: ", ")
        var task = SyncTask(
            name: (request.mirror ? "Synchronisation de " : "Copie de ") + "\(what) vers \(destination.lastPathComponent)",
            source: .local(path: source.path), destination: .local(path: destination.path),
            sourceItems: request.items, mode: request.mirror ? .mirror : .copy
        )
        task.notifications = .always
        try await client.perform(.runOnce(task))
        print("« \(task.name) » lancée (suivre avec : syncmacpro-ctl watch).")
```

`AgentModel.swift`, avant `static func describe` :

```swift
    /// Copies ponctuelles : `nil` si l'agent les a toutes prises en charge, sinon le premier refus.
    public func runOnce(_ tasks: [SyncTask]) async -> String? {
        for task in tasks {
            do { try await agent.perform(.runOnce(task)) } catch { return Self.describe(error) }
        }
        await refreshNow()
        return nil
    }
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "CtlParserTests|AgentModelOneOffTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -2` → passent ; `swift build` propre.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "ctl copy et AgentModel.runOnce : copies ponctuelles par l'agent" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 3 : lister un dossier, barre de chemin, emplacements

**Fichiers :** créer `Sources/SyncMacProUI/Browsing/DirectoryLister.swift`, `Sources/SyncMacProUI/Browsing/PathCrumbs.swift`, `Sources/SyncMacProUI/Browsing/StandardLocations.swift` ; tester `Tests/SyncMacProUITests/BrowsingTests.swift`.

**Interfaces :** `struct DirectoryItem: Identifiable, Hashable, Sendable` (`url`, `name`, `isDirectory`, `size: Int64?`, `modified: Date?`, `isHidden`) ; `enum DirectoryLister { static func list(_:showHidden:) throws -> [DirectoryItem] }` ; `struct Crumb: Hashable` (`name`, `url`) ; `enum PathCrumbs { static func crumbs(for:volumeName:) -> [Crumb] }` ; `struct Place: Identifiable, Hashable` (`url`, `name`, `systemImage`) ; `enum StandardLocations { static func folders() -> [Place]; static func volumes() -> [Place] }`.

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncMacProUITests/BrowsingTests.swift` :

```swift
import XCTest
@testable import SyncMacProUI

final class BrowsingTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("browse-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("App.app/Contents"), withIntermediateDirectories: true)
        try "abc".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "zz".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent(".cache"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Locked").path)
        try? FileManager.default.removeItem(at: root)
    }

    func testFoldersFirstThenFilesByName() throws {
        let items = try DirectoryLister.list(root, showHidden: false)
        XCTAssertEqual(items.map(\.name), ["Sub", "a.txt", "App.app", "b.txt"])
        XCTAssertEqual(items.first?.isDirectory, true)
        XCTAssertEqual(items.first { $0.name == "App.app" }?.isDirectory, false, "un paquet se comporte comme un fichier")
        XCTAssertEqual(items.first { $0.name == "a.txt" }?.size, 3)
        XCTAssertNil(items.first?.size, "pas de taille pour un dossier")
    }

    func testHiddenFilesOnDemand() throws {
        let items = try DirectoryLister.list(root, showHidden: true)
        XCTAssertTrue(items.contains { $0.name == ".cache" && $0.isHidden })
    }

    func testUnreadableFolderThrows() throws {
        let locked = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertThrowsError(try DirectoryLister.list(locked, showHidden: false))
    }

    func testCrumbsOnTheStartupDisk() {
        let crumbs = PathCrumbs.crumbs(for: URL(fileURLWithPath: "/Users/moi/Photos"), volumeName: { _ in "Macintosh HD" })
        XCTAssertEqual(crumbs.map(\.name), ["Macintosh HD", "Users", "moi", "Photos"])
        XCTAssertEqual(crumbs.last?.url.path, "/Users/moi/Photos")
        XCTAssertEqual(crumbs.first?.url.path, "/")
    }

    func testCrumbsOnAMountedVolume() {
        let crumbs = PathCrumbs.crumbs(for: URL(fileURLWithPath: "/Volumes/NAS/Photos/2024"), volumeName: { _ in "ignoré" })
        XCTAssertEqual(crumbs.map(\.name), ["NAS", "Photos", "2024"])
        XCTAssertEqual(crumbs.first?.url.path, "/Volumes/NAS")
    }

    func testCrumbsOfTheRoot() {
        XCTAssertEqual(PathCrumbs.crumbs(for: URL(fileURLWithPath: "/"), volumeName: { _ in "Disque" }).map(\.name), ["Disque"])
    }

    func testStandardLocationsExist() {
        let folders = StandardLocations.folders()
        XCTAssertFalse(folders.isEmpty)
        XCTAssertTrue(folders.allSatisfy { !$0.name.isEmpty })
        XCTAssertTrue(folders.contains { $0.url.path == NSHomeDirectory() })
        _ = StandardLocations.volumes()
    }
}
```

`swift test --filter BrowsingTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Browsing/DirectoryLister.swift` :

```swift
import Foundation

public struct DirectoryItem: Identifiable, Hashable, Sendable {
    public var url: URL
    public var name: String
    /// Vrai pour un dossier dans lequel on peut entrer ; un paquet (.app) est un fichier.
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    public var isHidden: Bool
    public var id: URL { url }

    public init(url: URL, name: String, isDirectory: Bool, size: Int64?, modified: Date?, isHidden: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isHidden = isHidden
    }
}

public enum DirectoryLister {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
    ]

    /// Dossiers d'abord, puis fichiers, par nom (ordre du Finder).
    public static func list(_ folder: URL, showHidden: Bool) throws -> [DirectoryItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles]
        )
        let items = urls.map { found -> DirectoryItem in
            // Les URL suivent la forme du dossier ouvert (« /var » et non « /private/var ») : la sélection les compare.
            let url = folder.appendingPathComponent(found.lastPathComponent)
            let values = try? found.resourceValues(forKeys: Set(keys))
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            return DirectoryItem(
                url: url, name: url.lastPathComponent, isDirectory: isDirectory,
                size: isDirectory ? nil : values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                isHidden: values?.isHidden ?? url.lastPathComponent.hasPrefix(".")
            )
        }
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
```

`Sources/SyncMacProUI/Browsing/PathCrumbs.swift` :

```swift
import Foundation

public struct Crumb: Hashable, Sendable {
    public let name: String
    public let url: URL
}

/// La barre de chemin : le volume, puis chaque dossier.
public enum PathCrumbs {
    public static func systemVolumeName(_ url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    public static func crumbs(for url: URL, volumeName: (URL) -> String? = systemVolumeName) -> [Crumb] {
        let parts = url.standardizedFileURL.pathComponents
        var crumbs: [Crumb] = []
        var current: URL
        var rest: ArraySlice<String>
        if parts.count >= 3, parts[1] == "Volumes" {
            current = URL(fileURLWithPath: "/Volumes/\(parts[2])")
            crumbs.append(Crumb(name: parts[2], url: current))
            rest = parts.dropFirst(3)
        } else {
            current = URL(fileURLWithPath: "/")
            crumbs.append(Crumb(name: volumeName(current) ?? "/", url: current))
            rest = parts.dropFirst(1)
        }
        for part in rest {
            current.appendPathComponent(part)
            crumbs.append(Crumb(name: part, url: current))
        }
        return crumbs
    }
}
```

`Sources/SyncMacProUI/Browsing/StandardLocations.swift` :

```swift
import Foundation

public struct Place: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let systemImage: String
    public var id: URL { url }
}

public enum StandardLocations {
    /// Départ, Bureau, Documents, Téléchargements (noms affichés par le Finder).
    public static func folders() -> [Place] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates: [(URL, String)] = [
            (home, "house"),
            (home.appendingPathComponent("Desktop"), "desktopcomputer"),
            (home.appendingPathComponent("Documents"), "doc"),
            (home.appendingPathComponent("Downloads"), "arrow.down.circle"),
        ]
        return candidates.compactMap { url, image in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Place(url: url, name: FileManager.default.displayName(atPath: url.path), systemImage: image)
        }
    }

    /// Volumes montés visibles (disque de démarrage, disques externes, partages réseau).
    public static func volumes() -> [Place] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsLocalKey], options: [.skipHiddenVolumes]
        ) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsLocalKey])
            let network = values?.volumeIsLocal == false
            return Place(
                url: url, name: values?.volumeName ?? url.lastPathComponent,
                systemImage: network ? "network" : "externaldrive"
            )
        }
    }
}
```

- [ ] **Étape 3 : vérifier** — `swift test --filter BrowsingTests 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | tail -4` → 7 tests passent.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources/SyncMacProUI/Browsing Tests/SyncMacProUITests/BrowsingTests.swift
git commit -m "Interface : lister un dossier, barre de chemin, emplacements standard et volumes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 4 : favoris et calcul de taille

**Fichiers :** créer `Sources/SyncMacProUI/Browsing/FavoritesStore.swift`, `Sources/SyncMacProUI/Browsing/FolderSizer.swift` ; tester `Tests/SyncMacProUITests/FavoritesAndSizeTests.swift`.

**Interfaces :** `final class FavoritesStore` (`init(defaults:)`, `list() -> [URL]`, `add(_:)`, `remove(_:)`, `contains(_:)`) ; `@MainActor @Observable final class FavoritesModel` (`favorites: [URL]`, `add`, `remove`, `contains`) ; `struct SizeTotal: Equatable, Sendable` (`bytes`, `files`, `folders`) ; `enum FolderSizer { static func total(of: [URL]) throws -> SizeTotal }` (vérifie l'annulation de la tâche courante, ne suit pas les liens).

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncMacProUITests/FavoritesAndSizeTests.swift` :

```swift
import XCTest
@testable import SyncMacProUI

final class FavoritesAndSizeTests: XCTestCase {
    func defaults() -> UserDefaults {
        let name = "favoris-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testFavoritesKeepOrderWithoutDuplicates() {
        let store = FavoritesStore(defaults: defaults())
        store.add(URL(fileURLWithPath: "/Volumes/NAS/Photos"))
        store.add(URL(fileURLWithPath: "/Users/moi/Documents"))
        store.add(URL(fileURLWithPath: "/Volumes/NAS/Photos/"))
        XCTAssertEqual(store.list().map(\.path), ["/Volumes/NAS/Photos", "/Users/moi/Documents"])
        XCTAssertTrue(store.contains(URL(fileURLWithPath: "/Users/moi/Documents")))
        store.remove(URL(fileURLWithPath: "/Volumes/NAS/Photos"))
        XCTAssertEqual(store.list().map(\.path), ["/Users/moi/Documents"])
    }

    @MainActor
    func testFavoritesModelPublishesChanges() {
        let model = FavoritesModel(store: FavoritesStore(defaults: defaults()))
        model.add(URL(fileURLWithPath: "/a"))
        XCTAssertEqual(model.favorites.map(\.path), ["/a"])
        model.remove(URL(fileURLWithPath: "/a"))
        XCTAssertTrue(model.favorites.isEmpty)
    }

    func testSizeCountsFilesAndFoldersButNotLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("photos/2024"), withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: root.appendingPathComponent("photos/a.jpg"))
        try Data(count: 500).write(to: root.appendingPathComponent("photos/2024/b.jpg"))
        try Data(count: 7).write(to: root.appendingPathComponent("note.txt"))
        let big = root.appendingPathComponent("gros.bin")
        try Data(count: 50_000).write(to: big)
        try fm.createSymbolicLink(at: root.appendingPathComponent("photos/lien.bin"), withDestinationURL: big)

        let total = try FolderSizer.total(of: [root.appendingPathComponent("photos"), root.appendingPathComponent("note.txt")])
        XCTAssertEqual(total.bytes, 1_507)
        XCTAssertEqual(total.files, 3)
        XCTAssertEqual(total.folders, 2)
    }

    func testSizeStopsWhenCancelled() async {
        let task = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try FolderSizer.total(of: [URL(fileURLWithPath: NSHomeDirectory())]); return nil } catch { return error }
        }
        let error = await task.value
        XCTAssertTrue(error is CancellationError)
    }
}
```

`swift test --filter FavoritesAndSizeTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Browsing/FavoritesStore.swift` :

```swift
import Foundation
import Observation

/// Dossiers favoris, partagés par les deux panneaux, conservés dans les réglages de l'app.
public final class FavoritesStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "favoriteFolders"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public func list() -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    public func contains(_ url: URL) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(normalized(url))
    }

    public func add(_ url: URL) {
        var paths = defaults.stringArray(forKey: key) ?? []
        let path = normalized(url)
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths, forKey: key)
    }

    public func remove(_ url: URL) {
        let path = normalized(url)
        defaults.set((defaults.stringArray(forKey: key) ?? []).filter { $0 != path }, forKey: key)
    }
}

@MainActor
@Observable
public final class FavoritesModel {
    public private(set) var favorites: [URL]
    @ObservationIgnored private let store: FavoritesStore

    public init(store: FavoritesStore = FavoritesStore()) {
        self.store = store
        favorites = store.list()
    }

    public func add(_ url: URL) {
        store.add(url)
        favorites = store.list()
    }

    public func remove(_ url: URL) {
        store.remove(url)
        favorites = store.list()
    }

    public func contains(_ url: URL) -> Bool { store.contains(url) }
}
```

`Sources/SyncMacProUI/Browsing/FolderSizer.swift` :

```swift
import Foundation

public struct SizeTotal: Equatable, Sendable {
    public var bytes: Int64 = 0
    public var files = 0
    public var folders = 0

    public init(bytes: Int64 = 0, files: Int = 0, folders: Int = 0) {
        self.bytes = bytes
        self.files = files
        self.folders = folders
    }
}

/// Taille d'une sélection. À appeler hors du fil principal ; s'arrête dès que la tâche courante est annulée.
/// Les liens symboliques ne sont ni suivis ni comptés (rsync les copie comme liens).
public enum FolderSizer {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    public static func total(of urls: [URL]) throws -> SizeTotal {
        var total = SizeTotal()
        for url in urls {
            try Task.checkCancellation()
            add(url, to: &total)
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                  let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
            else { continue }
            var count = 0
            for case let child as URL in enumerator {
                count += 1
                if count % 200 == 0 { try Task.checkCancellation() }
                add(child, to: &total)
            }
        }
        return total
    }

    private static func add(_ url: URL, to total: inout SizeTotal) {
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isSymbolicLink == true { return }
        if values?.isDirectory == true {
            total.folders += 1
        } else {
            total.files += 1
            total.bytes += Int64(values?.fileSize ?? 0)
        }
    }
}
```

- [ ] **Étape 3 : vérifier** — `swift test --filter FavoritesAndSizeTests 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | tail -4` → 4 tests passent.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources/SyncMacProUI/Browsing Tests/SyncMacProUITests/FavoritesAndSizeTests.swift
git commit -m "Interface : dossiers favoris et calcul de taille annulable" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 5 : le modèle d'un panneau (navigation, sélection, erreurs)

**Fichiers :** créer `Sources/SyncMacProUI/Browsing/PaneModel.swift` ; tester `Tests/SyncMacProUITests/PaneModelTests.swift`.

**Interfaces :** `enum PaneProblem: Equatable { unreadable, vanished }` ; `@MainActor @Observable final class PaneModel` : `folder`, `items`, `selection: Set<URL>`, `showHidden`, `problem`, `canGoUp`, `selectedItems`, `init(folder:)`, `open(_:)`, `goUp()`, `reload()`, `click(_:command:shift:)`, `selectAll()`.

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncMacProUITests/PaneModelTests.swift` :

```swift
import XCTest
@testable import SyncMacProUI

@MainActor
final class PaneModelTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pane-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sub/Deep"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", ".hidden"] {
            try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Locked").path)
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func testOpensAndGoesUp() {
        let pane = PaneModel(folder: root)
        XCTAssertEqual(pane.items.map(\.name), ["Sub", "a.txt", "b.txt", "c.txt", "d.txt"])
        pane.open(url("Sub"))
        XCTAssertEqual(pane.items.map(\.name), ["Deep"])
        pane.goUp()
        XCTAssertEqual(pane.folder.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertNil(pane.problem)
    }

    func testHiddenFilesToggle() {
        let pane = PaneModel(folder: root)
        pane.showHidden = true
        XCTAssertTrue(pane.items.contains { $0.name == ".hidden" })
        pane.showHidden = false
        XCTAssertFalse(pane.items.contains { $0.name == ".hidden" })
    }

    func testClickSelectionWithCommandAndShift() {
        let pane = PaneModel(folder: root)
        pane.click(url("a.txt"), command: false, shift: false)
        XCTAssertEqual(pane.selection, [url("a.txt")])
        pane.click(url("c.txt"), command: true, shift: false)
        XCTAssertEqual(pane.selection, [url("a.txt"), url("c.txt")])
        pane.click(url("a.txt"), command: true, shift: false)
        XCTAssertEqual(pane.selection, [url("c.txt")])
        pane.click(url("b.txt"), command: false, shift: false)
        pane.click(url("d.txt"), command: false, shift: true)
        XCTAssertEqual(pane.selection, [url("b.txt"), url("c.txt"), url("d.txt")], "⇧ : plage depuis le dernier clic")
        pane.selectAll()
        XCTAssertEqual(pane.selection.count, 5)
        XCTAssertEqual(pane.selectedItems.map(\.name), ["Sub", "a.txt", "b.txt", "c.txt", "d.txt"])
    }

    func testOpeningAFolderClearsTheSelection() {
        let pane = PaneModel(folder: root)
        pane.click(url("a.txt"), command: false, shift: false)
        pane.open(url("Sub"))
        XCTAssertTrue(pane.selection.isEmpty)
    }

    func testSelectionKeepsOnlyExistingItemsAfterReload() throws {
        let pane = PaneModel(folder: root)
        pane.click(url("a.txt"), command: false, shift: false)
        pane.click(url("b.txt"), command: true, shift: false)
        try FileManager.default.removeItem(at: url("a.txt"))
        pane.reload()
        XCTAssertEqual(pane.selection, [url("b.txt")])
    }

    func testUnreadableFolder() throws {
        let locked = url("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let pane = PaneModel(folder: root)
        pane.open(locked)
        XCTAssertEqual(pane.problem, .unreadable)
        XCTAssertTrue(pane.items.isEmpty)
    }

    func testVanishedFolderClimbsToTheFirstExistingParent() throws {
        let pane = PaneModel(folder: root)
        pane.open(url("Sub/Deep"))
        try FileManager.default.removeItem(at: url("Sub"))
        pane.reload()
        XCTAssertEqual(pane.problem, .vanished)
        XCTAssertEqual(pane.folder.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertFalse(pane.items.isEmpty)
    }
}
```

`swift test --filter PaneModelTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Browsing/PaneModel.swift` :

```swift
import Foundation
import Observation

public enum PaneProblem: Equatable, Sendable {
    /// Droits d'accès insuffisants.
    case unreadable
    /// Le dossier a disparu (volume démonté…) : le panneau est remonté au premier dossier existant.
    case vanished
}

/// Un panneau de fichiers : dossier courant, contenu, sélection.
@MainActor
@Observable
public final class PaneModel {
    public private(set) var folder: URL
    public private(set) var items: [DirectoryItem] = []
    public var selection: Set<URL> = []
    public private(set) var problem: PaneProblem?
    public var showHidden = false {
        didSet { reload() }
    }
    @ObservationIgnored private var anchor: URL?

    public init(folder: URL) {
        self.folder = folder
        reload()
    }

    public var canGoUp: Bool { folder.standardizedFileURL.path != "/" }

    public var selectedItems: [DirectoryItem] { items.filter { selection.contains($0.url) } }

    public func open(_ url: URL) {
        folder = url
        selection = []
        anchor = nil
        reload()
    }

    public func goUp() {
        guard canGoUp else { return }
        open(folder.deletingLastPathComponent())
    }

    public func reload() {
        problem = nil
        var target = folder
        if !FileManager.default.fileExists(atPath: target.path) {
            while !FileManager.default.fileExists(atPath: target.path) && target.path != "/" {
                target = target.deletingLastPathComponent()
            }
            folder = target
            problem = .vanished
        }
        do {
            items = try DirectoryLister.list(target, showHidden: showHidden)
        } catch {
            items = []
            problem = .unreadable
        }
        let existing = Set(items.map(\.url))
        selection = selection.filter { existing.contains($0) }
    }

    /// Clic simple : ne garde que l'élément ; ⌘ : l'ajoute ou le retire ; ⇧ : plage depuis le dernier clic.
    public func click(_ url: URL, command: Bool, shift: Bool) {
        if shift, let anchor, let from = items.firstIndex(where: { $0.url == anchor }),
           let to = items.firstIndex(where: { $0.url == url }) {
            let range = min(from, to)...max(from, to)
            selection = Set(items[range].map(\.url))
            return
        }
        if command {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else {
            selection = [url]
        }
        anchor = url
    }

    public func selectAll() {
        selection = Set(items.map(\.url))
    }
}
```

- [ ] **Étape 3 : vérifier** — `swift test --filter PaneModelTests 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | tail -4` → 7 tests passent.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources/SyncMacProUI/Browsing/PaneModel.swift Tests/SyncMacProUITests/PaneModelTests.swift
git commit -m "Interface : modèle de panneau (navigation, sélection ⌘ et ⇧, dossier illisible ou disparu)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 6 : de la sélection aux tâches ponctuelles ; validation élément par élément

**Fichiers :** créer `Sources/SyncMacProUI/Browsing/OneOffPlanner.swift`, `Tests/SyncMacProUITests/OneOffPlannerTests.swift` ; modifier `Sources/SyncKit/TaskValidator.swift`, `Tests/SyncKitTests/TaskValidatorTests.swift`, les deux `Localizable.strings`.

**Interfaces :** `enum OneOffPlanner` : `copyTasks(items: [URL], to: URL, resolver:localizer:) -> [SyncTask]`, `syncTask(from: URL, to: URL, acceptDeletions: Bool, resolver:localizer:) -> SyncTask`. `TaskValidator` : avec `sourceItems`, l'imbrication et l'égalité se jugent pour chaque élément (`source/élément`).

- [ ] **Étape 1 : tests qui échouent**

Dans `TaskValidatorTests`, ajouter :

```swift
    func testSelectedItemsAreJudgedOneByOne() {
        var intoSibling = task(source: .local(path: "/a"), destination: .local(path: "/a/b"))
        intoSibling.sourceItems = ["x.txt", "photos"]
        XCTAssertEqual(TaskValidator.problems(in: intoSibling), [], "copier des éléments de /a vers /a/b est légitime")
        var intoItself = task(source: .local(path: "/a"), destination: .local(path: "/a/photos/copie"))
        intoItself.sourceItems = ["photos"]
        XCTAssertEqual(TaskValidator.problems(in: intoItself), [.nestedFolders])
        var ontoItself = task(source: .local(path: "/a"), destination: .local(path: "/a/photos"))
        ontoItself.sourceItems = ["photos"]
        XCTAssertEqual(TaskValidator.problems(in: ontoItself), [.sameSourceAndDestination])
        var parentOfSource = task(source: .local(path: "/a/b"), destination: .local(path: "/a"))
        parentOfSource.sourceItems = ["x.txt"]
        XCTAssertEqual(TaskValidator.problems(in: parentOfSource), [.nestedFolders], "la destination contient la source")
    }
```

`Tests/SyncMacProUITests/OneOffPlannerTests.swift` :

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

final class OneOffPlannerTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func testSelectionFromOneFolderIsOneCopy() {
        let tasks = OneOffPlanner.copyTasks(
            items: [URL(fileURLWithPath: "/Users/moi/Photos/a.jpg"), URL(fileURLWithPath: "/Users/moi/Photos/2024")],
            to: URL(fileURLWithPath: "/Volumes/NAS/Photos"), resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].source, .local(path: "/Users/moi/Photos"))
        XCTAssertEqual(tasks[0].destination, .local(path: "/Volumes/NAS/Photos"))
        XCTAssertEqual(tasks[0].sourceItems, ["2024", "a.jpg"])
        XCTAssertEqual(tasks[0].mode, .copy)
        XCTAssertEqual(tasks[0].schedule, .manual)
        XCTAssertEqual(tasks[0].name, "Copie de 2 éléments vers Photos")
        XCTAssertEqual(TaskValidator.problems(in: tasks[0]), [])
    }

    func testItemsFromSeveralFoldersGiveOneCopyPerFolder() {
        let tasks = OneOffPlanner.copyTasks(
            items: [URL(fileURLWithPath: "/a/x.txt"), URL(fileURLWithPath: "/b/y.txt"), URL(fileURLWithPath: "/a/z.txt")],
            to: URL(fileURLWithPath: "/dest"), resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(tasks.map(\.source), [.local(path: "/a"), .local(path: "/b")])
        XCTAssertEqual(tasks.map(\.sourceItems), [["x.txt", "z.txt"], ["y.txt"]])
        XCTAssertEqual(tasks[1].name, "Copie de y.txt vers dest")
        XCTAssertNotEqual(tasks[0].id, tasks[1].id)
    }

    func testCopyingAFolderIntoItselfIsRefused() {
        let tasks = OneOffPlanner.copyTasks(
            items: [URL(fileURLWithPath: "/a/photos")], to: URL(fileURLWithPath: "/a/photos/copie"),
            resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(TaskValidator.problems(in: tasks[0]), [.nestedFolders])
    }

    func testSyncIsAMirrorOfTheWholeFolder() {
        let task = OneOffPlanner.syncTask(
            from: URL(fileURLWithPath: "/Users/moi/Photos"), to: URL(fileURLWithPath: "/Volumes/NAS/Photos"),
            acceptDeletions: false, resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(task.mode, .mirror)
        XCTAssertEqual(task.sourceItems, [])
        XCTAssertEqual(task.options.deleteThresholdPercent, TaskOptions().deleteThresholdPercent)
        XCTAssertEqual(task.name, "Synchronisation de Photos vers Photos")
        let accepted = OneOffPlanner.syncTask(
            from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b"), acceptDeletions: true,
            resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(accepted.options.deleteThresholdPercent, 100)
    }
}
```

`swift test --filter "OneOffPlannerTests|TaskValidatorTests" 2>&1 | grep -E "error:|Executed .* tests" | head -3` → compilation (`OneOffPlanner` inconnu) ; une fois le planificateur écrit (étape 2, partie app), le test de validation doit échouer tant que la partie SyncKit n'est pas faite.

- [ ] **Étape 2 : implémenter**

`TaskValidator.swift`, dans `problems(in:)`, remplacer le bloc qui compare `source` et `destination` (calculés avec `location(...)`) par :

```swift
                let destination = location(task.destination)
                // Avec des éléments choisis, chacun est jugé : copier /a/x.txt vers /a/b est légitime.
                let sources: [Location]
                if task.sourceItems.isEmpty {
                    sources = [location(task.source)]
                } else {
                    let base = location(task.source)
                    sources = task.sourceItems.map { item in
                        Location(namespace: base.namespace, parts: base.parts + item.lowercased().split(separator: "/").map(String.init))
                    }
                }
                let parent = location(task.source)
                if sources.contains(where: { $0.namespace == destination.namespace && $0.parts == destination.parts }) {
                    found.append(.sameSourceAndDestination)
                } else if sources.contains(where: { source in
                    source.namespace == destination.namespace && destination.parts.starts(with: source.parts)
                }) || (parent.namespace == destination.namespace && parent.parts.starts(with: destination.parts)
                       && parent.parts != destination.parts) {
                    found.append(.nestedFolders)
                }
```

Remarque : pour les services en ligne, les éléments gardent leur casse (`base.parts + item.split(...)`) ; pour les disques, la casse est ignorée comme ailleurs. Adapter : utiliser `item.lowercased()` seulement quand `base.namespace` est vide.

`Sources/SyncMacProUI/Browsing/OneOffPlanner.swift` :

```swift
import Foundation
import SyncKit

/// Transforme une sélection de fichiers (ou un dépôt) en copies ponctuelles pour l'agent.
public enum OneOffPlanner {
    /// Une copie par dossier d'origine (un dépôt depuis le Finder peut mêler plusieurs dossiers).
    public static func copyTasks(
        items: [URL], to destination: URL, resolver: EndpointResolver = .system, localizer: Localizer = .system
    ) -> [SyncTask] {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for item in items {
            let parent = item.standardizedFileURL.deletingLastPathComponent().path
            if groups[parent] == nil { order.append(parent) }
            groups[parent, default: []].append(item.lastPathComponent)
        }
        return order.map { parent in
            let names = (groups[parent] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let what = names.count == 1 ? names[0] : localizer.format("oneoff.items", names.count)
            var task = SyncTask(
                name: localizer.format("oneoff.copy.name", what, destination.lastPathComponent),
                source: resolver.endpoint(forPath: parent),
                destination: resolver.endpoint(forPath: destination.standardizedFileURL.path),
                sourceItems: names, mode: .copy, schedule: .manual
            )
            task.notifications = .always
            return task
        }
    }

    /// Le dossier de gauche entier vers celui de droite, en miroir. `acceptDeletions` : l'utilisateur a vu la simulation
    /// et accepte les suppressions qu'elle annonce (seuil à 100 % pour cette seule exécution).
    public static func syncTask(
        from source: URL, to destination: URL, acceptDeletions: Bool,
        resolver: EndpointResolver = .system, localizer: Localizer = .system
    ) -> SyncTask {
        var task = SyncTask(
            name: localizer.format("oneoff.sync.name", source.lastPathComponent, destination.lastPathComponent),
            source: resolver.endpoint(forPath: source.standardizedFileURL.path),
            destination: resolver.endpoint(forPath: destination.standardizedFileURL.path),
            mode: .mirror, schedule: .manual
        )
        task.notifications = .always
        if acceptDeletions { task.options.deleteThresholdPercent = 100 }
        return task
    }
}
```

Chaînes à ajouter (fin des fichiers) — `fr.lproj` :

```
"oneoff.copy.name" = "Copie de %@ vers %@";
"oneoff.sync.name" = "Synchronisation de %@ vers %@";
"oneoff.items" = "%d éléments";
```

`en.lproj` :

```
"oneoff.copy.name" = "Copy of %@ to %@";
"oneoff.sync.name" = "Sync of %@ to %@";
"oneoff.items" = "%d items";
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "OneOffPlannerTests|TaskValidatorTests|ReviewFix3bValidatorTests" 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | tail -4` → tous passent.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "Copies ponctuelles depuis une sélection (une par dossier d'origine) ; validation élément par élément" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 7 : les vues d'un panneau et la barre d'état

**Fichiers :** créer `Sources/SyncMacProUI/Browsing/FreeSpace.swift`, `Sources/SyncMacProUI/Views/FilePaneView.swift`, `Sources/SyncMacProUI/Views/CopyStatusBar.swift` ; modifier `OneOffPlanner.swift`, les deux `Localizable.strings`, `Tests/SyncMacProUITests/StringsCompletenessTests.swift` ; tester `Tests/SyncMacProUITests/CopyRenderTests.swift`.

**Interfaces :** consomme `PaneModel`, `DirectoryItem`, `PathCrumbs`, `FavoritesModel`, `StandardLocations` (tâches 3 à 5). Produit :
- `enum FreeSpace { static func available(at: URL) -> Int64? }` ;
- `OneOffPlanner.droppable(_ urls: [URL], into folder: URL) -> [URL]` (fichiers locaux seulement, sans ceux déjà dans `folder`, sans `folder` lui-même ni ses parents) ;
- `enum SizeState: Equatable { none, computing, done(SizeTotal), failed }` ;
- `struct CopyStatusBar: View` (`count`, `size: SizeState`, `free: Int64?`, `localizer`) ;
- `struct PathBar: View` (`crumbs`, `onOpen: (URL) -> Void`) ;
- `struct FileListBody: View` (`items`, `selection`, `problem`, `localizer`, `onClick(URL, command, shift)`, `onOpen(DirectoryItem)`, `menu: (DirectoryItem) -> PaneMenu`) — contenu sans défilement ;
- `struct PaneMenu` (`copyToOther`, `simulate`, `open: (() -> Void)?`, `addFavorite: (() -> Void)?`, `reveal`) ;
- `struct FilePaneView: View` (`pane: PaneModel`, `favorites: FavoritesModel`, `localizer`, `onDrop: ([URL]) -> Void`, `menu: (DirectoryItem) -> PaneMenu`).

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncMacProUITests/CopyRenderTests.swift` :

```swift
import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class CopyRenderTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func items() -> [DirectoryItem] {
        let base = URL(fileURLWithPath: "/Users/moi/Photos")
        return [
            DirectoryItem(url: base.appendingPathComponent("2024"), name: "2024", isDirectory: true, size: nil,
                          modified: Date(timeIntervalSince1970: 1_700_000_000), isHidden: false),
            DirectoryItem(url: base.appendingPathComponent("plage.jpg"), name: "plage.jpg", isDirectory: false,
                          size: 3_400_000, modified: Date(timeIntervalSince1970: 1_700_000_000), isHidden: false),
        ]
    }

    func noMenu(_ item: DirectoryItem) -> PaneMenu {
        PaneMenu(copyToOther: {}, simulate: {}, open: nil, addFavorite: nil, reveal: {})
    }

    func testFileListRenders() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = FileListBody(
                items: items(), selection: [items()[1].url], problem: nil, localizer: fr,
                onClick: { _, _, _ in }, onOpen: { _ in }, menu: noMenu
            )
            assertNotBlank(try render(view, name: "copy-list", size: CGSize(width: 420, height: 200), scheme: scheme))
        }
    }

    func testProblemsRender() throws {
        for problem in [PaneProblem.unreadable, .vanished] {
            let view = FileListBody(items: [], selection: [], problem: problem, localizer: fr,
                                    onClick: { _, _, _ in }, onOpen: { _ in }, menu: noMenu)
            assertNotBlank(try render(view, name: "copy-problem-\(problem)", size: CGSize(width: 420, height: 160), scheme: .light))
        }
    }

    func testPathBarRenders() throws {
        let crumbs = PathCrumbs.crumbs(for: URL(fileURLWithPath: "/Volumes/NAS/Photos/2024"))
        let view = PathBar(crumbs: crumbs, onOpen: { _ in })
        assertNotBlank(try render(view, name: "copy-path", size: CGSize(width: 420, height: 32), scheme: .light))
    }

    func testStatusBarRendersEveryState() throws {
        let states: [SizeState] = [.none, .computing, .done(SizeTotal(bytes: 3_400_000, files: 12, folders: 2)), .failed]
        for (index, state) in states.enumerated() {
            let view = CopyStatusBar(count: index == 0 ? 0 : 3, size: state, free: 120_000_000_000, localizer: fr)
            assertNotBlank(try render(view, name: "copy-status-\(index)", size: CGSize(width: 700, height: 32), scheme: .light))
        }
    }

    func testStatusBarSentences() {
        XCTAssertEqual(CopyStatusBar.sizeText(.done(SizeTotal(bytes: 2_000, files: 3, folders: 1)), localizer: fr),
                       "3 fichiers, \(fr.bytes(2_000))")
        XCTAssertEqual(CopyStatusBar.sizeText(.computing, localizer: fr), "Calcul de la taille…")
        XCTAssertNil(CopyStatusBar.sizeText(.none, localizer: fr))
    }
}
```

Dans `OneOffPlannerTests`, ajouter :

```swift
    func testDroppableKeepsOnlyWhatCanBeCopiedThere() {
        let folder = URL(fileURLWithPath: "/dest/photos")
        let dropped = [
            URL(fileURLWithPath: "/a/x.txt"),
            URL(fileURLWithPath: "/dest/photos/deja.txt"),
            URL(fileURLWithPath: "/dest/photos"),
            URL(fileURLWithPath: "/dest"),
            URL(string: "https://exemple.fr/page")!,
        ]
        XCTAssertEqual(OneOffPlanner.droppable(dropped, into: folder).map(\.path), ["/a/x.txt"])
    }
```

Et un test de l'espace libre (dans `CopyRenderTests`) :

```swift
    func testFreeSpaceOfTheHomeFolder() {
        XCTAssertGreaterThan(FreeSpace.available(at: URL(fileURLWithPath: NSHomeDirectory())) ?? 0, 0)
        XCTAssertNil(FreeSpace.available(at: URL(fileURLWithPath: "/n-existe-pas-\(UUID().uuidString)")))
    }
```

`swift test --filter "CopyRenderTests|OneOffPlannerTests" 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Browsing/FreeSpace.swift` :

```swift
import Foundation

public enum FreeSpace {
    /// Place disponible sur le volume du dossier (celle que le Finder affiche) ; `nil` si le dossier n'existe pas.
    public static func available(at url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
```

Dans `OneOffPlanner` :

```swift
    /// Ce qu'un dépôt dans `folder` peut copier : des fichiers locaux, ni déjà dans ce dossier, ni ce dossier ou un parent.
    public static func droppable(_ urls: [URL], into folder: URL) -> [URL] {
        let target = folder.standardizedFileURL.pathComponents
        return urls.filter { url in
            guard url.isFileURL else { return false }
            let item = url.standardizedFileURL
            if item.deletingLastPathComponent().pathComponents == target { return false }
            return !target.starts(with: item.pathComponents)
        }
    }
```

`Sources/SyncMacProUI/Views/CopyStatusBar.swift` :

```swift
import SwiftUI
import SyncKit

public enum SizeState: Equatable, Sendable {
    case none
    case computing
    case done(SizeTotal)
    case failed
}

/// En bas de l'écran Copie : la sélection, sa taille, la place libre à destination.
@MainActor
struct CopyStatusBar: View {
    let count: Int
    let size: SizeState
    let free: Int64?
    let localizer: Localizer

    static func sizeText(_ size: SizeState, localizer l: Localizer) -> String? {
        switch size {
        case .none: return nil
        case .computing: return l.text("copy.size.computing")
        case .failed: return l.text("copy.size.failed")
        case .done(let total): return l.format("copy.size.done", total.files, l.bytes(total.bytes))
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(count == 0 ? localizer.text("copy.selection.none") : localizer.format("copy.selection.count", count))
            if let size = Self.sizeText(size, localizer: localizer) {
                Text("·").foregroundStyle(.tertiary)
                Text(size)
            }
            Spacer()
            if let free {
                Label(localizer.format("copy.free", localizer.bytes(free)), systemImage: "internaldrive")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
```

`Sources/SyncMacProUI/Views/FilePaneView.swift` :

```swift
import AppKit
import SwiftUI
import SyncKit

/// Les actions du menu contextuel d'un élément (`nil` : entrée absente).
struct PaneMenu {
    let copyToOther: () -> Void
    let simulate: () -> Void
    let open: (() -> Void)?
    let addFavorite: (() -> Void)?
    let reveal: () -> Void
}

/// La barre de chemin : le volume, puis chaque dossier, cliquables.
@MainActor
struct PathBar: View {
    let crumbs: [Crumb]
    let onOpen: (URL) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                Button(crumb.name) { onOpen(crumb.url) }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// La liste d'un panneau, sans défilement (rendue par les tests).
@MainActor
struct FileListBody: View {
    let items: [DirectoryItem]
    let selection: Set<URL>
    let problem: PaneProblem?
    let localizer: Localizer
    let onClick: (URL, Bool, Bool) -> Void
    let onOpen: (DirectoryItem) -> Void
    let menu: (DirectoryItem) -> PaneMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem {
                Label(localizer.text(problem == .unreadable ? "copy.pane.unreadable" : "copy.pane.vanished"),
                      systemImage: problem == .unreadable ? "lock.fill" : "externaldrive.badge.xmark")
                    .font(.callout)
                    .foregroundStyle(problem == .unreadable ? .red : .orange)
                    .padding(10)
            }
            if items.isEmpty && problem != .unreadable {
                Text(localizer.text("copy.pane.empty")).font(.callout).foregroundStyle(.secondary).padding(10)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in row(item) }
            }
        }
    }

    private func row(_ item: DirectoryItem) -> some View {
        let selected = selection.contains(item.url)
        let actions = menu(item)
        return HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(item.size.map { localizer.bytes($0) } ?? "—")
                .foregroundStyle(.secondary).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(item.modified.map { $0.formatted(date: .numeric, time: .shortened) } ?? "")
                .foregroundStyle(.secondary).monospacedDigit().frame(width: 130, alignment: .trailing)
        }
        .font(.callout)
        .opacity(item.isHidden ? 0.6 : 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(item) }
        .simultaneousGesture(TapGesture().onEnded {
            let flags = NSEvent.modifierFlags
            onClick(item.url, flags.contains(.command), flags.contains(.shift))
        })
        .draggable(item.url)
        .contextMenu {
            Button(localizer.text("copy.menu.copy"), action: actions.copyToOther)
            Button(localizer.text("copy.menu.simulate"), action: actions.simulate)
            if let open = actions.open { Button(localizer.text("copy.menu.open"), action: open) }
            if let add = actions.addFavorite { Button(localizer.text("copy.menu.favorite"), action: add) }
            Divider()
            Button(localizer.text("copy.menu.reveal"), action: actions.reveal)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Un panneau complet : emplacements, dossier parent, fichiers cachés, barre de chemin, liste, dépôt.
@MainActor
struct FilePaneView: View {
    let pane: PaneModel
    let favorites: FavoritesModel
    let localizer: Localizer
    let onDrop: ([URL]) -> Void
    let menu: (DirectoryItem) -> PaneMenu
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            PathBar(crumbs: PathCrumbs.crumbs(for: pane.folder), onOpen: pane.open)
            Divider()
            ScrollView {
                FileListBody(
                    items: pane.items, selection: pane.selection, problem: pane.problem, localizer: localizer,
                    onClick: { pane.click($0, command: $1, shift: $2) },
                    onOpen: { item in
                        if item.isDirectory { pane.open(item.url) } else { NSWorkspace.shared.open(item.url) }
                    },
                    menu: menu
                )
            }
            .dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
                return true
            } isTargeted: { targeted = $0 }
        }
        .background(.background)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                lineWidth: targeted ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                Section(localizer.text("copy.places.favorites")) {
                    if favorites.favorites.isEmpty { Text(localizer.text("copy.places.noFavorites")) }
                    ForEach(favorites.favorites, id: \.self) { url in
                        Button(url.lastPathComponent) { pane.open(url) }
                    }
                }
                Section(localizer.text("copy.places.standard")) {
                    ForEach(StandardLocations.folders()) { place in
                        Button { pane.open(place.url) } label: { Label(place.name, systemImage: place.systemImage) }
                    }
                }
                Section(localizer.text("copy.places.volumes")) {
                    ForEach(StandardLocations.volumes()) { place in
                        Button { pane.open(place.url) } label: { Label(place.name, systemImage: place.systemImage) }
                    }
                }
            } label: {
                Label(pane.folder.lastPathComponent.isEmpty ? "/" : pane.folder.lastPathComponent, systemImage: "folder")
            }
            .fixedSize()
            Spacer()
            Button { pane.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!pane.canGoUp).help(localizer.text("copy.up"))
            Button {
                if favorites.contains(pane.folder) { favorites.remove(pane.folder) } else { favorites.add(pane.folder) }
            } label: {
                Image(systemName: favorites.contains(pane.folder) ? "star.fill" : "star")
            }
            .help(localizer.text("copy.favorite.toggle"))
            Toggle(isOn: Binding(get: { pane.showHidden }, set: { pane.showHidden = $0 })) {
                Image(systemName: "eye")
            }
            .toggleStyle(.button).help(localizer.text("copy.hidden"))
            Button { pane.reload() } label: { Image(systemName: "arrow.clockwise") }.help(localizer.text("copy.reload"))
        }
        .controlSize(.small)
        .padding(8)
    }
}
```

`StringsCompletenessTests` : ajouter `copy|confirm|oneoff` à la liste des préfixes de la regex.

Chaînes — `fr.lproj` :

```
"copy.size.computing" = "Calcul de la taille…";
"copy.size.failed" = "Taille inconnue";
"copy.size.done" = "%d fichiers, %@";
"copy.selection.none" = "Aucun élément choisi";
"copy.selection.count" = "%d éléments choisis";
"copy.free" = "%@ libres à destination";
"copy.pane.unreadable" = "Ce dossier ne peut pas être lu (droits d’accès insuffisants).";
"copy.pane.vanished" = "Le dossier a disparu (disque démonté ?) : affichage du premier dossier existant.";
"copy.pane.empty" = "Dossier vide";
"copy.menu.copy" = "Copier vers l’autre panneau";
"copy.menu.simulate" = "Simuler la copie";
"copy.menu.open" = "Ouvrir";
"copy.menu.favorite" = "Ajouter aux favoris";
"copy.menu.reveal" = "Afficher dans le Finder";
"copy.places.favorites" = "Favoris";
"copy.places.noFavorites" = "Aucun favori (étoile en haut du panneau)";
"copy.places.standard" = "Emplacements";
"copy.places.volumes" = "Disques";
"copy.up" = "Dossier parent";
"copy.favorite.toggle" = "Ajouter ou retirer des favoris";
"copy.hidden" = "Afficher les fichiers cachés";
"copy.reload" = "Actualiser";
```

`en.lproj` :

```
"copy.size.computing" = "Computing size…";
"copy.size.failed" = "Unknown size";
"copy.size.done" = "%d files, %@";
"copy.selection.none" = "Nothing selected";
"copy.selection.count" = "%d items selected";
"copy.free" = "%@ free at destination";
"copy.pane.unreadable" = "This folder can’t be read (insufficient permissions).";
"copy.pane.vanished" = "The folder is gone (disk unmounted?): showing the nearest existing folder.";
"copy.pane.empty" = "Empty folder";
"copy.menu.copy" = "Copy to the other pane";
"copy.menu.simulate" = "Simulate the copy";
"copy.menu.open" = "Open";
"copy.menu.favorite" = "Add to favorites";
"copy.menu.reveal" = "Show in Finder";
"copy.places.favorites" = "Favorites";
"copy.places.noFavorites" = "No favorites (star at the top of the pane)";
"copy.places.standard" = "Locations";
"copy.places.volumes" = "Disks";
"copy.up" = "Parent folder";
"copy.favorite.toggle" = "Add to or remove from favorites";
"copy.hidden" = "Show hidden files";
"copy.reload" = "Refresh";
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "CopyRenderTests|OneOffPlannerTests|StringsCompletenessTests" 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | tail -4` → passent ; ouvrir les PNG de `$TMPDIR/syncmacpro-renders/copy-*` et vérifier la lisibilité.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "Interface : panneau de fichiers (liste, barre de chemin, emplacements, dépôt) et barre d'état" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 8 : l'écran Copie, la confirmation, la barre latérale

**Fichiers :** créer `Sources/SyncMacProUI/Views/CopyConfirmationView.swift`, `Sources/SyncMacProUI/Views/CopyView.swift` ; modifier `OneOffPlanner.swift`, `RootView.swift`, `TaskCard.swift`, les deux `Localizable.strings`, `Tests/SyncMacProUITests/RootViewTests.swift`, `CopyRenderTests.swift`, `OneOffPlannerTests.swift`.

**Interfaces :** consomme `AgentModel.runOnce` / `simulate` (tâche 2, 3b), `OneOffPlanner` (tâches 6, 7), `FilePaneView`, `CopyStatusBar`, `FolderSizer`, `FreeSpace`. Produit :
- `enum CopyRequest: Equatable { copy(items: [URL], to: URL); sync(from: URL, to: URL) }` et `struct CopySession: Identifiable` (`id`, `request`, `simulateAtOnce: Bool`) ;
- `OneOffPlanner.tasks(for: CopyRequest, acceptDeletions: Bool, resolver:localizer:) -> [SyncTask]` ;
- `OneOffPlanner.combine(_ outcomes: [SimulationOutcome]) -> SimulationOutcome` ;
- `struct CopyConfirmationContent: View` (sans défilement) et `struct CopyConfirmationView: View` ;
- `struct CopyView: View` (`model`, `localizer`, `onSaveAsTask: (TaskDraft) -> Void`) ;
- `SidebarItem.copy` (ordre : dashboard, tasks, copy, history, settings).

- [ ] **Étape 1 : tests qui échouent**

Dans `OneOffPlannerTests` :

```swift
    func testSimulationsAreSummed() {
        let a = SimulationResult(status: .succeeded, filesToTransfer: 2, bytesToTransfer: 100, deletions: 0, message: nil)
        let b = SimulationResult(status: .succeeded, filesToTransfer: 3, bytesToTransfer: 50, deletions: 1, message: nil)
        XCTAssertEqual(OneOffPlanner.combine([.finished(a), .finished(b)]),
                       .finished(SimulationResult(status: .succeeded, filesToTransfer: 5, bytesToTransfer: 150, deletions: 1, message: nil)))
        XCTAssertEqual(OneOffPlanner.combine([.finished(a), .failed("source introuvable")]), .failed("source introuvable"))
        let blocked = SimulationResult(status: .blocked, filesToTransfer: 0, bytesToTransfer: 0, deletions: 9, message: "seuil")
        XCTAssertEqual(OneOffPlanner.combine([.finished(a), .finished(blocked)]).status, .blocked)
    }

    func testRequestsBecomeTasks() {
        let copy = CopyRequest.copy(items: [URL(fileURLWithPath: "/a/x.txt")], to: URL(fileURLWithPath: "/b"))
        XCTAssertEqual(OneOffPlanner.tasks(for: copy, acceptDeletions: false, resolver: .localOnly, localizer: fr).map(\.sourceItems), [["x.txt"]])
        let sync = CopyRequest.sync(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b"))
        let tasks = OneOffPlanner.tasks(for: sync, acceptDeletions: true, resolver: .localOnly, localizer: fr)
        XCTAssertEqual(tasks.map(\.mode), [.mirror])
        XCTAssertEqual(tasks.first?.options.deleteThresholdPercent, 100)
    }
```

`SimulationOutcome` reçoit un accesseur de test `status` : ajouter dans le test une extension privée

```swift
private extension SimulationOutcome {
    var status: RunStatus? {
        if case .finished(let result) = self { return result.status }
        return nil
    }
}
```

Dans `CopyRenderTests` :

```swift
    func testConfirmationRendersEveryState() throws {
        let tasks = OneOffPlanner.copyTasks(
            items: [URL(fileURLWithPath: "/Users/moi/Photos/a.jpg"), URL(fileURLWithPath: "/Users/moi/Photos/b.jpg")],
            to: URL(fileURLWithPath: "/Volumes/NAS/Photos"), resolver: .localOnly, localizer: fr
        )
        let result = SimulationResult(status: .succeeded, filesToTransfer: 2, bytesToTransfer: 4_000_000, deletions: 0, message: nil)
        let states: [SimulationState] = [.idle, .running, .finished(.finished(result)), .finished(.failed("Source introuvable"))]
        for (index, state) in states.enumerated() {
            let view = CopyConfirmationContent(
                tasks: tasks, isSync: false, simulation: state, error: index == 3 ? "La destination est dans la source." : nil,
                acceptDeletions: .constant(false), offline: false, localizer: fr
            )
            assertNotBlank(try render(view, name: "copy-confirm-\(index)", size: CGSize(width: 520, height: 300), scheme: .light))
        }
    }

    func testSyncConfirmationOffersToAcceptDeletionsAfterASimulation() {
        let task = OneOffPlanner.syncTask(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b"),
                                          acceptDeletions: false, resolver: .localOnly, localizer: fr)
        let deleting = SimulationResult(status: .succeeded, filesToTransfer: 0, bytesToTransfer: 0, deletions: 40, message: nil)
        XCTAssertTrue(CopyConfirmationContent.offersDeletionApproval(isSync: true, simulation: .finished(.finished(deleting))))
        XCTAssertFalse(CopyConfirmationContent.offersDeletionApproval(isSync: true, simulation: .idle))
        XCTAssertFalse(CopyConfirmationContent.offersDeletionApproval(isSync: false, simulation: .finished(.finished(deleting))))
        _ = task
    }
```

Dans `RootViewTests.testSidebarEntries` : `[.dashboard, .tasks, .copy, .history, .settings]`.

`swift test --filter "CopyRenderTests|OneOffPlannerTests|RootViewTests" 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

Dans `OneOffPlanner.swift` :

```swift
public enum CopyRequest: Equatable, Sendable {
    /// Des éléments choisis (ou déposés) vers un dossier.
    case copy(items: [URL], to: URL)
    /// Un dossier entier vers un autre, en miroir.
    case sync(from: URL, to: URL)
}

public struct CopySession: Identifiable {
    public let id = UUID()
    public let request: CopyRequest
    /// Ouverte depuis « Simuler » : la simulation démarre aussitôt.
    public let simulateAtOnce: Bool
}

extension OneOffPlanner {
    public static func tasks(
        for request: CopyRequest, acceptDeletions: Bool,
        resolver: EndpointResolver = .system, localizer: Localizer = .system
    ) -> [SyncTask] {
        switch request {
        case .copy(let items, let destination):
            return copyTasks(items: items, to: destination, resolver: resolver, localizer: localizer)
        case .sync(let source, let destination):
            return [syncTask(from: source, to: destination, acceptDeletions: acceptDeletions, resolver: resolver, localizer: localizer)]
        }
    }

    /// Les simulations des copies d'une même demande, additionnées ; le premier échec l'emporte, puis un blocage.
    public static func combine(_ outcomes: [SimulationOutcome]) -> SimulationOutcome {
        var total = SimulationResult(status: .succeeded, filesToTransfer: 0, bytesToTransfer: 0, deletions: 0, message: nil)
        for outcome in outcomes {
            switch outcome {
            case .failed(let message): return .failed(message)
            case .finished(let result):
                total.filesToTransfer += result.filesToTransfer
                total.bytesToTransfer += result.bytesToTransfer
                total.deletions += result.deletions
                if result.status != .succeeded && total.status == .succeeded {
                    total.status = result.status
                    total.message = result.message
                }
            }
        }
        return .finished(total)
    }
}
```

`Sources/SyncMacProUI/Views/CopyConfirmationView.swift` :

```swift
import SwiftUI
import SyncKit

/// Le contenu de la confirmation, sans défilement (rendu par les tests).
@MainActor
struct CopyConfirmationContent: View {
    let tasks: [SyncTask]
    let isSync: Bool
    let simulation: SimulationState
    let error: String?
    @Binding var acceptDeletions: Bool
    let offline: Bool
    let localizer: Localizer

    private var text: TaskSummaryText { TaskSummaryText(localizer: localizer) }

    /// Après une simulation qui annonce des suppressions, une synchronisation peut les accepter d'avance
    /// (le garde-fou bloquerait sinon une exécution qui n'existe plus ensuite pour être validée).
    static func offersDeletionApproval(isSync: Bool, simulation: SimulationState) -> Bool {
        guard isSync, case .finished(.finished(let result)) = simulation else { return false }
        return result.deletions > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizer.text(isSync ? "confirm.title.sync" : "confirm.title.copy")).font(.title3.bold())
            ForEach(tasks) { task in
                Text(text.sentence(for: task)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(Set(tasks.flatMap { text.warnings(for: $0) })).sorted(), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(Set(tasks.flatMap { TaskValidator.problems(in: $0) }.map { text.problem($0) })).sorted(), id: \.self) { problem in
                Label(problem, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            simulationSection
            if Self.offersDeletionApproval(isSync: isSync, simulation: simulation) {
                Toggle(localizer.text("confirm.acceptDeletions"), isOn: $acceptDeletions)
            }
            if let error {
                Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if offline {
                Text(localizer.text("confirm.offline")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var simulationSection: some View {
        switch simulation {
        case .idle:
            Text(localizer.text("confirm.simulate.help")).font(.caption).foregroundStyle(.secondary)
        case .running:
            HStack { ProgressView().controlSize(.small); Text(localizer.text("editor.simulating")) }
        case .finished(.finished(let result)):
            Label(text.simulation(result), systemImage: result.deletions > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(result.deletions > 0 ? .orange : .green)
                .fixedSize(horizontal: false, vertical: true)
        case .finished(.failed(let message)):
            Label(localizer.format("simulation.failed", message), systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// Feuille ouverte avant toute copie ou synchronisation : résumé, avertissements, Simuler, Lancer.
@MainActor
struct CopyConfirmationView: View {
    let model: AgentModel
    let session: CopySession
    let localizer: Localizer
    let onClose: () -> Void
    @State private var simulation: SimulationState = .idle
    @State private var acceptDeletions = false
    @State private var error: String?
    @State private var launching = false
    @State private var simulatedIDs: [UUID] = []

    private var isSync: Bool {
        if case .sync = session.request { return true }
        return false
    }

    private var tasks: [SyncTask] {
        OneOffPlanner.tasks(for: session.request, acceptDeletions: acceptDeletions, localizer: localizer)
    }

    private var offline: Bool { model.connection != .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                CopyConfirmationContent(
                    tasks: tasks, isSync: isSync, simulation: simulation, error: error,
                    acceptDeletions: $acceptDeletions, offline: offline, localizer: localizer
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(localizer.text("confirm.cancel"), role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Spacer()
                if case .running = simulation {
                    Button(localizer.text("editor.simulate.cancel")) { cancelSimulations() }
                } else {
                    Button(localizer.text("confirm.simulate")) { Task { await simulate() } }.disabled(offline)
                }
                Button(localizer.text("confirm.launch")) { Task { await launch() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(offline || launching || tasks.contains { !TaskValidator.problems(in: $0).isEmpty })
            }
        }
        .padding(20)
        .frame(width: 540, height: 380)
        .task { if session.simulateAtOnce { await simulate() } }
        .onDisappear { cancelSimulations() }
    }

    private func simulate() async {
        error = nil
        simulation = .running
        let planned = tasks
        simulatedIDs = planned.map(\.id)
        var outcomes: [SimulationOutcome] = []
        for task in planned {
            outcomes.append(await model.simulate(task))
            guard case .running = simulation else { return }
        }
        simulatedIDs = []
        simulation = .finished(OneOffPlanner.combine(outcomes))
    }

    private func cancelSimulations() {
        guard case .running = simulation else { return }
        let ids = simulatedIDs
        simulation = .idle
        simulatedIDs = []
        Task { for id in ids { await model.cancelSimulation(id) } }
    }

    private func launch() async {
        launching = true
        defer { launching = false }
        if let refusal = await model.runOnce(tasks) {
            error = refusal
        } else {
            close()
        }
    }

    private func close() {
        cancelSimulations()
        onClose()
    }
}
```

Note : les simulations d'une demande partagent l'identifiant de chaque tâche planifiée ; `tasks` est recalculé à chaque accès (nouveaux identifiants), d'où la copie `planned` et `simulatedIDs`.

`Sources/SyncMacProUI/Views/CopyView.swift` :

```swift
import AppKit
import SwiftUI
import SyncKit

/// L'écran Copie : deux panneaux (gauche = source, droite = destination) et les actions entre eux.
@MainActor
struct CopyView: View {
    let model: AgentModel
    let localizer: Localizer
    let onSaveAsTask: (TaskDraft) -> Void
    @State private var left = PaneModel(folder: URL(fileURLWithPath: NSHomeDirectory()))
    @State private var right = PaneModel(folder: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop"))
    @State private var favorites = FavoritesModel()
    @State private var size: SizeState = .none
    @State private var session: CopySession?

    private var offline: Bool { model.connection != .connected }
    private var selected: [URL] { left.selectedItems.map(\.url) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                pane(left, other: right)
                actions
                pane(right, other: left)
            }
            .padding(12)
            Divider()
            CopyStatusBar(count: selected.count, size: size, free: FreeSpace.available(at: right.folder), localizer: localizer)
        }
        .navigationTitle(localizer.text("sidebar.copy"))
        // La taille de la sélection est recalculée (et l'ancien calcul annulé) dès qu'elle change.
        .task(id: left.selection) { await computeSize() }
        .sheet(item: $session) { current in
            CopyConfirmationView(model: model, session: current, localizer: localizer) { session = nil }
        }
    }

    private func pane(_ pane: PaneModel, other: PaneModel) -> some View {
        FilePaneView(
            pane: pane, favorites: favorites, localizer: localizer,
            onDrop: { urls in
                let accepted = OneOffPlanner.droppable(urls, into: pane.folder)
                guard !accepted.isEmpty else { return }
                session = CopySession(request: .copy(items: accepted, to: pane.folder), simulateAtOnce: false)
            },
            menu: { item in
                let targets = pane.selection.contains(item.url) ? pane.selectedItems.map(\.url) : [item.url]
                return PaneMenu(
                    copyToOther: { session = CopySession(request: .copy(items: targets, to: other.folder), simulateAtOnce: false) },
                    simulate: { session = CopySession(request: .copy(items: targets, to: other.folder), simulateAtOnce: true) },
                    open: item.isDirectory ? { pane.open(item.url) } : nil,
                    addFavorite: item.isDirectory ? { favorites.add(item.url) } : nil,
                    reveal: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                )
            }
        )
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Spacer()
            Button { copy(simulate: false) } label: { Label(localizer.text("copy.action.copy"), systemImage: "arrow.right") }
                .disabled(selected.isEmpty || offline)
                .help(localizer.text("copy.action.copy.help"))
            Button { session = CopySession(request: .sync(from: left.folder, to: right.folder), simulateAtOnce: false) } label: {
                Label(localizer.text("copy.action.sync"), systemImage: "arrow.right.circle")
            }
            .disabled(offline)
            .help(localizer.text("copy.action.sync.help"))
            Button { simulate() } label: { Label(localizer.text("copy.action.simulate"), systemImage: "eye") }
                .disabled(offline)
            Button { saveAsTask() } label: { Label(localizer.text("copy.action.save"), systemImage: "square.and.arrow.down") }
            Divider().frame(width: 40)
            Button { swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                .help(localizer.text("copy.action.swap"))
            if offline {
                Text(localizer.text("copy.offline")).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(width: 130)
            }
            Spacer()
        }
        .labelStyle(.titleAndIcon)
        .frame(width: 150)
    }

    private func copy(simulate: Bool) {
        guard !selected.isEmpty else { return }
        session = CopySession(request: .copy(items: selected, to: right.folder), simulateAtOnce: simulate)
    }

    /// Simuler : la sélection si elle existe, sinon la synchronisation du dossier entier.
    private func simulate() {
        if selected.isEmpty {
            session = CopySession(request: .sync(from: left.folder, to: right.folder), simulateAtOnce: true)
        } else {
            copy(simulate: true)
        }
    }

    /// Enregistrer comme tâche : la sélection (mode copie) ou, sans sélection, tout le dossier (mode copie aussi :
    /// le miroir reste un choix explicite dans l'éditeur).
    private func saveAsTask() {
        let task = selected.isEmpty
            ? OneOffPlanner.copyTasks(items: [left.folder], to: right.folder, localizer: localizer)[0].withWholeFolder(left.folder)
            : OneOffPlanner.copyTasks(items: selected, to: right.folder, localizer: localizer)[0]
        var draft = TaskDraft(task: task)
        draft.name = ""
        onSaveAsTask(draft)
    }

    private func swap() {
        let leftFolder = left.folder
        left.open(right.folder)
        right.open(leftFolder)
    }

    private func computeSize() async {
        let urls = selected
        guard !urls.isEmpty else { size = .none; return }
        size = .computing
        let work = Task.detached(priority: .utility) { try FolderSizer.total(of: urls) }
        let outcome = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let total): size = .done(total)
        case .failure: size = .failed
        }
    }
}

private extension SyncTask {
    /// Une tâche « tout le dossier » : source = le dossier, aucun élément choisi.
    func withWholeFolder(_ folder: URL) -> SyncTask {
        var task = self
        task.source = EndpointResolver.system.endpoint(forPath: folder.standardizedFileURL.path)
        task.sourceItems = []
        return task
    }
}
```

La source « tout le dossier » passe par `EndpointResolver.system` : un dossier sur un volume réseau devient une source réseau.

`RootView.swift` :
- `case dashboard, tasks, copy, history, settings` ;
- `detail` : `case .copy: CopyView(model: model, localizer: localizer) { open($0, isNew: true) }` ;
- `title` : `case .copy: return localizer.text("sidebar.copy")` ; `icon` : `case .copy: return "doc.on.doc"` ;
- le commentaire de `RootView` cite la nouvelle entrée.

`TaskCard.swift`, après la ligne `if let task { … }` :

```swift
            if info.isOneOff {
                Label(l.text("card.oneoff"), systemImage: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
            }
```

Chaînes — `fr.lproj` :

```
"sidebar.copy" = "Copie";
"card.oneoff" = "Copie manuelle";
"copy.action.copy" = "Copier";
"copy.action.copy.help" = "Copier les éléments choisis à gauche dans le dossier de droite";
"copy.action.sync" = "Synchroniser";
"copy.action.sync.help" = "Rendre le dossier de droite identique à celui de gauche (miroir)";
"copy.action.simulate" = "Simuler";
"copy.action.save" = "Enregistrer comme tâche";
"copy.action.swap" = "Échanger les deux panneaux";
"copy.offline" = "L’agent ne répond pas : copies indisponibles.";
"confirm.title.copy" = "Copier ?";
"confirm.title.sync" = "Synchroniser ?";
"confirm.simulate.help" = "Simuler montre ce qui serait copié et supprimé, sans rien modifier.";
"confirm.acceptDeletions" = "J’ai vu la simulation : accepter les suppressions";
"confirm.offline" = "L’agent ne répond pas.";
"confirm.cancel" = "Annuler";
"confirm.simulate" = "Simuler";
"confirm.launch" = "Lancer";
```

`en.lproj` :

```
"sidebar.copy" = "Copy";
"card.oneoff" = "Manual copy";
"copy.action.copy" = "Copy";
"copy.action.copy.help" = "Copy the items selected on the left into the folder on the right";
"copy.action.sync" = "Sync";
"copy.action.sync.help" = "Make the right folder identical to the left one (mirror)";
"copy.action.simulate" = "Simulate";
"copy.action.save" = "Save as task";
"copy.action.swap" = "Swap the two panes";
"copy.offline" = "The agent isn’t responding: copies unavailable.";
"confirm.title.copy" = "Copy?";
"confirm.title.sync" = "Sync?";
"confirm.simulate.help" = "Simulate shows what would be copied and deleted, without changing anything.";
"confirm.acceptDeletions" = "I’ve seen the simulation: accept the deletions";
"confirm.offline" = "The agent isn’t responding.";
"confirm.cancel" = "Cancel";
"confirm.simulate" = "Simulate";
"confirm.launch" = "Start";
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "CopyRenderTests|OneOffPlannerTests|RootViewTests|StringsCompletenessTests" 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | tail -4` → passent ; suite complète verte ; `swift build` sans avertissement nouveau.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "Écran Copie : deux panneaux, confirmation avec simulation, enregistrer comme tâche ; carte « Copie manuelle »" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 9 : essai réel et documentation

**Fichiers :** modifier `README.md`, `docs/manual-checks-ui.md`.

**Interfaces :** consomme tout ce qui précède ; ne produit rien de nouveau.

- [ ] **Étape 1 : essai réel avec l'agent de développement** (rsync 3 via `SYNCMACPRO_RSYNC`)

```bash
swift build && scripts/dev-launchd.sh
```

Dans un dossier temporaire du bloc-notes (`$S/e2e`) : `src/{a.txt,b.txt,photos/1.jpg}`, `dst/old.txt`.
1. `syncmacpro-ctl copy --source $S/e2e/src --dest $S/e2e/dst --item a.txt --item photos` → `dst` contient `a.txt`, `photos/1.jpg`, `old.txt` ; pas de `b.txt`.
2. `syncmacpro-ctl copy --source $S/e2e/src --dest $S/e2e/dst --mirror` → `old.txt` déplacé dans l'archive ; `b.txt` présent.
3. `syncmacpro-ctl history` : les deux exécutions, réussies ; `syncmacpro-ctl status` : aucune tâche ponctuelle restante ; `tasks.json` inchangé.
4. Copier un dossier dans lui-même (`--source $S/e2e --dest $S/e2e/src/x --item src`) → refus clair.
5. L'app (`scripts/make-dev-bundle.sh`) : écran Copie, capture de la fenêtre seule (`screencapture -l`), puis suppression de la capture.

Arrêter l'agent de développement ensuite.

- [ ] **Étape 2 : documentation**

`README.md` — nouvelle section après « Interface (sous-projet 3a) » / 3b :

```markdown
## Copie à deux panneaux (sous-projet 3c)

L'écran **Copie** montre deux dossiers côte à côte : à gauche la source, à droite la destination (⇄ pour échanger).
- **Copier** : les éléments choisis à gauche (⌘ et ⇧ pour en choisir plusieurs) vers le dossier de droite.
- **Synchroniser** : rend le dossier de droite identique à celui de gauche (miroir, avec archive et garde-fou).
- **Simuler** : montre ce qui serait copié et supprimé, sans rien modifier.
- **Enregistrer comme tâche** : ouvre l'éditeur pré-rempli.
- Glisser un élément d'un panneau à l'autre, ou déposer des fichiers du Finder, ouvre la même confirmation.

Chaque copie est exécutée par l'agent comme une **copie manuelle** : elle apparaît au tableau de bord le temps de
l'exécution, puis dans l'historique (avec son journal) ; elle n'est pas enregistrée dans les tâches. Une copie
interrompue par l'arrêt de l'agent n'est pas reprise.

En ligne de commande : `syncmacpro-ctl copy --source DOSSIER --dest DOSSIER [--item NOM]... [--mirror]`.
```

`docs/manual-checks-ui.md` — section « Copie (3c) » :

```markdown
## Copie (3c)
- [ ] Naviguer : double-clic sur un dossier, barre de chemin, dossier parent, emplacements, volumes, favoris (étoile).
- [ ] Fichiers cachés : bouton œil.
- [ ] Choisir plusieurs fichiers (⌘, ⇧) : la barre d'état affiche le nombre, la taille (calcul en cours, puis total) et la place libre.
- [ ] Copier → confirmation → Simuler → Lancer : la carte « Copie manuelle » apparaît au tableau de bord, puis l'exécution dans l'historique avec son journal.
- [ ] Synchroniser un dossier dont la destination contient des fichiers en trop : la simulation annonce les suppressions ; « accepter les suppressions » permet de lancer malgré le garde-fou.
- [ ] Glisser un fichier d'un panneau à l'autre ; déposer des fichiers du Finder (de deux dossiers différents).
- [ ] Copier un dossier dans un de ses sous-dossiers : refus clair dans la confirmation.
- [ ] Dossier sans droits de lecture : message dans le panneau.
- [ ] Démonter un disque affiché : le panneau remonte et le signale (après Actualiser).
- [ ] Agent arrêté : boutons désactivés avec la raison.
- [ ] Enregistrer comme tâche : l'éditeur s'ouvre avec source, destination et éléments choisis.
```

- [ ] **Étape 3 : vérifier** — suite complète verte.

- [ ] **Étape 4 : commit et push**

```bash
git add README.md docs/manual-checks-ui.md
git commit -m "Docs : copie à deux panneaux, ctl copy, vérifications manuelles" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```
