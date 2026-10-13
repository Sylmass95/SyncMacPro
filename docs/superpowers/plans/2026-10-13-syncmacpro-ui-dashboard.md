# SyncMacPro — sous-projet 3a (voir et contrôler) : plan d'implémentation

> **Pour les agents :** SOUS-COMPÉTENCE REQUISE : utiliser superpowers:subagent-driven-development (recommandé) ou superpowers:executing-plans pour exécuter ce plan tâche par tâche. Les étapes utilisent la syntaxe à cases (`- [ ]`).

**Objectif :** une app SwiftUI native (tableau de bord, barre de menus, historique, réglages) qui se connecte à l'agent par XPC, affiche l'état en direct, contrôle les tâches et se rétablit seule quand l'agent redémarre.

**Architecture :** bibliothèque `SyncMacProUI` (modèle observable `AgentModel`, fonctions pures de présentation, vues) + exécutable fin `SyncMacPro`. Tout passe par un protocole `AgentConnecting` (faux en test). Trois petits ajouts côté agent (`SyncKit`) précèdent l'interface.

**Stack :** Swift 5.9 (mode 5), SwiftUI, Observation (`@Observable`), `MenuBarExtra`, `SMAppService`, XCTest, `ImageRenderer`.

**Spec :** `docs/superpowers/specs/2026-10-13-syncmacpro-ui-dashboard-design.md`

## Contraintes globales

- macOS 14 minimum, swift-tools-version 5.9, mode de langage Swift 5, aucune dépendance externe.
- **CI en Swift 5.10, plus strict que le Swift 6.3 local** (deux PR déjà cassées) : jamais de `var` capturée ni de `weak self` capturé dans une closure `@Sendable` ou `Task.detached` ; utiliser des copies `let`. Le CI est le seul juge de cette classe d'erreurs.
- Version du contrat XPC : **1** (`agentProtocolVersion`) ; ajouts **optionnels** seulement.
- Textes affichés : toujours par `Localizer` (`text(_:)` / `format(_:_:)`), clés présentes en **français (langue source) et en anglais** dans `Sources/SyncMacProUI/Resources/{fr,en}.lproj/Localizable.strings`. **Pas de `.xcstrings`** : `swift build` ne les compile pas (vérifié : seul le fichier brut est copié, l'anglais ne s'afficherait jamais).
- Présence : Dock **et** barre de menus ; fermer la fenêtre garde l'app ; Quitter laisse l'agent tourner.
- Barre de menus : `MenuBarExtra` en style panneau, **sans** menu de clic droit.
- Constantes : relecture groupée sur **0,25 s**, relecture de sécurité toutes les **30 s**, reconnexion après **1, 2, 4, 8 puis 15 s**, nouvelle tentative lente après une version incompatible : **60 s**, historique : **500** dernières exécutions.
- Les 241 tests existants restent verts. Commande de référence :
  `SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync" swift test`
- Chaque commit se termine par `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Décisions prises en rédigeant le plan (écarts avec le spec)

- **Ruling : `.strings` par langue au lieu de `.xcstrings`** (voir Contraintes). Le test de complétude lit les fichiers `.strings` et les clés utilisées dans le code.
- **Ruling : le modèle lit aussi `listTasks`** (mode et planification d'une tâche) à chaque relecture : `AgentTaskInfo` ne les contient pas, et la carte doit afficher le mode.
- **Ruling : priorité de l'icône de barre de menus** : déconnecté > pause globale > copie en cours > pause d'une tâche > erreur > repos. Une erreur est donc masquée tant qu'une copie tourne.
- **Ruling : une interruption de connexion XPC compte comme une fin** (l'abonnement est perdu quand l'agent redémarre) ; l'annulation volontaire (`cancel`) n'en est pas une.
- **Ruling : méthode `startWatching(onEvent:onEnd:)`** dans le protocole (et non `watch`) pour éviter une ambiguïté avec `AgentClient.watch`.
- **Ruling : Réglages à la fois dans la barre latérale et par ⌘,** (scène `Settings`, même vue).
- **Vérifié avant d'écrire ce plan** : `ctl` lancé depuis `SyncMacPro.app/Contents/MacOS/` voit bien le bundle comme `Bundle.main`, même si l'app est le programme principal : `agent install` en ligne de commande continue de marcher.
- Les messages d'erreur renvoyés par l'agent restent en français (`AgentError.errorDescription`) : leur traduction est hors périmètre.

## Points de revue (cas que les tests nominaux ne couvrent pas)

1. L'agent est tué puis relancé par launchd pendant que l'app est ouverte : l'interface se rétablit sans action de l'utilisateur. → tâche 4.
2. Une rafale d'événements ne provoque pas une rafale de relectures ; l'avancement ne déclenche aucune relecture. → tâche 4.
3. Une carte dont la tâche est inconnue du modèle (supprimée, `listTasks` en retard) ne plante pas. → tâches 4, 6.
4. Système en anglais : aucune clé manquante, aucun format avec un nombre d'arguments incohérent. → tâche 2.
5. Données limites : total inconnu ou nul, durée restante absente, noms très longs, aucune tâche, 500 lignes d'historique. → tâches 3, 6, 8.
6. Fenêtre fermée : l'app reste dans la barre de menus et l'icône continue de refléter l'état ; Quitter ne touche pas à l'agent. → tâche 10.

## Structure des fichiers

| Fichier | Rôle |
|---|---|
| `Sources/SyncKit/Agent/AgentXPC.swift` (modifié) | `watch(onEnd:)`, fuite d'observateur corrigée |
| `Sources/SyncKit/Agent/AgentTypes.swift`, `AgentCore.swift` (modifiés) | `AgentTaskInfo.progress`, `observerCount` |
| `Sources/SyncMacProUI/Localizer.swift` | Textes localisés, tailles, débits, durées |
| `Sources/SyncMacProUI/Resources/{fr,en}.lproj/Localizable.strings` | Chaînes |
| `Sources/SyncMacProUI/Logic/*.swift` | `ConnectionState`, `CardText`, `MenuBarState`, `CardOrdering`, `HistoryFilter` |
| `Sources/SyncMacProUI/Agent/*.swift` | `AgentConnecting`, `AgentModel`, `Sleeping`, `AgentInstaller`, `LoginItemModel` |
| `Sources/SyncMacProUI/Views/*.swift` | Tableau de bord, carte, bandeaux, barre de menus, historique, réglages, accueil, racine |
| `Sources/SyncMacPro/SyncMacProApp.swift` | Point d'entrée `@main`, scènes, délégué |
| `Tests/SyncKitTests/AgentXPCTests.swift` (modifié), `AgentProgressStatusTests.swift` | Tests des ajouts agent |
| `Tests/SyncMacProUITests/*.swift` | Tests de l'interface |
| `scripts/make-dev-bundle.sh` (modifié) | Bundle : l'app est le programme principal |

---

### Tâche 1 : ajouts côté agent (fin de connexion, fuite d'observateur, avancement dans l'état)

**Fichiers :**
- Modifier : `Sources/SyncKit/Agent/AgentXPC.swift`, `Sources/SyncKit/Agent/AgentTypes.swift`, `Sources/SyncKit/Agent/AgentCore.swift`, `Tests/SyncKitTests/AgentTestSupport.swift`, `Tests/SyncKitTests/AgentXPCTests.swift`
- Créer : `Tests/SyncKitTests/AgentProgressStatusTests.swift`

**Interfaces :**
- Produit :
  - `AgentClient.watch(_ onEvent: @escaping @Sendable (AgentEvent) -> Void, onEnd: @escaping @Sendable () -> Void = {}) async throws -> AgentWatch` : `onEnd` est appelé quand la connexion est coupée ou interrompue, **pas** après `cancel()`.
  - `AgentTaskInfo.progress: ProgressInfo?` (dernier paramètre de l'`init`, par défaut `nil`), rempli par `AgentCore.status()` pour une tâche en cours.
  - `AgentCore.observerCount: Int` (interne, pour les tests) ; `AgentListenerDelegate.onNewConnection: ((NSXPCConnection) -> Void)?` (interne, pour les tests).
  - `FakeRunner` / `RunnerFactory` : `snapshot: Locked<TransferSnapshot?>` émis par le faux exécuteur.

- [ ] **Étape 1 : écrire les tests qui échouent**

Dans `Tests/SyncKitTests/AgentTestSupport.swift`, ajouter à `FakeRunner` la propriété `let snapshot = Locked<TransferSnapshot?>(nil)` et, dans `run`, juste après `onUpdate(.phase(.running))` : `if let current = snapshot.get() { onUpdate(.snapshot(current)) }`. Ajouter à `RunnerFactory` la propriété `let snapshot = Locked<TransferSnapshot?>(nil)` et, dans `make()`, après `runner.failure.set(failure.get())` : `runner.snapshot.set(snapshot.get())`.

Dans `Tests/SyncKitTests/AgentXPCTests.swift`, ajouter à la fin de la classe `AgentXPCTests` (avant son accolade fermante) :

```swift
    func testWatcherIsToldWhenTheAgentConnectionEnds() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let delegate = AgentListenerDelegate(core: core)
        let serverConnections = Locked<[NSXPCConnection]>([])
        delegate.onNewConnection = { serverConnections.set(serverConnections.get() + [$0]) }
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        let client = AgentClient(timeout: 5) { NSXPCConnection(listenerEndpoint: endpoint) }

        let ended = Locked(false)
        let watch = try await client.watch({ _ in }, onEnd: { ended.set(true) })
        // L'agent « meurt » : sa connexion est coupée côté serveur.
        serverConnections.get().forEach { $0.invalidate() }
        let told = await eventually { ended.get() }
        XCTAssertTrue(told, "le client doit savoir que l'agent a disparu")
        withExtendedLifetime((watch, listener, delegate)) {}
    }

    func testCancellingAWatchDoesNotReportAnEnd() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let server = await makeServer(h)
        let ended = Locked(false)
        let watch = try await server.client.watch({ _ in }, onEnd: { ended.set(true) })
        watch.cancel()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(ended.get(), "annuler soi-même n'est pas une fin de connexion")
        withExtendedLifetime(server) {}
    }

    func testObserverRegisteredAfterTearDownIsRemoved() async throws {
        final class StubObserver: NSObject, AgentObserverXPC { func event(_ data: Data) {} }
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let handler = AgentConnectionHandler(core: core)
        handler.tearDown()   // le client s'est déconnecté avant que l'abonnement n'arrive
        let replied = Locked(false)
        handler.subscribe(StubObserver()) { replied.set(true) }
        let done = await eventually { replied.get() }
        XCTAssertTrue(done)
        let count = await core.observerCount
        XCTAssertEqual(count, 0, "un observateur orphelin ne doit pas rester enregistré")
    }
```

`Tests/SyncKitTests/AgentProgressStatusTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentProgressStatusTests: XCTestCase {
    func testRunningTaskReportsItsProgressInTheStatus() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        var snapshot = TransferSnapshot()
        snapshot.doneBytes = 4_000
        snapshot.totalBytes = 10_000
        snapshot.overallPercent = 40
        snapshot.currentName = "gros.bin"
        h.factory.snapshot.set(snapshot)
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        let seen = await eventually { await core.status().tasks.first?.progress?.doneBytes == 4_000 }
        XCTAssertTrue(seen, "une fenêtre ouverte en pleine copie doit voir l'avancement tout de suite")
        let info = await core.status().tasks[0].progress
        XCTAssertEqual(info?.overallPercent, 40)
        XCTAssertEqual(info?.currentName, "gros.bin")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        let after = await core.status().tasks[0].progress
        XCTAssertNil(after, "plus d'avancement une fois la tâche terminée")
    }

    func testTaskInfoWithoutProgressKeyStillDecodes() throws {
        let info = AgentTaskInfo(id: UUID(), name: "a", state: .idle)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        json.removeValue(forKey: "progress")
        let decoded = try JSONDecoder().decode(AgentTaskInfo.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, info)
        XCTAssertNil(decoded.progress)
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter "AgentXPCTests|AgentProgressStatusTests" 2>&1 | grep -E "error:" | head -5`
Attendu : erreurs de compilation (`onNewConnection`, `observerCount`, `onEnd:`, `progress` inconnus).

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/Agent/AgentTypes.swift`, struct `AgentTaskInfo` : ajouter `public var progress: ProgressInfo?` après `lastRun`, remplacer l'`init` par :

```swift
    public init(
        id: UUID, name: String, state: TaskRunState, nextDue: Date? = nil, lastRun: RunRecord? = nil,
        progress: ProgressInfo? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.nextDue = nextDue
        self.lastRun = lastRun
        self.progress = progress
    }
```

`Sources/SyncKit/Agent/AgentCore.swift` : dans `status()`, remplacer `return AgentTaskInfo(id: task.id, name: task.name, state: runState, nextDue: next, lastRun: last)` par :

```swift
            return AgentTaskInfo(
                id: task.id, name: task.name, state: runState, nextDue: next, lastRun: last,
                progress: jobs[task.id]?.latest
            )
```

et ajouter, dans la section « observateurs » : `var observerCount: Int { observers.count }`.

`Sources/SyncKit/Agent/AgentXPC.swift` :

1. Dans `AgentConnectionHandler`, remplacer les propriétés `tokens`, `subscribe` et `tearDown` par :

```swift
    private let lock = NSLock()
    private var tokens: [UUID] = []
    private var closed = false

    func subscribe(_ observer: AgentObserverXPC, reply: @escaping () -> Void) {
        let core = self.core
        Task {
            let token = await core.addObserver { event in
                if let data = try? JSONEncoder().encode(event) { observer.event(data) }
            }
            lock.lock()
            let alreadyClosed = closed
            if !alreadyClosed { tokens.append(token) }
            lock.unlock()
            // La connexion est déjà fermée : personne n'écoutera, on ne laisse pas l'observateur traîner.
            if alreadyClosed { await core.removeObserver(token) }
            reply()
        }
    }

    func tearDown() {
        lock.lock()
        closed = true
        let pending = tokens
        tokens = []
        lock.unlock()
        let core = self.core
        Task { for token in pending { await core.removeObserver(token) } }
    }
```

(supprimer l'ancienne propriété `private let tokens = Locked<[UUID]>([])`.)

2. Dans `AgentListenerDelegate` : ajouter `var onNewConnection: ((NSXPCConnection) -> Void)?` et, dans `listener(_:shouldAcceptNewConnection:)`, juste avant `connection.resume()` : `onNewConnection?(connection)`.

3. Remplacer la classe `AgentWatch` par :

```swift
public final class AgentWatch: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let observer: ClientObserver
    private let cancelled: Locked<Bool>

    init(connection: NSXPCConnection, observer: ClientObserver, cancelled: Locked<Bool>) {
        self.connection = connection
        self.observer = observer
        self.cancelled = cancelled
    }

    /// Fin volontaire : `onEnd` n'est pas appelé.
    public func cancel() {
        cancelled.set(true)
        connection.invalidate()
    }
}
```

4. Remplacer la méthode `watch` d'`AgentClient` par :

```swift
    /// Reçoit les événements de l'agent. `onEnd` est appelé quand la connexion est coupée ou interrompue
    /// (l'agent s'est arrêté : l'abonnement est perdu et il faut se reconnecter), jamais après `cancel()`.
    public func watch(
        _ onEvent: @escaping @Sendable (AgentEvent) -> Void,
        onEnd: @escaping @Sendable () -> Void = {}
    ) async throws -> AgentWatch {
        let connection = factory()
        let observer = ClientObserver(onEvent)
        let cancelled = Locked(false)
        let end: @Sendable () -> Void = { if !cancelled.get() { onEnd() } }
        connection.invalidationHandler = end
        connection.interruptionHandler = {
            end()
            connection.invalidate()
        }
        connection.remoteObjectInterface = AgentXPC.makeInterface()
        connection.exportedInterface = NSXPCInterface(with: AgentObserverXPC.self)
        connection.exportedObject = observer
        connection.resume()
        let timeout = self.timeout
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let shot = OneShot(continuation)
                let timer = DispatchWorkItem { shot.finish(.failure(AgentClientError.unreachable)) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    timer.cancel()
                    shot.finish(.failure(AgentClientError.unreachable))
                } as? AgentXPCProtocol
                guard let proxy else {
                    timer.cancel()
                    shot.finish(.failure(AgentClientError.unreachable))
                    return
                }
                proxy.subscribe(observer) {
                    timer.cancel()
                    shot.finish(.success(()))
                }
            }
        } catch {
            cancelled.set(true)
            connection.invalidate()
            throw error
        }
        return AgentWatch(connection: connection, observer: observer, cancelled: cancelled)
    }
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter "AgentXPCTests|AgentProgressStatusTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -3` puis, 5 fois, `swift test --skip-build --filter "AgentXPCTests|AgentProgressStatusTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -1`
Attendu : tous passent, à chaque exécution (contrôle d'instabilité). Puis la suite complète : `SYNCMACPRO_RSYNC=… swift test 2>&1 | tail -3` → vert (241 + 5).

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncKit Tests/SyncKitTests
git commit -m "Agent : fin de connexion signalée, fuite d'observateur corrigée, avancement dans l'état des tâches" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 2 : cibles du paquet, `Localizer` et chaînes fr / en

**Fichiers :**
- Modifier : `Package.swift`
- Créer : `Sources/SyncMacProUI/Localizer.swift`, `Sources/SyncMacProUI/Resources/fr.lproj/Localizable.strings`, `Sources/SyncMacProUI/Resources/en.lproj/Localizable.strings`, `Sources/SyncMacPro/SyncMacProApp.swift` (provisoire)
- Tester : `Tests/SyncMacProUITests/LocalizerTests.swift`, `Tests/SyncMacProUITests/StringsCompletenessTests.swift`, `Tests/SyncMacProUITests/UITestSupport.swift`

**Interfaces :**
- Produit : `struct Localizer: Sendable` — `init(language: String? = nil)`, `static let system`, `locale: Locale`, `text(_:) -> String`, `format(_:_ args: CVarArg...) -> String`, `bytes(_:) -> String`, `speed(_:) -> String`, `duration(_:) -> String`. Une clé inconnue s'affiche `⚠︎<clé>` (visible, et attrapée par le test de complétude).

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncMacProUITests/UITestSupport.swift` :

```swift
import Foundation
import XCTest

/// Attend qu'une condition devienne vraie (2 s au plus) ; faux si elle ne l'est jamais.
@MainActor
func eventually(timeout: TimeInterval = 2, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
```

`Tests/SyncMacProUITests/LocalizerTests.swift` :

```swift
import XCTest
@testable import SyncMacProUI

final class LocalizerTests: XCTestCase {
    let fr = Localizer(language: "fr")
    let en = Localizer(language: "en")

    func testTextInBothLanguages() {
        XCTAssertEqual(fr.text("sidebar.dashboard"), "Tableau de bord")
        XCTAssertEqual(en.text("sidebar.dashboard"), "Dashboard")
    }

    func testUnknownKeyIsVisible() {
        XCTAssertEqual(fr.text("cle.inexistante"), "⚠︎cle.inexistante")
    }

    func testFormatInsertsArguments() {
        XCTAssertEqual(fr.format("relative.hours", 2), "il y a 2 h")
        XCTAssertEqual(en.format("relative.hours", 2), "2 h ago")
        XCTAssertEqual(fr.format("state.waiting", "réseau"), "En attente : réseau")
    }

    func testBytesUseTheLanguageUnitsAndSeparator() {
        XCTAssertEqual(fr.bytes(512), "512 o")
        XCTAssertEqual(en.bytes(512), "512 B")
        XCTAssertEqual(fr.bytes(5_242_880), "5,0 Mo")
        XCTAssertEqual(en.bytes(5_242_880), "5.0 MB")
        XCTAssertEqual(fr.bytes(3_221_225_472), "3,00 Go")
    }

    func testSpeedAndDuration() {
        XCTAssertEqual(en.speed(2_097_152), "2.0 MB/s")
        XCTAssertEqual(fr.duration(65), "1:05")
        XCTAssertEqual(fr.duration(3725), "1:02:05")
        XCTAssertEqual(fr.duration(0), "0:00")
    }
}
```

`Tests/SyncMacProUITests/StringsCompletenessTests.swift` :

```swift
import XCTest
@testable import SyncMacProUI

final class StringsCompletenessTests: XCTestCase {
    var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SyncMacProUI/Resources")
    }

    func strings(_ language: String) throws -> [String: String] {
        let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: String], "\(language) : fichier .strings illisible")
    }

    func testBothLanguagesHaveTheSameKeys() throws {
        let fr = try strings("fr"), en = try strings("en")
        XCTAssertEqual(Set(fr.keys).subtracting(en.keys).sorted(), [], "clés sans traduction anglaise")
        XCTAssertEqual(Set(en.keys).subtracting(fr.keys).sorted(), [], "clés sans texte français")
    }

    func testNoValueIsEmpty() throws {
        for language in ["fr", "en"] {
            for (key, value) in try strings(language) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) : « \(key) » est vide")
            }
        }
    }

    func testFormatPlaceholdersMatchBetweenLanguages() throws {
        func placeholders(_ text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dfs]")
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        let fr = try strings("fr"), en = try strings("en")
        for (key, value) in fr {
            XCTAssertEqual(placeholders(value), placeholders(en[key] ?? ""), "« \(key) » : arguments différents entre fr et en")
        }
    }

    func testEveryKeyUsedInTheCodeExists() throws {
        let fr = try strings("fr")
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SyncMacProUI")
        // Toute chaîne qui ressemble à une clé (préfixe connu + point), y compris celles passées à une fonction d'aide.
        let regex = try NSRegularExpression(
            pattern: #""((?:app|sidebar|state|status|mode|schedule|weekday|relative|next|last|summary|unit|progress|connection|banner|dashboard|card|menubar|history|settings|agent|onboarding|alert)\.[A-Za-z0-9._]+)""#
        )
        var used = Set<String>()
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                used.insert(String(code[Range(match.range(at: 1), in: code)!]))
            }
        }
        XCTAssertEqual(used.subtracting(fr.keys).sorted(), [], "clés utilisées mais absentes des fichiers de chaînes")
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Écrire d'abord `Package.swift` (étape 3), car la cible de tests n'existe pas encore. Exécuter ensuite `swift test --filter "LocalizerTests|StringsCompletenessTests" 2>&1 | grep -E "error:" | head -3`.
Attendu : erreur de compilation (`Localizer` inconnu).

- [ ] **Étape 3 : implémenter**

`Package.swift` (remplacer en entier) :

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncMacPro",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"]),
        .executable(name: "synckit-cli", targets: ["synckit-cli"]),
        .executable(name: "syncmacpro-ctl", targets: ["syncmacpro-ctl"]),
        .executable(name: "syncmacpro-agent", targets: ["syncmacpro-agent"]),
        .executable(name: "SyncMacPro", targets: ["SyncMacPro"]),
    ],
    targets: [
        .target(name: "SyncKit"),
        .executableTarget(name: "synckit-cli", dependencies: ["SyncKit"]),
        .executableTarget(name: "syncmacpro-ctl", dependencies: ["SyncKit"]),
        .executableTarget(name: "syncmacpro-agent", dependencies: ["SyncKit"]),
        .target(name: "SyncMacProUI", dependencies: ["SyncKit"], resources: [.process("Resources")]),
        .executableTarget(name: "SyncMacPro", dependencies: ["SyncMacProUI"]),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SyncMacProUITests", dependencies: ["SyncMacProUI", "SyncKit"]),
    ]
)
```

`Sources/SyncMacPro/SyncMacProApp.swift` (provisoire, remplacé à la tâche 10) :

```swift
import SwiftUI
import SyncMacProUI

@main
struct SyncMacProApp: App {
    var body: some Scene {
        WindowGroup { Text("SyncMacPro") }
    }
}
```

`Sources/SyncMacProUI/Localizer.swift` :

```swift
import Foundation

/// Textes localisés (français = langue source, anglais) et mise en forme des tailles, débits et durées.
/// `language == nil` : langue du système. Une langue explicite sert aux tests.
public struct Localizer: Sendable {
    public let language: String?
    public let locale: Locale

    public init(language: String? = nil) {
        self.language = language
        locale = language.map { Locale(identifier: $0) } ?? .current
    }

    public static let system = Localizer()

    private var bundle: Bundle {
        guard let language, let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let localized = Bundle(path: path) else { return Bundle.module }
        return localized
    }

    /// Une clé inconnue s'affiche « ⚠︎clé » : visible à l'écran et attrapée par le test de complétude.
    public func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: "⚠︎\(key)", table: nil)
    }

    public func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    /// 512 → « 512 o », 5 242 880 → « 5,0 Mo » (« 5.0 MB » en anglais).
    public func bytes(_ value: Int64) -> String {
        let number = Double(value)
        let units = ["unit.byte", "unit.kilobyte", "unit.megabyte", "unit.gigabyte", "unit.terabyte"]
        let digits = [0, 0, 1, 2, 2]
        var scaled = max(number, 0)
        var index = 0
        while scaled >= 1_024, index < units.count - 1 {
            scaled /= 1_024
            index += 1
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = digits[index]
        formatter.maximumFractionDigits = digits[index]
        let figure = formatter.string(from: NSNumber(value: scaled)) ?? "\(Int(scaled))"
        return "\(figure) \(text(units[index]))"
    }

    public func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// 65 → « 1:05 », 3725 → « 1:02:05 ».
    public func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600, minutes = (total % 3_600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
```

Fichiers de chaînes. `Sources/SyncMacProUI/Resources/fr.lproj/Localizable.strings` :

```
"app.name" = "SyncMacPro";
"sidebar.dashboard" = "Tableau de bord";
"sidebar.history" = "Historique";
"sidebar.settings" = "Réglages";

"state.idle" = "Au repos";
"state.queued" = "En file d’attente";
"state.running" = "En cours";
"state.paused" = "En pause";
"state.waiting" = "En attente : %@";
"state.approval" = "Validation requise";
"state.disabled" = "Désactivée";

"status.running" = "En cours";
"status.succeeded" = "Réussie";
"status.failed" = "Échec";
"status.blocked" = "Bloquée";
"status.quota" = "Quota atteint";
"status.interrupted" = "Interrompue";
"status.stopped" = "Arrêtée";

"mode.copy" = "Copie";
"mode.mirror" = "Miroir";
"mode.bidirectional" = "Bidirectionnel";
"mode.move" = "Déplacement";
"mode.versioned" = "Versions";
"mode.verify" = "Vérification";

"schedule.manual" = "Manuelle";
"schedule.daily" = "Tous les jours à %@";
"schedule.everyMinutes" = "Toutes les %d min";
"schedule.weekdays" = "%@ à %@";
"schedule.whenAvailable" = "Dès que disponible";
"weekday.1" = "dim.";
"weekday.2" = "lun.";
"weekday.3" = "mar.";
"weekday.4" = "mer.";
"weekday.5" = "jeu.";
"weekday.6" = "ven.";
"weekday.7" = "sam.";

"relative.now" = "à l’instant";
"relative.minutes" = "il y a %d min";
"relative.hours" = "il y a %d h";
"relative.days" = "il y a %d j";
"next.today" = "aujourd’hui à %@";
"next.tomorrow" = "demain à %@";
"next.none" = "Sans échéance";
"last.never" = "Jamais lancée";
"last.format" = "%@ %@";
"last.format.summary" = "%@ %@ — %@";
"summary.files" = "%d fichier(s)";
"summary.errors" = "%d erreur(s)";
"unit.byte" = "o";
"unit.kilobyte" = "Ko";
"unit.megabyte" = "Mo";
"unit.gigabyte" = "Go";
"unit.terabyte" = "To";
"progress.line" = "%@ sur %@ · %@ · reste %@";
"progress.line.noeta" = "%@ sur %@ · %@";
"progress.line.unknown" = "%@ copiés";

"connection.connecting" = "Connexion à l’agent…";
"connection.reconnecting" = "Reconnexion à l’agent… (essai %d)";
"connection.unreachable.title" = "L’agent ne répond pas";
"connection.unreachable.body" = "Il n’est peut-être pas installé, ou il vient de s’arrêter. Installez-le ou réessayez.";
"connection.version.title" = "Versions incompatibles";
"connection.version.body" = "L’agent (version %d) et l’app ne se comprennent plus : mettez à jour l’agent ou l’app.";
"connection.retry" = "Réessayer";

"banner.recovered" = "L’agent est reparti en pause : son fichier d’état était illisible.";
"banner.tasksfile" = "Le fichier des tâches est illisible ; les tâches précédentes sont conservées. %@";

"dashboard.title" = "Tableau de bord";
"dashboard.pause.global" = "Pause globale";
"dashboard.pause.on" = "En pause globale";
"dashboard.pause.help" = "Rien ne démarre et les copies en cours sont figées.";
"dashboard.resume" = "Reprendre";
"dashboard.empty.title" = "Aucune tâche";
"dashboard.empty.body" = "La création de tâches arrive bientôt. D’ici là, utilisez la commande : syncmacpro-ctl add";

"card.run" = "Lancer";
"card.pause" = "Pause";
"card.resume" = "Reprendre";
"card.stop" = "Arrêter";
"card.approve" = "Valider les suppressions";
"card.next" = "Prochaine : %@";
"card.last" = "Dernière : %@";
"card.approval.body" = "Cette tâche supprimerait beaucoup de fichiers : elle a été bloquée par sécurité. %@";

"menubar.idle" = "Au repos";
"menubar.copies" = "%d copies";
"menubar.active" = "Copies en cours";
"menubar.none" = "Aucune copie en cours";
"menubar.upcoming" = "Prochaines exécutions";
"menubar.nonext" = "Aucune exécution planifiée";
"menubar.open" = "Ouvrir SyncMacPro";
"menubar.quit" = "Quitter";

"history.title" = "Historique";
"history.column.date" = "Date";
"history.column.task" = "Tâche";
"history.column.status" = "État";
"history.column.duration" = "Durée";
"history.column.files" = "Fichiers";
"history.column.size" = "Taille";
"history.column.errors" = "Erreurs";
"history.filter.task" = "Tâche";
"history.filter.alltasks" = "Toutes les tâches";
"history.filter.status" = "État";
"history.filter.allstatus" = "Tous les états";
"history.period.day" = "24 heures";
"history.period.week" = "7 jours";
"history.period.month" = "30 jours";
"history.period.all" = "Tout";
"history.search" = "Rechercher une tâche";
"history.empty" = "Aucune exécution";
"history.empty.filtered" = "Aucune exécution ne correspond aux filtres";
"history.error" = "L’historique est illisible : %@";
"history.detail.none" = "Sélectionnez une exécution";
"history.detail.message" = "Message";
"history.detail.engine" = "Moteur";
"history.detail.started" = "Début";
"history.detail.finished" = "Fin";

"settings.title" = "Réglages";
"settings.appearance" = "Apparence";
"settings.appearance.auto" = "Automatique";
"settings.appearance.light" = "Clair";
"settings.appearance.dark" = "Sombre";
"settings.login" = "Ouvrir SyncMacPro à l’ouverture de session";
"settings.agent" = "Agent d’arrière-plan";
"agent.state.enabled" = "Installé et actif";
"agent.state.notRegistered" = "Non installé";
"agent.state.requiresApproval" = "À autoriser dans Réglages Système";
"agent.state.notFound" = "Introuvable dans l’application";
"agent.state.unknown" = "État inconnu";
"agent.install" = "Installer l’agent";
"agent.uninstall" = "Désinstaller l’agent";
"agent.opensettings" = "Ouvrir Réglages Système";
"settings.data" = "Données";
"settings.data.reveal" = "Afficher le dossier des données";
"settings.about" = "À propos";
"settings.version" = "Version %@";

"onboarding.title" = "Bienvenue dans SyncMacPro";
"onboarding.body" = "Pour lancer vos synchronisations même quand l’app est fermée, SyncMacPro installe un petit agent d’arrière-plan.";
"onboarding.install" = "Installer l’agent";
"onboarding.approve" = "macOS demande votre autorisation : ouvrez Réglages Système › Général › Éléments de connexion et extensions, puis activez SyncMacPro.";

"alert.title" = "Action impossible";
"alert.ok" = "OK";
```

`Sources/SyncMacProUI/Resources/en.lproj/Localizable.strings` :

```
"app.name" = "SyncMacPro";
"sidebar.dashboard" = "Dashboard";
"sidebar.history" = "History";
"sidebar.settings" = "Settings";

"state.idle" = "Idle";
"state.queued" = "Queued";
"state.running" = "Running";
"state.paused" = "Paused";
"state.waiting" = "Waiting: %@";
"state.approval" = "Approval needed";
"state.disabled" = "Disabled";

"status.running" = "Running";
"status.succeeded" = "Succeeded";
"status.failed" = "Failed";
"status.blocked" = "Blocked";
"status.quota" = "Quota reached";
"status.interrupted" = "Interrupted";
"status.stopped" = "Stopped";

"mode.copy" = "Copy";
"mode.mirror" = "Mirror";
"mode.bidirectional" = "Two-way";
"mode.move" = "Move";
"mode.versioned" = "Versioned";
"mode.verify" = "Verify";

"schedule.manual" = "Manual";
"schedule.daily" = "Every day at %@";
"schedule.everyMinutes" = "Every %d min";
"schedule.weekdays" = "%@ at %@";
"schedule.whenAvailable" = "When available";
"weekday.1" = "Sun";
"weekday.2" = "Mon";
"weekday.3" = "Tue";
"weekday.4" = "Wed";
"weekday.5" = "Thu";
"weekday.6" = "Fri";
"weekday.7" = "Sat";

"relative.now" = "just now";
"relative.minutes" = "%d min ago";
"relative.hours" = "%d h ago";
"relative.days" = "%d d ago";
"next.today" = "today at %@";
"next.tomorrow" = "tomorrow at %@";
"next.none" = "No schedule";
"last.never" = "Never run";
"last.format" = "%@ %@";
"last.format.summary" = "%@ %@ — %@";
"summary.files" = "%d file(s)";
"summary.errors" = "%d error(s)";
"unit.byte" = "B";
"unit.kilobyte" = "KB";
"unit.megabyte" = "MB";
"unit.gigabyte" = "GB";
"unit.terabyte" = "TB";
"progress.line" = "%@ of %@ · %@ · %@ left";
"progress.line.noeta" = "%@ of %@ · %@";
"progress.line.unknown" = "%@ copied";

"connection.connecting" = "Connecting to the agent…";
"connection.reconnecting" = "Reconnecting to the agent… (attempt %d)";
"connection.unreachable.title" = "The agent is not responding";
"connection.unreachable.body" = "It may not be installed, or it just stopped. Install it or try again.";
"connection.version.title" = "Incompatible versions";
"connection.version.body" = "The agent (version %d) and the app no longer understand each other: update the agent or the app.";
"connection.retry" = "Try again";

"banner.recovered" = "The agent restarted paused: its state file was unreadable.";
"banner.tasksfile" = "The tasks file is unreadable; the previous tasks are kept. %@";

"dashboard.title" = "Dashboard";
"dashboard.pause.global" = "Global pause";
"dashboard.pause.on" = "Globally paused";
"dashboard.pause.help" = "Nothing starts and running copies are frozen.";
"dashboard.resume" = "Resume";
"dashboard.empty.title" = "No tasks";
"dashboard.empty.body" = "Task creation is coming soon. Until then, use the command: syncmacpro-ctl add";

"card.run" = "Run now";
"card.pause" = "Pause";
"card.resume" = "Resume";
"card.stop" = "Stop";
"card.approve" = "Approve deletions";
"card.next" = "Next: %@";
"card.last" = "Last: %@";
"card.approval.body" = "This task would delete many files, so it was blocked for safety. %@";

"menubar.idle" = "Idle";
"menubar.copies" = "%d copies";
"menubar.active" = "Running copies";
"menubar.none" = "No copy running";
"menubar.upcoming" = "Upcoming runs";
"menubar.nonext" = "No scheduled run";
"menubar.open" = "Open SyncMacPro";
"menubar.quit" = "Quit";

"history.title" = "History";
"history.column.date" = "Date";
"history.column.task" = "Task";
"history.column.status" = "Status";
"history.column.duration" = "Duration";
"history.column.files" = "Files";
"history.column.size" = "Size";
"history.column.errors" = "Errors";
"history.filter.task" = "Task";
"history.filter.alltasks" = "All tasks";
"history.filter.status" = "Status";
"history.filter.allstatus" = "All statuses";
"history.period.day" = "24 hours";
"history.period.week" = "7 days";
"history.period.month" = "30 days";
"history.period.all" = "All time";
"history.search" = "Search a task";
"history.empty" = "No runs";
"history.empty.filtered" = "No run matches the filters";
"history.error" = "The history is unreadable: %@";
"history.detail.none" = "Select a run";
"history.detail.message" = "Message";
"history.detail.engine" = "Engine";
"history.detail.started" = "Started";
"history.detail.finished" = "Finished";

"settings.title" = "Settings";
"settings.appearance" = "Appearance";
"settings.appearance.auto" = "Automatic";
"settings.appearance.light" = "Light";
"settings.appearance.dark" = "Dark";
"settings.login" = "Open SyncMacPro at login";
"settings.agent" = "Background agent";
"agent.state.enabled" = "Installed and running";
"agent.state.notRegistered" = "Not installed";
"agent.state.requiresApproval" = "Needs approval in System Settings";
"agent.state.notFound" = "Not found in the app";
"agent.state.unknown" = "Unknown state";
"agent.install" = "Install the agent";
"agent.uninstall" = "Uninstall the agent";
"agent.opensettings" = "Open System Settings";
"settings.data" = "Data";
"settings.data.reveal" = "Show the data folder";
"settings.about" = "About";
"settings.version" = "Version %@";

"onboarding.title" = "Welcome to SyncMacPro";
"onboarding.body" = "To run your syncs even when the app is closed, SyncMacPro installs a small background agent.";
"onboarding.install" = "Install the agent";
"onboarding.approve" = "macOS needs your approval: open System Settings › General › Login Items & Extensions, then turn on SyncMacPro.";

"alert.title" = "Action failed";
"alert.ok" = "OK";
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift build 2>&1 | tail -3` puis `swift test --filter "LocalizerTests|StringsCompletenessTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -4`
Attendu : la compilation réussit (les cibles `SyncMacProUI` et `SyncMacPro` sont valides) ; 9 tests passent. Si le test `testBytesUseTheLanguageUnitsAndSeparator` échoue sur un espace insécable dans le résultat de `NumberFormatter`, ce n'est pas le cas ici (l'espace vient de l'interpolation `"\(figure) \(unité)"`) ; si le séparateur décimal diffère de « , » ou « . », relever la valeur réelle et corriger l'attendu, pas le code.

- [ ] **Étape 5 : suite complète puis commit**

Exécuter : `SYNCMACPRO_RSYNC=… swift test 2>&1 | tail -3` → vert.

```bash
git add Package.swift Sources/SyncMacProUI Sources/SyncMacPro Tests/SyncMacProUITests
git commit -m "Interface : cibles SyncMacProUI et SyncMacPro, Localizer, chaînes françaises et anglaises" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 3 : logique de présentation pure (textes, tri, filtres, état de la barre de menus)

**Fichiers :**
- Créer : `Sources/SyncMacProUI/Logic/ConnectionState.swift`, `Sources/SyncMacProUI/Logic/CardText.swift`, `Sources/SyncMacProUI/Logic/MenuBarState.swift`, `Sources/SyncMacProUI/Logic/CardOrdering.swift`, `Sources/SyncMacProUI/Logic/HistoryFilter.swift`
- Tester : `Tests/SyncMacProUITests/PresentationLogicTests.swift`

**Interfaces :**
- Consomme : `Localizer` (tâche 2), types de `SyncKit` (`AgentStatus`, `AgentTaskInfo`, `ProgressInfo`, `RunRecord`, `SyncTask`, `Schedule`, `SyncMode`).
- Produit :
  - `enum ConnectionState: Equatable, Sendable { connecting, connected, reconnecting(attempt: Int), unreachable, versionMismatch(agent: Int) }`
  - `struct CardText` — `init(localizer:calendar:now:)` ; `state(_:)`, `status(_:)`, `mode(_:)`, `schedule(_:)`, `relative(_:)`, `nextRun(_:)`, `lastRun(_:)`, `progressLine(_:)`, `summaryLine(_:)`, `dateTime(_:)`.
  - `enum MenuBarState` (`disconnected`, `idle`, `copying(percent: Int?, count: Int)`, `paused`, `error`) — `static make(connection:status:progress:)`, `systemImage`, `title(_ localizer:)`.
  - `enum CardOrdering { static func sorted(_ tasks: [AgentTaskInfo]) -> [AgentTaskInfo] }`
  - `enum HistoryPeriod` (`day`, `week`, `month`, `all`) ; `struct HistoryFilter` — `taskID`, `statuses`, `period`, `search`, `apply(to:now:)`.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncMacProUITests/PresentationLogicTests.swift` :

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

private let paris: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}()

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    paris.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func info(
    _ name: String, _ state: TaskRunState = .idle, next: Date? = nil, last: RunStatus? = nil
) -> AgentTaskInfo {
    let id = UUID()
    let record = last.map {
        RunRecord(taskID: id, taskName: name, engine: .rsync, mode: .copy, startedAt: at(12, 8), status: $0)
    }
    return AgentTaskInfo(id: id, name: name, state: state, nextDue: next, lastRun: record)
}

final class CardTextTests: XCTestCase {
    func text(_ language: String, now: Date = at(12, 10)) -> CardText {
        CardText(localizer: Localizer(language: language), calendar: paris, now: now)
    }

    func testRelativeTimes() {
        let now = at(12, 10)
        XCTAssertEqual(text("fr").relative(now.addingTimeInterval(-20)), "à l’instant")
        XCTAssertEqual(text("fr").relative(now.addingTimeInterval(-5 * 60)), "il y a 5 min")
        XCTAssertEqual(text("fr").relative(now.addingTimeInterval(-2 * 3_600)), "il y a 2 h")
        XCTAssertEqual(text("en").relative(now.addingTimeInterval(-3 * 86_400)), "3 d ago")
    }

    func testNextRunTodayTomorrowAndLater() {
        XCTAssertEqual(text("fr").nextRun(at(12, 23)), "aujourd’hui à 23:00")
        XCTAssertEqual(text("fr").nextRun(at(13, 3)), "demain à 03:00")
        XCTAssertTrue(text("en").nextRun(at(13, 3)).hasPrefix("tomorrow at"))
        let later = text("fr").nextRun(at(20, 3))
        XCTAssertTrue(later.contains("20"), later)
        XCTAssertEqual(text("fr").nextRun(nil), "Sans échéance")
    }

    func testLastRunSummary() {
        let record = RunRecord(
            taskID: UUID(), taskName: "n", engine: .rsync, mode: .copy, startedAt: at(12, 8),
            finishedAt: at(12, 9), status: .succeeded,
            summary: RunSummary(filesTransferred: 3, bytesTransferred: 5_242_880, errors: 0)
        )
        XCTAssertEqual(text("fr").lastRun(record), "Réussie il y a 2 h — 3 fichier(s), 5,0 Mo")
        XCTAssertEqual(text("fr").lastRun(nil), "Jamais lancée")
        var running = record
        running.status = .running
        running.summary = nil
        XCTAssertEqual(text("fr").lastRun(running), "En cours il y a 2 h")
    }

    func testSummaryLineMentionsErrors() {
        let summary = RunSummary(filesTransferred: 1, bytesTransferred: 10, errors: 2)
        XCTAssertEqual(text("fr").summaryLine(summary), "1 fichier(s), 10 o, 2 erreur(s)")
    }

    func testProgressLineVariants() {
        var info = ProgressInfo(TransferSnapshot())
        info.doneBytes = 1_073_741_824
        info.totalBytes = 3_221_225_472
        info.currentSpeed = 47_185_920
        info.totalETA = 12
        XCTAssertEqual(text("fr").progressLine(info), "1,00 Go sur 3,00 Go · 45,0 Mo/s · reste 0:12")
        info.totalETA = nil
        XCTAssertEqual(text("fr").progressLine(info), "1,00 Go sur 3,00 Go · 45,0 Mo/s")
        info.totalBytes = nil
        XCTAssertEqual(text("fr").progressLine(info), "1,00 Go copiés")
        info.totalBytes = 0
        XCTAssertEqual(text("fr").progressLine(info), "1,00 Go copiés")
    }

    func testScheduleAndModeNames() {
        XCTAssertEqual(text("fr").schedule(.manual), "Manuelle")
        XCTAssertEqual(text("fr").schedule(.daily(hour: 3, minute: 5)), "Tous les jours à 03:05")
        XCTAssertEqual(text("fr").schedule(.everyMinutes(15)), "Toutes les 15 min")
        XCTAssertEqual(text("fr").schedule(.weekdays(days: [6, 2], hour: 8, minute: 0)), "lun., ven. à 08:00")
        XCTAssertEqual(text("en").schedule(.whenAvailable), "When available")
        XCTAssertEqual(text("fr").mode(.mirror), "Miroir")
        XCTAssertEqual(text("en").mode(.bidirectional), "Two-way")
    }

    func testStateAndStatusLabels() {
        XCTAssertEqual(text("fr").state(.waiting(reason: "réseau")), "En attente : réseau")
        XCTAssertEqual(text("en").state(.awaitingApproval), "Approval needed")
        XCTAssertEqual(text("fr").status(.quotaReached), "Quota atteint")
    }
}

final class MenuBarStateTests: XCTestCase {
    func status(paused: Bool = false, _ tasks: [AgentTaskInfo]) -> AgentStatus {
        AgentStatus(globalPause: paused, stateRecovered: false, taskLoadError: nil, tasks: tasks)
    }

    func make(
        _ status: AgentStatus?, connection: ConnectionState = .connected, progress: [UUID: ProgressInfo] = [:]
    ) -> MenuBarState {
        MenuBarState.make(connection: connection, status: status, progress: progress)
    }

    func testDisconnectedWhenNotConnectedOrNoStatus() {
        XCTAssertEqual(make(nil), .disconnected)
        XCTAssertEqual(make(status([]), connection: .reconnecting(attempt: 2)), .disconnected)
        XCTAssertEqual(make(status([]), connection: .unreachable), .disconnected)
    }

    func testIdleWhenNothingHappens() {
        XCTAssertEqual(make(status([info("a")])), .idle)
        XCTAssertEqual(make(status([])), .idle)
    }

    func testOneCopyShowsItsPercentage() {
        let running = info("a", .running)
        var progress = ProgressInfo(TransferSnapshot())
        progress.overallPercent = 42
        XCTAssertEqual(make(status([running]), progress: [running.id: progress]), .copying(percent: 42, count: 1))
        XCTAssertEqual(make(status([running])), .copying(percent: nil, count: 1))
    }

    func testSeveralCopiesShowACount() {
        XCTAssertEqual(make(status([info("a", .running), info("b", .running)])), .copying(percent: nil, count: 2))
    }

    func testGlobalPauseWinsOverACopy() {
        XCTAssertEqual(make(status(paused: true, [info("a", .paused)])), .paused)
    }

    func testPausedTaskWhenNothingElseRuns() {
        XCTAssertEqual(make(status([info("a", .paused)])), .paused)
    }

    func testErrorsShowWhenNothingRuns() {
        XCTAssertEqual(make(status([info("a", last: .failed)])), .error)
        XCTAssertEqual(make(status([info("a", last: .blocked)])), .error)
        XCTAssertEqual(make(status([info("a", .awaitingApproval)])), .error)
        XCTAssertEqual(make(status([info("a", last: .succeeded)])), .idle)
    }

    func testACopyHidesAnErrorElsewhere() {
        XCTAssertEqual(
            make(status([info("a", .running), info("b", last: .failed)])), .copying(percent: nil, count: 1)
        )
    }

    func testIconsAndTitles() {
        let l = Localizer(language: "fr")
        XCTAssertEqual(MenuBarState.copying(percent: 42, count: 1).title(l), "42 %")
        XCTAssertEqual(MenuBarState.copying(percent: nil, count: 2).title(l), "2 copies")
        XCTAssertNil(MenuBarState.idle.title(l))
        XCTAssertEqual(MenuBarState.paused.systemImage, "pause.circle")
        XCTAssertEqual(MenuBarState.error.systemImage, "exclamationmark.triangle")
        XCTAssertEqual(MenuBarState.disconnected.systemImage, "bolt.slash")
    }
}

final class CardOrderingTests: XCTestCase {
    func testOrder() {
        let tasks = [
            info("idle-late", next: at(14, 3)),
            info("disabled", .disabled),
            info("idle-soon", next: at(13, 3)),
            info("waiting", .waiting(reason: "x")),
            info("approval", .awaitingApproval),
            info("paused", .paused),
            info("running", .running),
            info("manual"),
        ]
        XCTAssertEqual(
            CardOrdering.sorted(tasks).map(\.name),
            ["paused", "running", "approval", "waiting", "idle-soon", "idle-late", "manual", "disabled"]
        )
    }

    func testRunningOrPausedKeepAlphabeticalOrder() {
        let tasks = [info("b", .running), info("a", .paused)]
        XCTAssertEqual(CardOrdering.sorted(tasks).map(\.name), ["a", "b"])
    }
}

final class HistoryFilterTests: XCTestCase {
    let now = at(12, 12)

    func record(_ name: String, _ status: RunStatus, hoursAgo: Double, task: UUID = UUID()) -> RunRecord {
        RunRecord(
            taskID: task, taskName: name, engine: .rsync, mode: .copy,
            startedAt: now.addingTimeInterval(-hoursAgo * 3_600), status: status
        )
    }

    func testNoFilterKeepsEverything() {
        let records = [record("a", .succeeded, hoursAgo: 1), record("b", .failed, hoursAgo: 100)]
        XCTAssertEqual(HistoryFilter().apply(to: records, now: now).count, 2)
    }

    func testByTaskStatusAndSearch() {
        let nas = UUID()
        let records = [
            record("Archives NAS", .succeeded, hoursAgo: 1, task: nas),
            record("Archives NAS", .failed, hoursAgo: 2, task: nas),
            record("Photos", .failed, hoursAgo: 3),
        ]
        var filter = HistoryFilter()
        filter.taskID = nas
        XCTAssertEqual(filter.apply(to: records, now: now).count, 2)
        filter.statuses = [.failed]
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["Archives NAS"])
        filter = HistoryFilter()
        filter.search = "PHO"
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["Photos"])
    }

    func testPeriods() {
        let records = [
            record("a", .succeeded, hoursAgo: 2),
            record("b", .succeeded, hoursAgo: 48),
            record("c", .succeeded, hoursAgo: 24 * 10),
            record("d", .succeeded, hoursAgo: 24 * 40),
        ]
        var filter = HistoryFilter()
        filter.period = .day
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["a"])
        filter.period = .week
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["a", "b"])
        filter.period = .month
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["a", "b", "c"])
        filter.period = .all
        XCTAssertEqual(filter.apply(to: records, now: now).count, 4)
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter "CardTextTests|MenuBarStateTests|CardOrderingTests|HistoryFilterTests" 2>&1 | grep -E "error:" | head -3`
Attendu : erreur de compilation (`CardText`, `MenuBarState`… inconnus).

- [ ] **Étape 3 : implémenter**

`Sources/SyncMacProUI/Logic/ConnectionState.swift` :

```swift
import Foundation

/// Où en est la connexion de l'app avec l'agent.
public enum ConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting(attempt: Int)
    /// L'agent ne répond pas et n'a jamais répondu pendant cette session (non installé, ou arrêté).
    case unreachable
    case versionMismatch(agent: Int)
}
```

`Sources/SyncMacProUI/Logic/CardText.swift` :

```swift
import Foundation
import SyncKit

/// Tous les textes d'une carte, d'une ligne d'historique ou du panneau de la barre de menus.
/// Horloge et calendrier injectés : « il y a 2 h » et « demain à 03:00 » se testent sans attendre.
public struct CardText {
    public let localizer: Localizer
    public let calendar: Calendar
    public let now: Date

    public init(localizer: Localizer = .system, calendar: Calendar = .current, now: Date = Date()) {
        self.localizer = localizer
        self.calendar = calendar
        self.now = now
    }

    public func state(_ state: TaskRunState) -> String {
        switch state {
        case .idle: return localizer.text("state.idle")
        case .queued: return localizer.text("state.queued")
        case .running: return localizer.text("state.running")
        case .paused: return localizer.text("state.paused")
        case .waiting(let reason): return localizer.format("state.waiting", reason)
        case .awaitingApproval: return localizer.text("state.approval")
        case .disabled: return localizer.text("state.disabled")
        }
    }

    public func status(_ status: RunStatus) -> String {
        switch status {
        case .running: return localizer.text("status.running")
        case .succeeded: return localizer.text("status.succeeded")
        case .failed: return localizer.text("status.failed")
        case .blocked: return localizer.text("status.blocked")
        case .quotaReached: return localizer.text("status.quota")
        case .interrupted: return localizer.text("status.interrupted")
        case .stopped: return localizer.text("status.stopped")
        }
    }

    public func mode(_ mode: SyncMode) -> String {
        switch mode {
        case .copy: return localizer.text("mode.copy")
        case .mirror: return localizer.text("mode.mirror")
        case .bidirectional: return localizer.text("mode.bidirectional")
        case .move: return localizer.text("mode.move")
        case .versioned: return localizer.text("mode.versioned")
        case .verify: return localizer.text("mode.verify")
        }
    }

    public func schedule(_ schedule: Schedule) -> String {
        func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
        switch schedule {
        case .manual: return localizer.text("schedule.manual")
        case .whenAvailable: return localizer.text("schedule.whenAvailable")
        case .everyMinutes(let minutes): return localizer.format("schedule.everyMinutes", minutes)
        case .daily(let hour, let minute): return localizer.format("schedule.daily", clock(hour, minute))
        case .weekdays(let days, let hour, let minute):
            let names = days.sorted().filter { (1...7).contains($0) }.map { localizer.text("weekday.\($0)") }
            return localizer.format("schedule.weekdays", names.joined(separator: ", "), clock(hour, minute))
        }
    }

    /// « à l'instant », « il y a 5 min », « il y a 2 h », « il y a 3 j ».
    public func relative(_ date: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return localizer.text("relative.now")
        case ..<3_600: return localizer.format("relative.minutes", Int(seconds / 60))
        case ..<86_400: return localizer.format("relative.hours", Int(seconds / 3_600))
        default: return localizer.format("relative.days", Int(seconds / 86_400))
        }
    }

    /// « aujourd'hui à 23:00 », « demain à 03:00 », ou « mar. 20 oct. 03:00 ». `nil` : « Sans échéance ».
    public func nextRun(_ date: Date?) -> String {
        guard let date else { return localizer.text("next.none") }
        let time = DateFormatter()
        time.locale = localizer.locale
        time.timeZone = calendar.timeZone
        time.timeStyle = .short
        time.dateStyle = .none
        if calendar.isDate(date, inSameDayAs: now) { return localizer.format("next.today", time.string(from: date)) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return localizer.format("next.tomorrow", time.string(from: date))
        }
        let full = DateFormatter()
        full.locale = localizer.locale
        full.timeZone = calendar.timeZone
        full.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return full.string(from: date)
    }

    /// « Réussie il y a 2 h — 3 fichier(s), 5,0 Mo » ; « Jamais lancée » sans exécution.
    public func lastRun(_ record: RunRecord?) -> String {
        guard let record else { return localizer.text("last.never") }
        let label = status(record.status)
        let when = relative(record.startedAt)
        if record.status != .running, let summary = record.summary {
            return localizer.format("last.format.summary", label, when, summaryLine(summary))
        }
        return localizer.format("last.format", label, when)
    }

    /// « 3 fichier(s), 5,0 Mo » ; ajoute « , 2 erreur(s) » s'il y en a.
    public func summaryLine(_ summary: RunSummary?) -> String {
        guard let summary else { return "" }
        var parts = [
            localizer.format("summary.files", summary.filesTransferred),
            localizer.bytes(summary.bytesTransferred),
        ]
        if summary.errors > 0 { parts.append(localizer.format("summary.errors", summary.errors)) }
        return parts.joined(separator: ", ")
    }

    /// « 1,00 Go sur 3,00 Go · 45,0 Mo/s · reste 0:12 », sans durée restante, ou sans total connu.
    public func progressLine(_ info: ProgressInfo) -> String {
        let done = localizer.bytes(info.doneBytes)
        guard let total = info.totalBytes, total > 0 else { return localizer.format("progress.line.unknown", done) }
        let speed = localizer.speed(info.currentSpeed)
        if let eta = info.totalETA {
            return localizer.format("progress.line", done, localizer.bytes(total), speed, localizer.duration(eta))
        }
        return localizer.format("progress.line.noeta", done, localizer.bytes(total), speed)
    }

    public func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = localizer.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
```

`Sources/SyncMacProUI/Logic/MenuBarState.swift` :

```swift
import Foundation
import SyncKit

/// Ce que montre l'icône de la barre de menus. Priorité : déconnecté > pause globale > copie en cours >
/// pause d'une tâche > erreur > repos (une erreur est donc masquée tant qu'une copie tourne).
public enum MenuBarState: Equatable, Sendable {
    case disconnected
    case idle
    case copying(percent: Int?, count: Int)
    case paused
    case error

    public static func make(
        connection: ConnectionState, status: AgentStatus?, progress: [UUID: ProgressInfo]
    ) -> MenuBarState {
        guard connection == .connected, let status else { return .disconnected }
        if status.globalPause { return .paused }
        let running = status.tasks.filter { $0.state == .running }
        if !running.isEmpty {
            let percent = running.count == 1 ? progress[running[0].id]?.overallPercent : nil
            return .copying(percent: percent, count: running.count)
        }
        if status.tasks.contains(where: { $0.state == .paused }) { return .paused }
        let failing: Set<RunStatus> = [.failed, .blocked, .quotaReached]
        let hasError = status.tasks.contains {
            $0.state == .awaitingApproval || ($0.lastRun.map { failing.contains($0.status) } ?? false)
        }
        return hasError ? .error : .idle
    }

    public var systemImage: String {
        switch self {
        case .disconnected: return "bolt.slash"
        case .idle, .copying: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    /// Texte à côté de l'icône : « 42 % » pour une copie, « 2 copies » pour plusieurs.
    public func title(_ localizer: Localizer) -> String? {
        guard case .copying(let percent, let count) = self else { return nil }
        if count == 1 { return percent.map { "\($0) %" } }
        return localizer.format("menubar.copies", count)
    }
}
```

`Sources/SyncMacProUI/Logic/CardOrdering.swift` :

```swift
import Foundation
import SyncKit

/// En cours ou en pause, puis à valider, en attente (ou en file), puis par prochaine échéance ; désactivées en dernier.
public enum CardOrdering {
    private static func rank(_ state: TaskRunState) -> Int {
        switch state {
        case .running, .paused: return 0
        case .awaitingApproval: return 1
        case .waiting, .queued: return 2
        case .idle: return 3
        case .disabled: return 4
        }
    }

    public static func sorted(_ tasks: [AgentTaskInfo]) -> [AgentTaskInfo] {
        tasks.sorted { lhs, rhs in
            let (a, b) = (rank(lhs.state), rank(rhs.state))
            if a != b { return a < b }
            switch (lhs.nextDue, rhs.nextDue) {
            case (let x?, let y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
```

`Sources/SyncMacProUI/Logic/HistoryFilter.swift` :

```swift
import Foundation
import SyncKit

public enum HistoryPeriod: String, CaseIterable, Sendable {
    case day, week, month, all

    var interval: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .all: return nil
        }
    }
}

/// Filtres de l'historique, appliqués dans l'app sur les dernières exécutions que l'agent renvoie.
public struct HistoryFilter: Equatable, Sendable {
    public var taskID: UUID?
    /// Vide : tous les états.
    public var statuses: Set<RunStatus> = []
    public var period: HistoryPeriod = .all
    public var search = ""

    public init() {}

    public func apply(to records: [RunRecord], now: Date) -> [RunRecord] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return records.filter { record in
            if let taskID, record.taskID != taskID { return false }
            if !statuses.isEmpty, !statuses.contains(record.status) { return false }
            if let interval = period.interval, now.timeIntervalSince(record.startedAt) > interval { return false }
            if !query.isEmpty, record.taskName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
            return true
        }
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter "CardTextTests|MenuBarStateTests|CardOrderingTests|HistoryFilterTests" 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | sed -E 's|/Users/[^ ]*/||' | tail -8`
Attendu : tous passent. Si une valeur de date ou de nombre diffère (séparateurs de la locale), relever la valeur réelle : l'attendu des tests de `CardText` en français suppose `fr_FR` (virgule décimale, `HH:mm` sur 24 h).

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncMacProUI/Logic Tests/SyncMacProUITests/PresentationLogicTests.swift
git commit -m "Interface : textes de carte, état de la barre de menus, tri des cartes, filtres de l'historique" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 4 : `AgentConnecting`, `AgentModel` et sa boucle de connexion

**Fichiers :**
- Créer : `Sources/SyncMacProUI/Agent/AgentConnecting.swift`, `Sources/SyncMacProUI/Agent/Sleeping.swift`, `Sources/SyncMacProUI/Agent/AgentModel.swift`
- Tester : `Tests/SyncMacProUITests/AgentModelTests.swift`, `Tests/SyncMacProUITests/FakeAgent.swift`

**Interfaces :**
- Consomme : `AgentClient`, `AgentWatch`, `AgentStatus`, `AgentRequest`, `AgentEvent`, `ConnectionState`, `AgentClientError`.
- Produit :
  - `protocol AgentConnecting: Sendable` — `status()`, `listTasks()`, `history(taskID:limit:)`, `perform(_:)`, `startWatching(onEvent:onEnd:) async throws -> any AgentWatching` ; `protocol AgentWatching: Sendable { func cancel() }` ; `extension AgentClient: AgentConnecting`, `extension AgentWatch: AgentWatching`.
  - `protocol Sleeping: Sendable { func sleep(seconds: TimeInterval) async throws }`, `struct RealSleeper`.
  - `@MainActor @Observable final class AgentModel` — état : `connection`, `status`, `tasks: [UUID: SyncTask]`, `progress: [UUID: ProgressInfo]`, `history`, `historyError`, `busyTasks`, `globalPauseBusy`, `alertMessage` ; méthodes : `init(agent:sleeper:timing:)`, `start()`, `restart()`, `shutdown()`, `refreshNow()`, `reloadHistory()`, `runNow(_:)`, `pause(_:)`, `resume(_:)`, `stop(_:)`, `approve(_:)`, `setGlobalPause(_:)`, `static preview(...)`.
  - `AgentModel.Timing` (`debounce`, `safetyRefresh`, `backoff`, `versionRetry`), `UnavailableAgent: AgentConnecting`.

- [ ] **Étape 1 : écrire les doubles et les tests qui échouent**

`Tests/SyncMacProUITests/FakeAgent.swift` :

```swift
import Foundation
import SyncKit
@testable import SyncMacProUI

/// Agent scripté : les réponses de `status()` sont consommées dans l'ordre, la dernière se répète.
final class FakeAgent: AgentConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var statusResults: [Result<AgentStatus, Error>] = []
    private var _tasks: [SyncTask] = []
    private var _history: Result<[RunRecord], Error> = .success([])
    private var _performError: Error?
    private var _watchError: Error?
    private var _statusCalls = 0
    private var _historyCalls = 0
    private var _watchStarts = 0
    private var _watchCancels = 0
    private var _performed: [AgentRequest] = []
    private var onEvent: (@Sendable (AgentEvent) -> Void)?
    private var onEnd: (@Sendable () -> Void)?

    // MARK: réglages

    func setStatus(_ results: Result<AgentStatus, Error>...) { locked { statusResults = results } }
    func setTasks(_ tasks: [SyncTask]) { locked { _tasks = tasks } }
    func setHistory(_ result: Result<[RunRecord], Error>) { locked { _history = result } }
    func setPerformError(_ error: Error?) { locked { _performError = error } }
    func setWatchError(_ error: Error?) { locked { _watchError = error } }

    // MARK: observation

    var statusCalls: Int { locked { _statusCalls } }
    var historyCalls: Int { locked { _historyCalls } }
    var watchStarts: Int { locked { _watchStarts } }
    var watchCancels: Int { locked { _watchCancels } }
    var performed: [AgentRequest] { locked { _performed } }

    func emit(_ event: AgentEvent) { locked { onEvent }?(event) }
    func endWatch() { locked { onEnd }?() }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: AgentConnecting

    func status() async throws -> AgentStatus {
        let result: Result<AgentStatus, Error> = locked {
            _statusCalls += 1
            if statusResults.count > 1 { return statusResults.removeFirst() }
            return statusResults.first ?? .failure(AgentClientError.unreachable)
        }
        return try result.get()
    }

    func listTasks() async throws -> [SyncTask] { locked { _tasks } }

    func history(taskID: UUID?, limit: Int) async throws -> [RunRecord] {
        let result = locked { () -> Result<[RunRecord], Error> in
            _historyCalls += 1
            return _history
        }
        return try result.get()
    }

    func perform(_ request: AgentRequest) async throws {
        let error: Error? = locked {
            _performed.append(request)
            return _performError
        }
        if let error { throw error }
    }

    func startWatching(
        onEvent: @escaping @Sendable (AgentEvent) -> Void, onEnd: @escaping @Sendable () -> Void
    ) async throws -> any AgentWatching {
        let error: Error? = locked {
            _watchStarts += 1
            if _watchError == nil {
                self.onEvent = onEvent
                self.onEnd = onEnd
            }
            return _watchError
        }
        if let error { throw error }
        return FakeWatch(owner: self)
    }

    fileprivate func watchWasCancelled() { locked { _watchCancels += 1 } }
}

final class FakeWatch: AgentWatching, @unchecked Sendable {
    private let owner: FakeAgent
    init(owner: FakeAgent) { self.owner = owner }
    func cancel() { owner.watchWasCancelled() }
}

/// Sommeil piloté par le test : chaque `sleep` attend qu'on le libère, et reste annulable.
final class ManualSleeper: Sleeping, @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let seconds: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var nextID = 0
    private var _requests: [TimeInterval] = []

    /// Durées demandées, dans l'ordre.
    var requests: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func sleep(seconds: TimeInterval) async throws {
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            nextID += 1
            _requests.append(seconds)
            return nextID
        }()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, seconds: seconds, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let cancelled = waiters.first { $0.id == id }
            waiters.removeAll { $0.id == id }
            lock.unlock()
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Libère les sommeils d'une durée donnée.
    func release(seconds: TimeInterval) {
        lock.lock()
        let due = waiters.filter { $0.seconds == seconds }
        waiters.removeAll { $0.seconds == seconds }
        lock.unlock()
        due.forEach { $0.continuation.resume() }
    }

    func releaseAll() {
        lock.lock()
        let all = waiters
        waiters = []
        lock.unlock()
        all.forEach { $0.continuation.resume() }
    }
}

func makeStatus(
    paused: Bool = false, recovered: Bool = false, _ tasks: [AgentTaskInfo] = []
) -> AgentStatus {
    AgentStatus(globalPause: paused, stateRecovered: recovered, taskLoadError: nil, tasks: tasks)
}
```

`Tests/SyncMacProUITests/AgentModelTests.swift` :

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class AgentModelTests: XCTestCase {
    let id = UUID()
    var agent: FakeAgent!
    var sleeper: ManualSleeper!
    var model: AgentModel!

    override func setUp() async throws {
        agent = FakeAgent()
        sleeper = ManualSleeper()
        model = AgentModel(agent: agent, sleeper: sleeper)
    }

    override func tearDown() async throws { model.shutdown() }

    func connect(_ status: AgentStatus? = nil) async {
        agent.setStatus(.success(status ?? makeStatus([AgentTaskInfo(id: id, name: "t", state: .idle)])))
        model.start()
        let ok = await eventually { self.model.connection == .connected && self.agent.watchStarts == 1 }
        XCTAssertTrue(ok, "la connexion doit aboutir")
    }

    func testConnectsAndLoadsStatusTasksAndHistory() async {
        let task = SyncTask(id: id, name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))
        agent.setTasks([task])
        await connect()
        XCTAssertEqual(model.status?.tasks.count, 1)
        XCTAssertEqual(model.tasks[id]?.name, "t")
        XCTAssertEqual(agent.historyCalls, 1)
        XCTAssertNil(model.historyError)
    }

    func testInitialProgressComesFromTheStatus() async {
        var info = ProgressInfo(TransferSnapshot())
        info.doneBytes = 123
        await connect(makeStatus([AgentTaskInfo(id: id, name: "t", state: .running, progress: info)]))
        XCTAssertEqual(model.progress[id]?.doneBytes, 123)
    }

    func testProgressEventsAreAppliedWithoutAnyRefetch() async {
        await connect()
        var info = ProgressInfo(TransferSnapshot())
        info.overallPercent = 42
        agent.emit(.progress(id, info))
        let seen = await eventually { self.model.progress[id]?.overallPercent == 42 }
        XCTAssertTrue(seen)
        XCTAssertEqual(agent.statusCalls, 1, "l'avancement ne déclenche aucune relecture")
    }

    func testABurstOfEventsCausesASingleRefresh() async {
        await connect()
        agent.emit(.stateChanged)
        agent.emit(.taskStarted(id))
        agent.emit(.stateChanged)
        let waiting = await eventually { self.sleeper.requests.contains(0.25) }
        XCTAssertTrue(waiting)
        sleeper.release(seconds: 0.25)
        let refreshed = await eventually { self.agent.statusCalls == 2 }
        XCTAssertTrue(refreshed)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(agent.statusCalls, 2, "une seule relecture pour toute la rafale")
        XCTAssertEqual(sleeper.requests.filter { $0 == 0.25 }.count, 1)
    }

    func testTaskFinishedClearsProgressAndReloadsHistory() async {
        await connect()
        var info = ProgressInfo(TransferSnapshot())
        info.overallPercent = 80
        agent.emit(.progress(id, info))
        _ = await eventually { self.model.progress[id] != nil }
        agent.emit(.taskFinished(id, .succeeded, nil))
        _ = await eventually { self.sleeper.requests.contains(0.25) }
        XCTAssertNil(model.progress[id])
        sleeper.release(seconds: 0.25)
        let reloaded = await eventually { self.agent.historyCalls == 2 }
        XCTAssertTrue(reloaded, "une fin d'exécution recharge l'historique")
    }

    func testSafetyRefreshRunsEveryThirtySeconds() async {
        await connect()
        let waiting = await eventually { self.sleeper.requests.contains(30) }
        XCTAssertTrue(waiting)
        sleeper.release(seconds: 30)
        let refreshed = await eventually { self.agent.statusCalls >= 2 }
        XCTAssertTrue(refreshed)
    }

    func testUnreachableAgentIsRetriedWithGrowingDelays() async {
        agent.setStatus(.failure(AgentClientError.unreachable))
        model.start()
        for count in 1...6 {
            let asked = await eventually { self.sleeper.requests.count == count }
            XCTAssertTrue(asked, "attente n°\(count)")
            sleeper.releaseAll()
        }
        XCTAssertEqual(Array(sleeper.requests.prefix(6)), [1, 2, 4, 8, 15, 15])
        XCTAssertEqual(model.connection, .unreachable)
    }

    func testLostConnectionReconnectsByItself() async {
        await connect()
        agent.endWatch()
        let reconnecting = await eventually { self.model.connection == .reconnecting(attempt: 1) }
        XCTAssertTrue(reconnecting)
        let asked = await eventually { self.sleeper.requests.contains(1) }
        XCTAssertTrue(asked)
        sleeper.release(seconds: 1)
        let back = await eventually { self.model.connection == .connected && self.agent.watchStarts == 2 }
        XCTAssertTrue(back, "l'app se reconnecte sans action de l'utilisateur")
        XCTAssertEqual(agent.watchCancels, 1, "l'ancien abonnement est libéré")
    }

    func testAgentGoneAfterAGoodSessionShowsReconnectingNotUnreachable() async {
        await connect()
        agent.setStatus(.failure(AgentClientError.unreachable))
        agent.endWatch()
        let state = await eventually { self.model.connection == .reconnecting(attempt: 1) }
        XCTAssertTrue(state)
        sleeper.release(seconds: 1)
        let second = await eventually { self.model.connection == .reconnecting(attempt: 2) }
        XCTAssertTrue(second)
    }

    func testIncompatibleVersionIsReportedAndRetriedSlowly() async {
        agent.setStatus(.failure(AgentClientError.agent(.versionMismatch(agent: 9, client: 1))))
        model.start()
        let shown = await eventually { self.model.connection == .versionMismatch(agent: 9) }
        XCTAssertTrue(shown)
        let slow = await eventually { self.sleeper.requests == [60] }
        XCTAssertTrue(slow, "pas de réessai rapide sur une version incompatible")
    }

    func testActionErrorIsShownAndBusyIsCleared() async {
        await connect()
        agent.setPerformError(AgentClientError.agent(.alreadyRunning))
        await model.runNow(id)
        XCTAssertEqual(model.alertMessage, AgentError.alreadyRunning.errorDescription)
        XCTAssertTrue(model.busyTasks.isEmpty)
    }

    func testActionsAreForwardedThenStateIsRefreshed() async {
        await connect()
        let before = agent.statusCalls
        await model.pause(id)
        await model.resume(id)
        await model.stop(id)
        await model.approve(id)
        await model.setGlobalPause(true)
        XCTAssertEqual(
            agent.performed,
            [.pause(id), .resume(id), .stop(id), .approveDeletion(id), .setGlobalPause(true)]
        )
        XCTAssertEqual(agent.statusCalls, before + 5)
        XCTAssertFalse(model.globalPauseBusy)
    }

    func testShutdownReleasesTheWatch() async {
        await connect()
        model.shutdown()
        let released = await eventually { self.agent.watchCancels == 1 }
        XCTAssertTrue(released)
    }

    func testRestartConnectsAgainRightAway() async {
        agent.setStatus(.failure(AgentClientError.unreachable))
        model.start()
        _ = await eventually { self.sleeper.requests.count == 1 }
        agent.setStatus(.success(makeStatus()))
        model.restart()
        let ok = await eventually { self.model.connection == .connected }
        XCTAssertTrue(ok)
    }

    func testHistoryErrorIsKept() async {
        agent.setHistory(.failure(AgentClientError.badReply))
        await connect()
        XCTAssertNotNil(model.historyError)
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter AgentModelTests 2>&1 | grep -E "error:" | head -3`
Attendu : erreur de compilation (`AgentConnecting`, `AgentModel`, `Sleeping` inconnus).

- [ ] **Étape 3 : implémenter**

`Sources/SyncMacProUI/Agent/Sleeping.swift` :

```swift
import Foundation

/// Sommeil injectable : les tests pilotent les attentes (reconnexion, relecture groupée) sans attendre.
public protocol Sleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct RealSleeper: Sleeping {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
```

`Sources/SyncMacProUI/Agent/AgentConnecting.swift` :

```swift
import Foundation
import SyncKit

public protocol AgentWatching: Sendable {
    func cancel()
}

/// Ce que l'app attend de l'agent. `AgentClient` y répond ; les tests utilisent un faux.
public protocol AgentConnecting: Sendable {
    func status() async throws -> AgentStatus
    func listTasks() async throws -> [SyncTask]
    func history(taskID: UUID?, limit: Int) async throws -> [RunRecord]
    func perform(_ request: AgentRequest) async throws
    func startWatching(
        onEvent: @escaping @Sendable (AgentEvent) -> Void, onEnd: @escaping @Sendable () -> Void
    ) async throws -> any AgentWatching
}

extension AgentWatch: AgentWatching {}

extension AgentClient: AgentConnecting {
    public func startWatching(
        onEvent: @escaping @Sendable (AgentEvent) -> Void, onEnd: @escaping @Sendable () -> Void
    ) async throws -> any AgentWatching {
        try await watch(onEvent, onEnd: onEnd)
    }
}

/// Agent absent : tout échoue comme un agent injoignable. Sert aux aperçus et aux captures.
public struct UnavailableAgent: AgentConnecting {
    public init() {}
    public func status() async throws -> AgentStatus { throw AgentClientError.unreachable }
    public func listTasks() async throws -> [SyncTask] { throw AgentClientError.unreachable }
    public func history(taskID: UUID?, limit: Int) async throws -> [RunRecord] { throw AgentClientError.unreachable }
    public func perform(_ request: AgentRequest) async throws { throw AgentClientError.unreachable }
    public func startWatching(
        onEvent: @escaping @Sendable (AgentEvent) -> Void, onEnd: @escaping @Sendable () -> Void
    ) async throws -> any AgentWatching { throw AgentClientError.unreachable }
}
```

`Sources/SyncMacProUI/Agent/AgentModel.swift` :

```swift
import Foundation
import Observation
import os
import SyncKit

/// L'état de l'agent tel que l'app le montre : connexion, tâches, avancement, historique.
/// La boucle de connexion se rétablit seule quand l'agent redémarre.
@MainActor
@Observable
public final class AgentModel {
    public struct Timing: Sendable {
        public var debounce: TimeInterval = 0.25
        public var safetyRefresh: TimeInterval = 30
        public var backoff: [TimeInterval] = [1, 2, 4, 8, 15]
        public var versionRetry: TimeInterval = 60
        public init() {}
    }

    public private(set) var connection: ConnectionState = .connecting
    public private(set) var status: AgentStatus?
    public private(set) var tasks: [UUID: SyncTask] = [:]
    public private(set) var progress: [UUID: ProgressInfo] = [:]
    public private(set) var history: [RunRecord] = []
    public private(set) var historyError: String?
    public private(set) var busyTasks: Set<UUID> = []
    public private(set) var globalPauseBusy = false
    public var alertMessage: String?

    @ObservationIgnored private let agent: AgentConnecting
    @ObservationIgnored private let sleeper: Sleeping
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var safety: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var watching: (any AgentWatching)?
    @ObservationIgnored private var currentEnd: EndSignal?
    @ObservationIgnored private var historyDirty = false
    @ObservationIgnored private var hasConnected = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private static let log = Logger(subsystem: "com.sylvain.syncmacpro", category: "agent")

    public init(agent: AgentConnecting, sleeper: Sleeping = RealSleeper(), timing: Timing = Timing()) {
        self.agent = agent
        self.sleeper = sleeper
        self.timing = timing
    }

    /// Modèle pré-rempli pour les aperçus et les captures : aucune connexion n'est ouverte.
    public static func preview(
        connection: ConnectionState = .connected, status: AgentStatus?, tasks: [SyncTask] = [],
        progress: [UUID: ProgressInfo] = [:], history: [RunRecord] = [], historyError: String? = nil
    ) -> AgentModel {
        let model = AgentModel(agent: UnavailableAgent())
        model.connection = connection
        model.status = status
        model.tasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        model.progress = progress
        model.history = history
        model.historyError = historyError
        return model
    }

    // MARK: cycle de vie

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    /// « Réessayer » : repart tout de suite au lieu d'attendre la fin de l'attente.
    public func restart() {
        shutdown()
        failures = 0
        start()
    }

    public func shutdown() {
        loop?.cancel()
        loop = nil
        safety?.cancel()
        safety = nil
        debounce?.cancel()
        debounce = nil
        currentEnd?.fire()
        currentEnd = nil
        watching?.cancel()
        watching = nil
    }

    // MARK: boucle de connexion

    private func setConnection(_ state: ConnectionState) {
        guard connection != state else { return }
        connection = state
        Self.log.notice("connexion : \(String(describing: state), privacy: .public)")
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let delay: TimeInterval
            do {
                try await session()
                // La session s'est terminée (l'agent a disparu) : on retente vite.
                failures = 1
                setConnection(.reconnecting(attempt: 1))
                delay = timing.backoff[0]
            } catch is CancellationError {
                return
            } catch let error as AgentClientError {
                if case .agent(.versionMismatch(let agentVersion, _)) = error {
                    setConnection(.versionMismatch(agent: agentVersion))
                    delay = timing.versionRetry
                } else {
                    delay = registerFailure()
                }
            } catch {
                delay = registerFailure()
            }
            if Task.isCancelled { return }
            try? await sleeper.sleep(seconds: delay)
        }
    }

    private func registerFailure() -> TimeInterval {
        failures += 1
        setConnection(hasConnected ? .reconnecting(attempt: failures) : .unreachable)
        return timing.backoff[min(failures - 1, timing.backoff.count - 1)]
    }

    /// Se connecte, s'abonne, puis attend la fin de la connexion.
    private func session() async throws {
        let first = try await agent.status()
        let list = try await agent.listTasks()
        failures = 0
        hasConnected = true
        apply(status: first, tasks: list)
        setConnection(.connected)

        let ended = EndSignal()
        currentEnd = ended
        // Boîte à référence faible plutôt que `[weak self]` : Swift 5.10 refuse un `weak self` capturé dans une
        // closure concurrente imbriquée (« reference to captured var 'self' »).
        let target = WeakModel(self)
        watching = try await agent.startWatching(
            onEvent: { event in Task { @MainActor in target.value?.handle(event) } },
            onEnd: { ended.fire() }
        )
        await reloadHistory()
        startSafetyRefresh()
        await ended.wait()
        safety?.cancel()
        safety = nil
        watching?.cancel()
        watching = nil
        currentEnd = nil
    }

    // MARK: événements

    private func handle(_ event: AgentEvent) {
        switch event {
        case .progress(let id, let info):
            progress[id] = info
        case .taskFinished(let id, _, _):
            progress[id] = nil
            historyDirty = true
            scheduleRefresh()
        case .taskStarted, .stateChanged:
            scheduleRefresh()
        }
    }

    /// Une rafale d'événements ne fait qu'une relecture.
    private func scheduleRefresh() {
        guard debounce == nil else { return }
        debounce = Task { [weak self] in
            guard let self else { return }
            try? await self.sleeper.sleep(seconds: self.timing.debounce)
            if Task.isCancelled { return }
            await self.flushRefresh()
        }
    }

    private func flushRefresh() async {
        debounce = nil
        let includeHistory = historyDirty
        historyDirty = false
        await refreshNow()
        if includeHistory { await reloadHistory() }
    }

    private func startSafetyRefresh() {
        safety?.cancel()
        safety = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.sleeper.sleep(seconds: self.timing.safetyRefresh)
                if Task.isCancelled { return }
                await self.refreshNow()
            }
        }
    }

    // MARK: lecture

    public func refreshNow() async {
        guard let latest = try? await agent.status() else { return }
        let list = (try? await agent.listTasks()) ?? Array(tasks.values)
        apply(status: latest, tasks: list)
    }

    public func reloadHistory() async {
        do {
            history = try await agent.history(taskID: nil, limit: 500)
            historyError = nil
        } catch {
            historyError = Self.describe(error)
        }
    }

    private func apply(status new: AgentStatus, tasks list: [SyncTask]) {
        status = new
        tasks = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for info in new.tasks {
            if let current = info.progress {
                progress[info.id] = current
            } else if info.state != .running && info.state != .paused {
                progress[info.id] = nil
            }
        }
    }

    // MARK: actions

    public func runNow(_ id: UUID) async { await act(on: id) { try await $0.perform(.runNow(id)) } }
    public func pause(_ id: UUID) async { await act(on: id) { try await $0.perform(.pause(id)) } }
    public func resume(_ id: UUID) async { await act(on: id) { try await $0.perform(.resume(id)) } }
    public func stop(_ id: UUID) async { await act(on: id) { try await $0.perform(.stop(id)) } }
    public func approve(_ id: UUID) async { await act(on: id) { try await $0.perform(.approveDeletion(id)) } }

    public func setGlobalPause(_ paused: Bool) async {
        globalPauseBusy = true
        defer { globalPauseBusy = false }
        await act(on: nil) { try await $0.perform(.setGlobalPause(paused)) }
    }

    /// On attend la réponse de l'agent, puis on relit l'état : l'interface n'affiche jamais l'effet d'avance.
    private func act(on id: UUID?, _ body: (AgentConnecting) async throws -> Void) async {
        if let id { busyTasks.insert(id) }
        defer { if let id { busyTasks.remove(id) } }
        do {
            try await body(agent)
            await refreshNow()
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

final class WeakModel: @unchecked Sendable {
    weak var value: AgentModel?
    init(_ value: AgentModel) { self.value = value }
}

/// Signal de fin de connexion : `wait()` reprend dès que `fire()` a été appelé, avant ou après.
final class EndSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        fired = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter AgentModelTests 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | sed -E 's|/Users/[^ ]*/||' | tail -10` puis, 6 fois, `swift test --skip-build --filter AgentModelTests 2>&1 | grep -E "error:|Executed .* tests" | tail -1`
Attendu : 14 tests passent, à chaque exécution (contrôle d'instabilité : ces tests dépendent de l'ordonnancement des tâches).
Si un test de reconnexion échoue, relire `session()` : `ended.wait()` doit être réveillé par `fire()` appelé depuis `shutdown()` ET depuis `onEnd`.

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncMacProUI/Agent Tests/SyncMacProUITests
git commit -m "Interface : AgentModel (connexion, reconnexion, relecture groupée, actions) et protocole AgentConnecting" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 5 : installation de l'agent et « ouvrir à la connexion »

**Fichiers :**
- Créer : `Sources/SyncMacProUI/Agent/AgentInstaller.swift`
- Tester : `Tests/SyncMacProUITests/AgentInstallerTests.swift`

**Interfaces :**
- Consomme : `AgentIdentifiers.launchdLabel` (`SyncKit`).
- Produit :
  - `enum AgentInstallState: Equatable, Sendable` (`notRegistered`, `requiresApproval`, `enabled`, `notFound`, `unknown`).
  - `protocol ServiceControlling: Sendable { func status() -> AgentInstallState; func register() throws; func unregister() throws; func openSystemSettings() }` ; `struct SystemAgentService: ServiceControlling` (`SMAppService.agent`) .
  - `@MainActor @Observable final class AgentInstaller` — `state`, `errorMessage`, `init(service:)`, `refresh()`, `install()`, `uninstall()`, `openSettings()`.
  - `protocol LoginItemControlling: Sendable { var isEnabled: Bool { get }; func setEnabled(_ enabled: Bool) throws }` ; `struct SystemLoginItem` (`SMAppService.mainApp`) ; `@MainActor @Observable final class LoginItemModel` — `isEnabled`, `errorMessage`, `set(_:)`, `refresh()`.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncMacProUITests/AgentInstallerTests.swift` :

```swift
import XCTest
@testable import SyncMacProUI

private final class FakeService: ServiceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AgentInstallState
    var afterRegister: AgentInstallState = .enabled
    var registerError: Error?
    private(set) var registers = 0, unregisters = 0, settingsOpened = 0

    init(_ state: AgentInstallState) { current = state }

    func status() -> AgentInstallState { lock.lock(); defer { lock.unlock() }; return current }

    func register() throws {
        lock.lock(); defer { lock.unlock() }
        registers += 1
        if let registerError { throw registerError }
        current = afterRegister
    }

    func unregister() throws {
        lock.lock(); defer { lock.unlock() }
        unregisters += 1
        current = .notRegistered
    }

    func openSystemSettings() { lock.lock(); settingsOpened += 1; lock.unlock() }
}

private final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    var isEnabled = false
    var error: Error?
    func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
        isEnabled = enabled
    }
}

@MainActor
final class AgentInstallerTests: XCTestCase {
    func testInstallRegistersAndBecomesEnabled() {
        let service = FakeService(.notRegistered)
        let installer = AgentInstaller(service: service)
        XCTAssertEqual(installer.state, .notRegistered)
        installer.install()
        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(installer.state, .enabled)
        XCTAssertEqual(service.settingsOpened, 0)
        XCTAssertNil(installer.errorMessage)
    }

    func testInstallThatNeedsApprovalOpensSystemSettings() {
        let service = FakeService(.notRegistered)
        service.afterRegister = .requiresApproval
        let installer = AgentInstaller(service: service)
        installer.install()
        XCTAssertEqual(installer.state, .requiresApproval)
        XCTAssertEqual(service.settingsOpened, 1)
    }

    func testInstallOnAnEnabledAgentDoesNothing() {
        let service = FakeService(.enabled)
        let installer = AgentInstaller(service: service)
        installer.install()
        XCTAssertEqual(service.registers, 0)
    }

    func testInstallFailureIsReported() {
        struct Boom: LocalizedError { var errorDescription: String? { "boum" } }
        let service = FakeService(.notRegistered)
        service.registerError = Boom()
        let installer = AgentInstaller(service: service)
        installer.install()
        XCTAssertEqual(installer.errorMessage, "boum")
        XCTAssertEqual(installer.state, .notRegistered)
    }

    func testUninstallUnregisters() {
        let service = FakeService(.enabled)
        let installer = AgentInstaller(service: service)
        installer.uninstall()
        XCTAssertEqual(service.unregisters, 1)
        XCTAssertEqual(installer.state, .notRegistered)
    }

    func testRefreshReadsTheCurrentState() {
        let service = FakeService(.notFound)
        let installer = AgentInstaller(service: service)
        XCTAssertEqual(installer.state, .notFound)
    }

    func testLoginItemToggle() {
        let control = FakeLoginItem()
        let model = LoginItemModel(control: control)
        XCTAssertFalse(model.isEnabled)
        model.set(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(control.isEnabled)
        model.set(false)
        XCTAssertFalse(model.isEnabled)
    }

    func testLoginItemFailureKeepsTheRealValueAndReports() {
        struct Boom: LocalizedError { var errorDescription: String? { "refusé" } }
        let control = FakeLoginItem()
        control.error = Boom()
        let model = LoginItemModel(control: control)
        model.set(true)
        XCTAssertFalse(model.isEnabled, "l'interrupteur revient à la vraie valeur")
        XCTAssertEqual(model.errorMessage, "refusé")
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter AgentInstallerTests 2>&1 | grep -E "error:" | head -3`
Attendu : erreur de compilation.

- [ ] **Étape 3 : implémenter**

`Sources/SyncMacProUI/Agent/AgentInstaller.swift` :

```swift
import Foundation
import Observation
import ServiceManagement
import SyncKit

public enum AgentInstallState: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    /// Le plist de l'agent est absent du bundle (l'app n'est pas lancée depuis SyncMacPro.app).
    case notFound
    case unknown
}

public protocol ServiceControlling: Sendable {
    func status() -> AgentInstallState
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// Enregistrement de l'agent de l'app par `SMAppService`.
public struct SystemAgentService: ServiceControlling {
    public init() {}

    private var service: SMAppService {
        SMAppService.agent(plistName: "\(AgentIdentifiers.launchdLabel).plist")
    }

    public func status() -> AgentInstallState {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
@Observable
public final class AgentInstaller {
    public private(set) var state: AgentInstallState
    public var errorMessage: String?

    @ObservationIgnored private let service: ServiceControlling

    public init(service: ServiceControlling = SystemAgentService()) {
        self.service = service
        state = service.status()
    }

    public func refresh() { state = service.status() }

    public func install() {
        errorMessage = nil
        if service.status() != .enabled {
            do { try service.register() } catch { errorMessage = Self.describe(error) }
        }
        refresh()
        if state == .requiresApproval { service.openSystemSettings() }
    }

    public func uninstall() {
        errorMessage = nil
        do { try service.unregister() } catch { errorMessage = Self.describe(error) }
        refresh()
    }

    public func openSettings() { service.openSystemSettings() }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: ouvrir à la connexion

public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public struct SystemLoginItem: LoginItemControlling {
    public init() {}

    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
@Observable
public final class LoginItemModel {
    public private(set) var isEnabled: Bool
    public var errorMessage: String?

    @ObservationIgnored private let control: LoginItemControlling

    public init(control: LoginItemControlling = SystemLoginItem()) {
        self.control = control
        isEnabled = control.isEnabled
    }

    public func refresh() { isEnabled = control.isEnabled }

    /// En cas d'échec, l'interrupteur revient à la vraie valeur et le message s'affiche.
    public func set(_ enabled: Bool) {
        errorMessage = nil
        do { try control.setEnabled(enabled) } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        refresh()
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter AgentInstallerTests 2>&1 | grep -E "error:|Executed .* tests" | tail -3`
Attendu : 8 tests passent. Puis la suite complète : `SYNCMACPRO_RSYNC=… swift test 2>&1 | tail -3` → vert.

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncMacProUI/Agent/AgentInstaller.swift Tests/SyncMacProUITests/AgentInstallerTests.swift
git commit -m "Interface : installation de l'agent (SMAppService) et ouverture à la connexion" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 6 : tableau de bord (carte de tâche, bandeaux, en-tête) et outils de rendu

**Fichiers :**
- Créer : `Sources/SyncMacProUI/Views/Appearance.swift`, `Sources/SyncMacProUI/Views/Components.swift`, `Sources/SyncMacProUI/Views/TaskCard.swift`, `Sources/SyncMacProUI/Views/DashboardView.swift`
- Tester : `Tests/SyncMacProUITests/RenderSupport.swift`, `Tests/SyncMacProUITests/UIFixtures.swift`, `Tests/SyncMacProUITests/DashboardRenderTests.swift`

**Interfaces :**
- Consomme : `AgentModel`, `AgentInstallState`, `CardText`, `CardOrdering`, `ConnectionState` (tâches 3 à 5).
- Produit :
  - `enum Appearance: String, CaseIterable` (`auto`, `light`, `dark`) avec `colorScheme: ColorScheme?`.
  - `StatePill`, `Banner`, `ConnectionBanner(connection:installState:localizer:onRetry:onInstall:)`, `TaskCardActions`, `TaskCard(info:task:progress:busy:text:actions:)`.
  - `DashboardContent(model:installState:text:onInstall:)` (interne, testable) et `public struct DashboardView(model:installer:localizer:)` (enveloppe `TimelineView` : les « il y a… » se mettent à jour toutes les 30 s).
- Produit (tests) : `render(_:name:size:scheme:)` (écrit un PNG dans `$TMPDIR/syncmacpro-renders/`), `assertNotBlank(_:)`, `UIFixtures`.

- [ ] **Étape 1 : écrire les outils de rendu et les tests qui échouent**

`Tests/SyncMacProUITests/RenderSupport.swift` :

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// Rend une vue en image (sans toucher à l'écran) et l'enregistre en PNG pour inspection manuelle.
/// Ignoré (XCTSkip) si l'environnement ne sait pas rendre (runner sans session graphique).
@MainActor
func render<V: View>(_ view: V, name: String, size: CGSize, scheme: ColorScheme) throws -> CGImage {
    let content = view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage else {
        throw XCTSkip("ImageRenderer ne produit pas d'image dans cet environnement")
    }
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syncmacpro-renders")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
    if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    return image
}

/// L'image doit contenir plusieurs couleurs distinctes : une vue qui n'a rien dessiné est unie.
func assertNotBlank(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
    let side = 64
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let context = CGContext(
        data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return XCTFail("contexte graphique indisponible", file: file, line: line) }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    var colors = Set<UInt32>()
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let quantized = (UInt32(pixels[index] >> 4) << 8) | (UInt32(pixels[index + 1] >> 4) << 4) | UInt32(pixels[index + 2] >> 4)
        colors.insert(quantized)
    }
    XCTAssertGreaterThanOrEqual(colors.count, 4, "l'image rendue est vide ou unie", file: file, line: line)
}
```

`Tests/SyncMacProUITests/UIFixtures.swift` :

```swift
import Foundation
import SyncKit
@testable import SyncMacProUI

/// Données factices : six tâches dans tous les états, et un historique de 30 exécutions.
enum UIFixtures {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static let now = at(12, 10)
    static let french = CardText(localizer: Localizer(language: "fr"), calendar: calendar, now: now)
    static let english = CardText(localizer: Localizer(language: "en"), calendar: calendar, now: now)

    static let ids = (0..<6).map { _ in UUID() }

    static let tasks: [SyncTask] = [
        SyncTask(id: ids[0], name: "Archives NAS → Drive", source: .local(path: "/Volumes/NAS/archives"),
                 destination: .cloud(remote: "drive", path: "Sauvegardes"), mode: .mirror, schedule: .daily(hour: 3, minute: 0)),
        SyncTask(id: ids[1], name: "Photos", source: .local(path: "/Users/moi/Photos"),
                 destination: .local(path: "/Volumes/Disque/Photos"), mode: .copy, schedule: .everyMinutes(60)),
        SyncTask(id: ids[2], name: "Documents du travail avec un nom vraiment très très long pour tester la troncature",
                 source: .local(path: "/a"), destination: .local(path: "/b"), mode: .bidirectional, schedule: .whenAvailable),
        SyncTask(id: ids[3], name: "Projets vidéo", source: .local(path: "/c"), destination: .local(path: "/d"),
                 mode: .versioned, schedule: .weekdays(days: [2, 6], hour: 8, minute: 30)),
        SyncTask(id: ids[4], name: "Téléchargements", source: .local(path: "/e"), destination: .local(path: "/f"),
                 mode: .move, schedule: .manual),
        SyncTask(id: ids[5], name: "Ancienne sauvegarde", source: .local(path: "/g"), destination: .local(path: "/h"),
                 mode: .copy, schedule: .manual, isEnabled: false),
    ]

    static func record(
        _ index: Int, _ status: RunStatus, hoursAgo: Double, files: Int = 120, bytes: Int64 = 3_221_225_472,
        errors: Int = 0, message: String? = nil
    ) -> RunRecord {
        let start = now.addingTimeInterval(-hoursAgo * 3_600)
        return RunRecord(
            taskID: ids[index], taskName: tasks[index].name, engine: .rsync, mode: tasks[index].mode,
            startedAt: start, finishedAt: status == .running ? nil : start.addingTimeInterval(754), status: status,
            summary: RunSummary(
                filesTransferred: files, bytesTransferred: bytes, errors: errors, durationSeconds: 754, message: message
            )
        )
    }

    static func progress(done: Int64 = 1_288_490_188, total: Int64 = 3_221_225_472, percent: Int = 40) -> ProgressInfo {
        var snapshot = TransferSnapshot()
        snapshot.doneBytes = done
        snapshot.totalBytes = total
        snapshot.overallPercent = percent
        snapshot.currentName = "Vacances 2025/IMG_0042.mov"
        snapshot.currentSpeed = 47_185_920
        snapshot.totalETA = 41
        return ProgressInfo(snapshot)
    }

    static let infos: [AgentTaskInfo] = [
        AgentTaskInfo(id: ids[0], name: tasks[0].name, state: .awaitingApproval, nextDue: at(13, 3),
                      lastRun: record(0, .blocked, hoursAgo: 7, message: "Bloqué : 412 suppression(s) sur 1 200 fichier(s) (34 %), au-dessus du seuil de 25 %.")),
        AgentTaskInfo(id: ids[1], name: tasks[1].name, state: .running, nextDue: at(12, 11),
                      lastRun: record(1, .succeeded, hoursAgo: 2), progress: progress()),
        AgentTaskInfo(id: ids[2], name: tasks[2].name, state: .waiting(reason: "destination inaccessible"),
                      lastRun: record(2, .failed, hoursAgo: 30, errors: 3)),
        AgentTaskInfo(id: ids[3], name: tasks[3].name, state: .paused, nextDue: at(16, 8, 30),
                      lastRun: record(3, .succeeded, hoursAgo: 50), progress: progress(done: 500_000_000, percent: 15)),
        AgentTaskInfo(id: ids[4], name: tasks[4].name, state: .idle, lastRun: nil),
        AgentTaskInfo(id: ids[5], name: tasks[5].name, state: .disabled, lastRun: record(5, .stopped, hoursAgo: 400)),
    ]

    static func status(paused: Bool = false, recovered: Bool = false, taskLoadError: String? = nil) -> AgentStatus {
        AgentStatus(globalPause: paused, stateRecovered: recovered, taskLoadError: taskLoadError, tasks: infos)
    }

    @MainActor
    static func model(
        connection: ConnectionState = .connected, paused: Bool = false, recovered: Bool = false,
        empty: Bool = false
    ) -> AgentModel {
        let value = empty
            ? AgentStatus(globalPause: paused, stateRecovered: false, taskLoadError: nil, tasks: [])
            : status(paused: paused, recovered: recovered)
        return AgentModel.preview(
            connection: connection, status: value, tasks: empty ? [] : tasks,
            progress: [ids[1]: progress(), ids[3]: progress(done: 500_000_000, percent: 15)],
            history: history()
        )
    }

    static func history() -> [RunRecord] {
        let statuses: [RunStatus] = [.succeeded, .succeeded, .failed, .succeeded, .blocked, .quotaReached, .interrupted, .stopped]
        return (0..<30).map { index in
            record(index % 5, statuses[index % statuses.count], hoursAgo: Double(index) * 5.5 + 1,
                   files: 40 + index * 13, bytes: Int64(index + 1) * 98_765_432,
                   errors: statuses[index % statuses.count] == .failed ? 3 : 0,
                   message: statuses[index % statuses.count] == .failed ? "rsync : disque plein (code 11)" : nil)
        }
    }
}
```

`Tests/SyncMacProUITests/DashboardRenderTests.swift` :

```swift
import SwiftUI
import XCTest
@testable import SyncMacProUI

@MainActor
final class DashboardRenderTests: XCTestCase {
    func content(_ model: AgentModel, install: AgentInstallState = .enabled, text: CardText = UIFixtures.french) -> some View {
        DashboardContent(model: model, installState: install, text: text, onInstall: {})
    }

    func testDashboardRendersInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(content(UIFixtures.model()), name: "dashboard", size: CGSize(width: 900, height: 760), scheme: scheme)
            assertNotBlank(image)
        }
    }

    func testDashboardRendersInEnglish() throws {
        let image = try render(
            content(UIFixtures.model(), text: UIFixtures.english), name: "dashboard-en",
            size: CGSize(width: 900, height: 760), scheme: .light
        )
        assertNotBlank(image)
    }

    func testGlobalPauseAndRecoveredBannerRender() throws {
        let model = UIFixtures.model(paused: true, recovered: true)
        let image = try render(content(model), name: "dashboard-paused", size: CGSize(width: 900, height: 760), scheme: .light)
        assertNotBlank(image)
    }

    func testConnectionBannersRender() throws {
        let cases: [(String, ConnectionState, AgentInstallState)] = [
            ("unreachable", .unreachable, .notRegistered),
            ("reconnecting", .reconnecting(attempt: 3), .enabled),
            ("version", .versionMismatch(agent: 7), .enabled),
            ("connecting", .connecting, .enabled),
        ]
        for (name, connection, install) in cases {
            let model = AgentModel.preview(connection: connection, status: nil)
            let image = try render(
                content(model, install: install), name: "banner-\(name)",
                size: CGSize(width: 700, height: 220), scheme: .light
            )
            assertNotBlank(image)
        }
    }

    func testEmptyStateRenders() throws {
        let image = try render(
            content(UIFixtures.model(empty: true)), name: "dashboard-empty",
            size: CGSize(width: 700, height: 360), scheme: .dark
        )
        assertNotBlank(image)
    }

    func testCardForAnUnknownTaskDoesNotCrash() throws {
        // `listTasks` en retard : la carte existe mais le modèle ne connaît pas encore la tâche.
        let info = UIFixtures.infos[1]
        let card = TaskCard(
            info: info, task: nil, progress: nil, busy: true, text: UIFixtures.french, actions: TaskCardActions()
        )
        let image = try render(card, name: "card-unknown", size: CGSize(width: 360, height: 260), scheme: .light)
        assertNotBlank(image)
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter DashboardRenderTests 2>&1 | grep -E "error:" | head -3`
Attendu : erreur de compilation (`DashboardContent`, `TaskCard`… inconnus).

- [ ] **Étape 3 : implémenter**

`Sources/SyncMacProUI/Views/Appearance.swift` :

```swift
import SwiftUI

/// Apparence choisie dans les Réglages (clé `appearance` de `UserDefaults`).
public enum Appearance: String, CaseIterable, Sendable {
    case auto, light, dark

    public var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
```

`Sources/SyncMacProUI/Views/Components.swift` :

```swift
import SwiftUI
import SyncKit

struct StatePill: View {
    let state: TaskRunState
    let label: String

    private var tint: Color {
        switch state {
        case .running: return .blue
        case .paused: return .orange
        case .queued, .disabled: return .gray
        case .waiting: return .yellow
        case .awaitingApproval: return .red
        case .idle: return .green
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint == .yellow ? Color.primary : tint)
    }
}

struct Banner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    var message: String? = nil
    var spinner = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionBanner: View {
    let connection: ConnectionState
    let installState: AgentInstallState
    let localizer: Localizer
    let onRetry: () -> Void
    let onInstall: () -> Void

    var body: some View {
        switch connection {
        case .connected:
            EmptyView()
        case .connecting:
            Banner(systemImage: "bolt", tint: .secondary, title: localizer.text("connection.connecting"), spinner: true) {}
        case .reconnecting(let attempt):
            Banner(
                systemImage: "bolt", tint: .orange,
                title: localizer.format("connection.reconnecting", attempt), spinner: true
            ) {}
        case .unreachable:
            Banner(
                systemImage: "bolt.slash", tint: .red, title: localizer.text("connection.unreachable.title"),
                message: localizer.text("connection.unreachable.body")
            ) {
                HStack {
                    if installState == .notRegistered {
                        Button(localizer.text("agent.install"), action: onInstall)
                    }
                    Button(localizer.text("connection.retry"), action: onRetry)
                }
            }
        case .versionMismatch(let agent):
            Banner(
                systemImage: "exclamationmark.triangle", tint: .red, title: localizer.text("connection.version.title"),
                message: localizer.format("connection.version.body", agent)
            ) {}
        }
    }
}
```

`Sources/SyncMacProUI/Views/TaskCard.swift` :

```swift
import SwiftUI
import SyncKit

struct TaskCardActions {
    var run: () -> Void = {}
    var pause: () -> Void = {}
    var resume: () -> Void = {}
    var stop: () -> Void = {}
    var approve: () -> Void = {}
}

struct TaskCard: View {
    let info: AgentTaskInfo
    /// `nil` tant que `listTasks` ne connaît pas la tâche : la carte reste affichable, sans mode ni planification.
    let task: SyncTask?
    let progress: ProgressInfo?
    let busy: Bool
    let text: CardText
    let actions: TaskCardActions

    private var l: Localizer { text.localizer }
    private var isActive: Bool { info.state == .running || info.state == .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.name).font(.headline).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                StatePill(state: info.state, label: text.state(info.state))
            }
            if let task {
                Text("\(text.mode(task.mode)) · \(text.schedule(task.schedule))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if isActive { progressSection }
            if info.state == .awaitingApproval {
                Text(l.format("card.approval.body", info.lastRun?.summary?.message ?? ""))
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(l.format("card.last", text.lastRun(info.lastRun)))
                Text(l.format("card.next", text.nextRun(info.nextDue)))
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack { buttons }.controlSize(.small)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(info.name), \(text.state(info.state))")
    }

    @ViewBuilder private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress {
                ProgressView(value: fraction(progress))
                    .progressViewStyle(.linear)
                    .accessibilityLabel(l.text("state.running"))
                    .accessibilityValue("\(progress.overallPercent ?? Int(fraction(progress) * 100)) %")
                Text(text.progressLine(progress)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let name = progress.currentName {
                    Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func fraction(_ info: ProgressInfo) -> Double {
        if let percent = info.overallPercent { return min(1, max(0, Double(percent) / 100)) }
        guard let total = info.totalBytes, total > 0 else { return 0 }
        return min(1, Double(info.doneBytes) / Double(total))
    }

    @ViewBuilder private var buttons: some View {
        switch info.state {
        case .running:
            button("card.pause", "pause.fill", actions.pause)
            button("card.stop", "stop.fill", actions.stop)
        case .paused:
            button("card.resume", "play.fill", actions.resume)
            button("card.stop", "stop.fill", actions.stop)
        case .queued:
            button("card.stop", "stop.fill", actions.stop)
        case .awaitingApproval:
            Button(action: actions.approve) { Label(l.text("card.approve"), systemImage: "checkmark.shield") }
                .buttonStyle(.borderedProminent).disabled(busy)
            button("card.run", "play.fill", actions.run)
        case .idle, .waiting, .disabled:
            button("card.run", "play.fill", actions.run)
        }
    }

    private func button(_ key: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(l.text(key), systemImage: symbol) }.disabled(busy)
    }
}
```

`Sources/SyncMacProUI/Views/DashboardView.swift` :

```swift
import SwiftUI
import SyncKit

struct DashboardContent: View {
    let model: AgentModel
    let installState: AgentInstallState
    let text: CardText
    let onInstall: () -> Void

    private var l: Localizer { text.localizer }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ConnectionBanner(
                    connection: model.connection, installState: installState, localizer: l,
                    onRetry: { model.restart() }, onInstall: onInstall
                )
                if model.status?.stateRecovered == true {
                    Banner(systemImage: "exclamationmark.triangle", tint: .orange, title: l.text("banner.recovered")) {
                        Button(l.text("dashboard.resume")) { Task { await model.setGlobalPause(false) } }
                    }
                }
                if let error = model.status?.taskLoadError {
                    Banner(
                        systemImage: "exclamationmark.triangle", tint: .orange,
                        title: l.format("banner.tasksfile", error)
                    ) {}
                }
                content
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Text(l.text("dashboard.title")).font(.largeTitle.bold())
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                pauseButton
                if model.status?.globalPause == true {
                    Text(l.text("dashboard.pause.on")).font(.caption.bold()).foregroundStyle(.orange)
                }
                Text(l.text("dashboard.pause.help"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: 260, alignment: .trailing)
        }
    }

    @ViewBuilder private var pauseButton: some View {
        let paused = model.status?.globalPause == true
        Button {
            Task { await model.setGlobalPause(!paused) }
        } label: {
            Label(
                paused ? l.text("dashboard.resume") : l.text("dashboard.pause.global"),
                systemImage: paused ? "play.fill" : "pause.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(paused ? .green : .accentColor)
        .disabled(model.globalPauseBusy || model.connection != .connected)
    }

    @ViewBuilder private var content: some View {
        if let status = model.status {
            if status.tasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(l.text("dashboard.empty.title")).font(.title3.bold())
                    Text(l.text("dashboard.empty.body")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(CardOrdering.sorted(status.tasks)) { info in
                        TaskCard(
                            info: info, task: model.tasks[info.id], progress: model.progress[info.id],
                            busy: model.busyTasks.contains(info.id), text: text, actions: actions(for: info.id)
                        )
                    }
                }
            }
        }
    }

    private func actions(for id: UUID) -> TaskCardActions {
        TaskCardActions(
            run: { Task { await model.runNow(id) } },
            pause: { Task { await model.pause(id) } },
            resume: { Task { await model.resume(id) } },
            stop: { Task { await model.stop(id) } },
            approve: { Task { await model.approve(id) } }
        )
    }
}

public struct DashboardView: View {
    let model: AgentModel
    let installer: AgentInstaller
    let localizer: Localizer

    public init(model: AgentModel, installer: AgentInstaller, localizer: Localizer = .system) {
        self.model = model
        self.installer = installer
        self.localizer = localizer
    }

    public var body: some View {
        // Les « il y a 2 h » et « demain à 03:00 » se recalculent toutes les 30 s.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            DashboardContent(
                model: model, installState: installer.state,
                text: CardText(localizer: localizer, now: context.date),
                onInstall: { installer.install(); model.restart() }
            )
        }
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter DashboardRenderTests 2>&1 | grep -E "error:|Executed .* tests|skipped" | sed -E 's|/Users/[^ ]*/||' | tail -6`
Attendu : 6 tests passent (ou sont ignorés avec le message « ImageRenderer ne produit pas d'image » si l'environnement n'a pas de session graphique : dans ce cas, le noter dans le journal et ne pas continuer sans vérification visuelle manuelle plus tard).

- [ ] **Étape 5 : inspecter les images**

Lire avec l'outil Read les fichiers `$TMPDIR/syncmacpro-renders/dashboard-light.png`, `dashboard-dark.png`, `dashboard-en-light.png`, `banner-unreachable-light.png` (le dossier : `echo "$TMPDIR/syncmacpro-renders"` ; `ls` pour lister).
Attendu : six cartes visibles (une avec barre de progression bleue et ligne « 1,20 Go sur 3,00 Go · 45,0 Mo/s · reste 0:41 », une en pause, une avec le motif de blocage en rouge et le bouton « Valider les suppressions », une désactivée), le nom très long tronqué, l'en-tête avec « Pause globale ». Si les matériaux (`.regularMaterial`) ne se rendent pas hors écran (cartes sans fond), c'est une limite de `ImageRenderer`, pas un défaut : le noter. Si la grille `LazyVGrid` est vide ou incomplète dans l'image, la remplacer par un `VStack` de lignes de `HStack` **dans le rendu seulement** n'est pas souhaitable : relever le constat dans le journal et vérifier la grille dans l'app à la tâche 10.

- [ ] **Étape 6 : commit**

```bash
git add Sources/SyncMacProUI/Views Tests/SyncMacProUITests
git commit -m "Interface : tableau de bord (cartes, bandeaux, pause globale) et outils de rendu" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 7 : barre de menus (icône et panneau)

**Fichiers :**
- Créer : `Sources/SyncMacProUI/Views/MenuBarViews.swift`
- Tester : `Tests/SyncMacProUITests/MenuBarRenderTests.swift`

**Interfaces :**
- Consomme : `MenuBarState`, `AgentModel`, `ConnectionBanner`, `CardText`.
- Produit : `public struct MenuBarLabel(state:localizer:)`, `public struct MenuBarPanel(model:text:onOpen:onQuit:)`.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncMacProUITests/MenuBarRenderTests.swift` :

```swift
import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class MenuBarRenderTests: XCTestCase {
    func testPanelRendersWithActiveCopiesAndUpcomingRuns() throws {
        for scheme in [ColorScheme.light, .dark] {
            let panel = MenuBarPanel(model: UIFixtures.model(), text: UIFixtures.french, onOpen: {}, onQuit: {})
            let image = try render(panel, name: "menubar-panel", size: CGSize(width: 320, height: 420), scheme: scheme)
            assertNotBlank(image)
        }
    }

    func testPanelRendersWhenNothingRunsAndWhenDisconnected() throws {
        let idle = AgentModel.preview(status: AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: []))
        let image1 = try render(
            MenuBarPanel(model: idle, text: UIFixtures.english, onOpen: {}, onQuit: {}),
            name: "menubar-idle", size: CGSize(width: 320, height: 260), scheme: .light
        )
        assertNotBlank(image1)
        let down = AgentModel.preview(connection: .unreachable, status: nil)
        let image2 = try render(
            MenuBarPanel(model: down, text: UIFixtures.french, onOpen: {}, onQuit: {}),
            name: "menubar-down", size: CGSize(width: 320, height: 300), scheme: .dark
        )
        assertNotBlank(image2)
    }

    func testLabelsRenderForEveryState() throws {
        let states: [MenuBarState] = [
            .idle, .copying(percent: 42, count: 1), .copying(percent: nil, count: 3), .paused, .error, .disconnected,
        ]
        for (index, state) in states.enumerated() {
            let label = MenuBarLabel(state: state, localizer: Localizer(language: "fr")).padding(8)
            let image = try render(label, name: "menubar-label-\(index)", size: CGSize(width: 90, height: 28), scheme: .light)
            XCTAssertGreaterThan(image.width, 0)
        }
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter MenuBarRenderTests 2>&1 | grep -E "error:" | head -3`
Attendu : erreur de compilation.

- [ ] **Étape 3 : implémenter**

`Sources/SyncMacProUI/Views/MenuBarViews.swift` :

```swift
import SwiftUI
import SyncKit

/// Icône de la barre de menus : symbole selon l'état, et « 42 % » ou « 2 copies » pendant une copie.
public struct MenuBarLabel: View {
    let state: MenuBarState
    let localizer: Localizer

    public init(state: MenuBarState, localizer: Localizer = .system) {
        self.state = state
        self.localizer = localizer
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.systemImage)
            if let title = state.title(localizer) { Text(title).monospacedDigit() }
        }
    }
}

/// Panneau de la barre de menus : copies actives, prochaines exécutions, pause globale, ouvrir, quitter.
public struct MenuBarPanel: View {
    let model: AgentModel
    let text: CardText
    let onOpen: () -> Void
    let onQuit: () -> Void

    public init(model: AgentModel, text: CardText, onOpen: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.model = model
        self.text = text
        self.onOpen = onOpen
        self.onQuit = onQuit
    }

    private var l: Localizer { text.localizer }
    private var tasks: [AgentTaskInfo] { model.status?.tasks ?? [] }
    private var active: [AgentTaskInfo] { tasks.filter { $0.state == .running || $0.state == .paused } }
    private var upcoming: [AgentTaskInfo] {
        let planned = tasks.filter { $0.nextDue != nil && $0.state != .disabled }
        return Array(planned.sorted { ($0.nextDue ?? .distantFuture) < ($1.nextDue ?? .distantFuture) }.prefix(3))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.connection != .connected {
                ConnectionBanner(
                    connection: model.connection, installState: .unknown, localizer: l,
                    onRetry: { model.restart() }, onInstall: {}
                )
            }
            section(l.text("menubar.active")) {
                if active.isEmpty {
                    Text(l.text("menubar.none")).foregroundStyle(.secondary)
                } else {
                    ForEach(active) { activeRow($0) }
                }
            }
            section(l.text("menubar.upcoming")) {
                if upcoming.isEmpty {
                    Text(l.text("menubar.nonext")).foregroundStyle(.secondary)
                } else {
                    ForEach(upcoming) { info in
                        HStack {
                            Text(info.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(text.nextRun(info.nextDue)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.callout)
                    }
                }
            }
            Divider()
            pauseButton
            HStack {
                Button(l.text("menubar.open"), action: onOpen)
                Spacer()
                Button(l.text("menubar.quit"), action: onQuit)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func activeRow(_ info: AgentTaskInfo) -> some View {
        let progress = model.progress[info.id]
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(info.name).lineLimit(1)
                Spacer(minLength: 8)
                Text(text.state(info.state)).font(.caption).foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: Double(progress.overallPercent ?? 0) / 100)
                Text(text.progressLine(progress)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var pauseButton: some View {
        let paused = model.status?.globalPause == true
        Button {
            Task { await model.setGlobalPause(!paused) }
        } label: {
            Label(
                paused ? l.text("dashboard.resume") : l.text("dashboard.pause.global"),
                systemImage: paused ? "play.fill" : "pause.fill"
            )
        }
        .disabled(model.globalPauseBusy || model.connection != .connected)
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter MenuBarRenderTests 2>&1 | grep -E "error:|Executed .* tests|skipped" | sed -E 's|/Users/[^ ]*/||' | tail -4`
Attendu : 3 tests passent.

- [ ] **Étape 5 : inspecter les images**

Lire avec l'outil Read `$TMPDIR/syncmacpro-renders/menubar-panel-light.png`, `menubar-down-dark.png`, `menubar-label-1-light.png`.
Attendu : le panneau liste les deux copies (en cours et en pause) avec barre et ligne de progression, trois prochaines exécutions triées, le bouton de pause globale et « Ouvrir / Quitter » ; le panneau déconnecté montre le bandeau rouge avec Réessayer ; l'étiquette « 42 % » à côté de l'icône.

- [ ] **Étape 6 : commit**

```bash
git add Sources/SyncMacProUI/Views/MenuBarViews.swift Tests/SyncMacProUITests/MenuBarRenderTests.swift
git commit -m "Interface : icône et panneau de la barre de menus" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 8 : historique

**Fichiers :**
- Créer : `Sources/SyncMacProUI/Views/HistoryView.swift`
- Tester : `Tests/SyncMacProUITests/HistoryRenderTests.swift`

**Interfaces :**
- Consomme : `AgentModel.history`, `historyError`, `reloadHistory()`, `HistoryFilter`, `CardText`, `RunRecord`.
- Produit : `public struct HistoryView(model:localizer:filter:selection:now:)` : barre de filtres (tâche, états, période, recherche), tableau (date, tâche, état, durée, fichiers, taille, erreurs), volet de détail. Le tableau est dessiné avec des `HStack` (pas `Table`) : `Table` s'appuie sur `NSTableView`, que `ImageRenderer` ne sait pas rendre ; la sélection et les flèches du clavier sont gérées à la main (`focusable` + `onMoveCommand`).

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncMacProUITests/HistoryRenderTests.swift` :

```swift
import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class HistoryRenderTests: XCTestCase {
    func view(
        _ model: AgentModel, text: CardText = UIFixtures.french, filter: HistoryFilter = HistoryFilter(),
        selection: UUID? = nil
    ) -> HistoryView {
        HistoryView(model: model, localizer: text.localizer, filter: filter, selection: selection, now: UIFixtures.now)
    }

    func testHistoryRendersInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let model = UIFixtures.model()
            let selected = model.history[2].id
            let image = try render(
                view(model, selection: selected), name: "history", size: CGSize(width: 980, height: 620), scheme: scheme
            )
            assertNotBlank(image)
        }
    }

    func testFilteredEmptyAndErrorStatesRender() throws {
        var filter = HistoryFilter()
        filter.search = "zzzz"
        let filtered = try render(
            view(UIFixtures.model(), filter: filter), name: "history-filtered",
            size: CGSize(width: 980, height: 300), scheme: .light
        )
        assertNotBlank(filtered)
        let empty = AgentModel.preview(status: nil, history: [])
        let emptyImage = try render(
            view(empty, text: UIFixtures.english), name: "history-empty",
            size: CGSize(width: 980, height: 300), scheme: .light
        )
        assertNotBlank(emptyImage)
        let failing = AgentModel.preview(status: nil, history: [], historyError: "base verrouillée")
        let errorImage = try render(
            view(failing), name: "history-error", size: CGSize(width: 980, height: 300), scheme: .dark
        )
        assertNotBlank(errorImage)
    }

    func test500RowsDoNotBreakTheView() throws {
        let many = (0..<500).map { UIFixtures.record($0 % 5, .succeeded, hoursAgo: Double($0)) }
        let model = AgentModel.preview(status: nil, history: many)
        let image = try render(view(model), name: "history-500", size: CGSize(width: 980, height: 620), scheme: .light)
        assertNotBlank(image)
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter HistoryRenderTests 2>&1 | grep -E "error:" | head -3`
Attendu : erreur de compilation (`HistoryView` inconnu).

- [ ] **Étape 3 : implémenter**

`Sources/SyncMacProUI/Views/HistoryView.swift` :

```swift
import SwiftUI
import SyncKit

public struct HistoryView: View {
    let model: AgentModel
    let localizer: Localizer
    let now: Date?
    @State private var filter: HistoryFilter
    @State private var selection: UUID?

    public init(
        model: AgentModel, localizer: Localizer = .system, filter: HistoryFilter = HistoryFilter(),
        selection: UUID? = nil, now: Date? = nil
    ) {
        self.model = model
        self.localizer = localizer
        self.now = now
        _filter = State(initialValue: filter)
        _selection = State(initialValue: selection)
    }

    private enum Column {
        static let date: CGFloat = 150, status: CGFloat = 110, duration: CGFloat = 70
        static let files: CGFloat = 70, size: CGFloat = 90, errors: CGFloat = 60
    }

    public var body: some View {
        let text = CardText(localizer: localizer, now: now ?? Date())
        let rows = filter.apply(to: model.history, now: text.now)
        VStack(spacing: 0) {
            filterBar(text)
            Divider()
            if let error = model.historyError {
                Banner(
                    systemImage: "exclamationmark.triangle", tint: .red,
                    title: localizer.format("history.error", error)
                ) {
                    Button(localizer.text("connection.retry")) { Task { await model.reloadHistory() } }
                }
                .padding(12)
            }
            if rows.isEmpty {
                Spacer()
                Text(model.history.isEmpty ? localizer.text("history.empty") : localizer.text("history.empty.filtered"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                table(rows, text)
            }
            Divider()
            detail(rows, text)
        }
    }

    // MARK: filtres

    private func filterBar(_ text: CardText) -> some View {
        HStack(spacing: 12) {
            Picker(localizer.text("history.filter.task"), selection: $filter.taskID) {
                Text(localizer.text("history.filter.alltasks")).tag(UUID?.none)
                ForEach(taskChoices, id: \.0) { Text($0.1).tag(UUID?.some($0.0)) }
            }
            .frame(maxWidth: 220)
            Menu {
                ForEach(RunStatus.allCases, id: \.self) { status in
                    Toggle(text.status(status), isOn: binding(for: status))
                }
            } label: {
                Text(
                    filter.statuses.isEmpty
                        ? localizer.text("history.filter.allstatus")
                        : "\(localizer.text("history.filter.status")) (\(filter.statuses.count))"
                )
            }
            .frame(maxWidth: 170)
            Picker("", selection: $filter.period) {
                ForEach(HistoryPeriod.allCases, id: \.self) { Text(periodLabel($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
            TextField(localizer.text("history.search"), text: $filter.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
        }
        .padding(12)
    }

    private var taskChoices: [(UUID, String)] {
        var seen = Set<UUID>()
        var choices: [(UUID, String)] = []
        for record in model.history where seen.insert(record.taskID).inserted {
            choices.append((record.taskID, record.taskName))
        }
        return choices.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private func binding(for status: RunStatus) -> Binding<Bool> {
        Binding(
            get: { filter.statuses.contains(status) },
            set: { isOn in
                if isOn { filter.statuses.insert(status) } else { filter.statuses.remove(status) }
            }
        )
    }

    private func periodLabel(_ period: HistoryPeriod) -> String {
        switch period {
        case .day: return localizer.text("history.period.day")
        case .week: return localizer.text("history.period.week")
        case .month: return localizer.text("history.period.month")
        case .all: return localizer.text("history.period.all")
        }
    }

    // MARK: tableau

    private func table(_ rows: [RunRecord], _ text: CardText) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                header(localizer.text("history.column.date"), width: Column.date)
                header(localizer.text("history.column.task"), width: nil)
                header(localizer.text("history.column.status"), width: Column.status)
                header(localizer.text("history.column.duration"), width: Column.duration)
                header(localizer.text("history.column.files"), width: Column.files)
                header(localizer.text("history.column.size"), width: Column.size)
                header(localizer.text("history.column.errors"), width: Column.errors)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { record in
                        row(record, text)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = record.id }
                    }
                }
            }
            .focusable()
            .onMoveCommand { direction in move(direction, in: rows) }
        }
    }

    private func header(_ title: String, width: CGFloat?) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func row(_ record: RunRecord, _ text: CardText) -> some View {
        let summary = record.summary
        return HStack(spacing: 8) {
            Text(text.dateTime(record.startedAt)).frame(width: Column.date, alignment: .leading)
            Text(record.taskName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(text.status(record.status)).foregroundStyle(color(record.status)).frame(width: Column.status, alignment: .leading)
            Text(durationText(record, text)).frame(width: Column.duration, alignment: .leading)
            Text("\(summary?.filesTransferred ?? 0)").frame(width: Column.files, alignment: .leading)
            Text(localizer.bytes(summary?.bytesTransferred ?? 0)).frame(width: Column.size, alignment: .leading)
            Text("\(summary?.errors ?? 0)").frame(width: Column.errors, alignment: .leading)
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selection == record.id ? Color.accentColor.opacity(0.2) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection == record.id ? .isSelected : [])
    }

    private func color(_ status: RunStatus) -> Color {
        switch status {
        case .succeeded: return .green
        case .failed, .blocked, .quotaReached: return .red
        case .running: return .blue
        case .interrupted, .stopped: return .orange
        }
    }

    private func durationText(_ record: RunRecord, _ text: CardText) -> String {
        if let seconds = record.summary?.durationSeconds, record.status != .running, seconds > 0 {
            return localizer.duration(seconds)
        }
        if let end = record.finishedAt { return localizer.duration(end.timeIntervalSince(record.startedAt)) }
        return "—"
    }

    private func move(_ direction: MoveCommandDirection, in rows: [RunRecord]) {
        guard !rows.isEmpty else { return }
        let current = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        switch direction {
        case .down: selection = rows[min((current ?? -1) + 1, rows.count - 1)].id
        case .up: selection = rows[max((current ?? rows.count) - 1, 0)].id
        default: break
        }
    }

    // MARK: détail

    @ViewBuilder
    private func detail(_ rows: [RunRecord], _ text: CardText) -> some View {
        Group {
            if let record = rows.first(where: { $0.id == selection }) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text(localizer.text("history.column.task")).foregroundStyle(.secondary)
                        Text("\(record.taskName) — \(text.status(record.status))").bold()
                    }
                    GridRow {
                        Text(localizer.text("history.detail.engine")).foregroundStyle(.secondary)
                        Text("\(record.engine.rawValue) · \(text.mode(record.mode))")
                    }
                    GridRow {
                        Text(localizer.text("history.detail.started")).foregroundStyle(.secondary)
                        Text(text.dateTime(record.startedAt))
                    }
                    if let end = record.finishedAt {
                        GridRow {
                            Text(localizer.text("history.detail.finished")).foregroundStyle(.secondary)
                            Text(text.dateTime(end))
                        }
                    }
                    GridRow {
                        Text(localizer.text("history.column.files")).foregroundStyle(.secondary)
                        Text(text.summaryLine(record.summary))
                    }
                    if let message = record.summary?.message, !message.isEmpty {
                        GridRow(alignment: .top) {
                            Text(localizer.text("history.detail.message")).foregroundStyle(.secondary)
                            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
            } else {
                Text(localizer.text("history.detail.none")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(12)
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter HistoryRenderTests 2>&1 | grep -E "error:|Executed .* tests|skipped" | sed -E 's|/Users/[^ ]*/||' | tail -4`
Attendu : 3 tests passent. Puis `swift test --filter StringsCompletenessTests 2>&1 | grep -E "error:|Executed .* tests" | tail -2` : toutes les clés utilisées par les vues des tâches 6 à 8 doivent exister (sinon, ajouter la clé manquante **dans les deux fichiers** de chaînes).

- [ ] **Étape 5 : inspecter les images**

Lire `$TMPDIR/syncmacpro-renders/history-light.png`, `history-dark.png`, `history-error-dark.png`.
Attendu : barre de filtres, en-têtes de colonnes, lignes colorées par état, la ligne sélectionnée surlignée, le volet de détail avec le message « rsync : disque plein (code 11) » ; l'état d'erreur montre le bandeau rouge avec Réessayer.

- [ ] **Étape 6 : commit**

```bash
git add Sources/SyncMacProUI/Views/HistoryView.swift Tests/SyncMacProUITests/HistoryRenderTests.swift
git commit -m "Interface : historique (filtres, tableau, détail, clavier)" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 9 : réglages, accueil et fenêtre principale

**Fichiers :**
- Créer : `Sources/SyncMacProUI/Views/SettingsView.swift`, `Sources/SyncMacProUI/Views/OnboardingView.swift`, `Sources/SyncMacProUI/Views/RootView.swift`
- Tester : `Tests/SyncMacProUITests/RootViewTests.swift`

**Interfaces :**
- Consomme : `AgentInstaller`, `LoginItemModel`, `Appearance`, `AgentModel`, `DashboardView`, `HistoryView`, `AgentPaths`.
- Produit : `public struct SettingsView(installer:loginItem:localizer:)`, `public struct OnboardingView(installer:localizer:onInstall:)`, `public enum SidebarItem` (`dashboard`, `history`, `settings`), `public struct RootView(model:installer:loginItem:localizer:)` avec `static func shouldShowOnboarding(connection:installState:) -> Bool`.

Règle de l'accueil : s'affiche seulement si l'agent est **injoignable** (jamais connecté pendant cette session) **et** non installé ou introuvable. Un agent installé mais muet, ou un agent de développement déjà connecté, ne déclenche pas l'accueil.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncMacProUITests/RootViewTests.swift` :

```swift
import SwiftUI
import XCTest
@testable import SyncMacProUI

@MainActor
final class RootViewTests: XCTestCase {
    func testOnboardingOnlyWhenUnreachableAndNotInstalled() {
        let show = RootView.shouldShowOnboarding
        XCTAssertTrue(show(.unreachable, .notRegistered))
        XCTAssertTrue(show(.unreachable, .notFound))
        XCTAssertFalse(show(.unreachable, .enabled), "installé mais muet : bandeau « ne répond pas », pas d'accueil")
        XCTAssertFalse(show(.unreachable, .requiresApproval))
        XCTAssertFalse(show(.connected, .notRegistered), "un agent déjà connecté (développement) n'a pas besoin d'accueil")
        XCTAssertFalse(show(.connecting, .notRegistered))
        XCTAssertFalse(show(.reconnecting(attempt: 2), .notRegistered))
    }

    func testSidebarHasThreeEntries() {
        XCTAssertEqual(SidebarItem.allCases, [.dashboard, .history, .settings])
    }

    func testOnboardingRendersForEveryInstallState() throws {
        for (index, state) in [AgentInstallState.notRegistered, .requiresApproval, .notFound].enumerated() {
            let installer = AgentInstaller(service: StubService(state))
            let view = OnboardingView(installer: installer, localizer: Localizer(language: "fr"), onInstall: {})
            let image = try render(view, name: "onboarding-\(index)", size: CGSize(width: 640, height: 420), scheme: .light)
            assertNotBlank(image)
        }
    }

    func testSettingsRenders() throws {
        let installer = AgentInstaller(service: StubService(.enabled))
        let view = SettingsView(installer: installer, loginItem: LoginItemModel(control: StubLogin()), localizer: Localizer(language: "fr"))
        // Un `Form` s'appuie sur AppKit : on vérifie seulement que le rendu ne plante pas.
        let image = try render(view, name: "settings", size: CGSize(width: 520, height: 520), scheme: .light)
        XCTAssertGreaterThan(image.width, 0)
    }
}

private struct StubService: ServiceControlling {
    let state: AgentInstallState
    init(_ state: AgentInstallState) { self.state = state }
    func status() -> AgentInstallState { state }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

private struct StubLogin: LoginItemControlling {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter RootViewTests 2>&1 | grep -E "error:" | head -3`
Attendu : erreur de compilation.

- [ ] **Étape 3 : implémenter**

`Sources/SyncMacProUI/Views/OnboardingView.swift` :

```swift
import SwiftUI

/// Premier lancement : propose d'installer l'agent d'arrière-plan.
public struct OnboardingView: View {
    let installer: AgentInstaller
    let localizer: Localizer
    let onInstall: () -> Void

    public init(installer: AgentInstaller, localizer: Localizer = .system, onInstall: @escaping () -> Void) {
        self.installer = installer
        self.localizer = localizer
        self.onInstall = onInstall
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(localizer.text("onboarding.title")).font(.largeTitle.bold())
            Text(localizer.text("onboarding.body"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            if installer.state == .requiresApproval {
                Text(localizer.text("onboarding.approve"))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button(localizer.text("agent.opensettings")) { installer.openSettings() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(localizer.text("onboarding.install"), action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            if let error = installer.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

`Sources/SyncMacProUI/Views/SettingsView.swift` :

```swift
import AppKit
import SwiftUI
import SyncKit

public struct SettingsView: View {
    let installer: AgentInstaller
    let loginItem: LoginItemModel
    let localizer: Localizer
    @AppStorage("appearance") private var appearanceRaw = Appearance.auto.rawValue

    public init(installer: AgentInstaller, loginItem: LoginItemModel, localizer: Localizer = .system) {
        self.installer = installer
        self.loginItem = loginItem
        self.localizer = localizer
    }

    public var body: some View {
        Form {
            Section(localizer.text("settings.appearance")) {
                Picker(localizer.text("settings.appearance"), selection: $appearanceRaw) {
                    Text(localizer.text("settings.appearance.auto")).tag(Appearance.auto.rawValue)
                    Text(localizer.text("settings.appearance.light")).tag(Appearance.light.rawValue)
                    Text(localizer.text("settings.appearance.dark")).tag(Appearance.dark.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section {
                Toggle(
                    localizer.text("settings.login"),
                    isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) })
                )
                if let error = loginItem.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            }
            Section(localizer.text("settings.agent")) {
                LabeledContent(localizer.text("settings.agent"), value: stateLabel(installer.state))
                HStack {
                    if installer.state == .enabled {
                        Button(localizer.text("agent.uninstall")) { installer.uninstall() }
                    } else {
                        Button(localizer.text("agent.install")) { installer.install() }
                    }
                    if installer.state == .requiresApproval {
                        Button(localizer.text("agent.opensettings")) { installer.openSettings() }
                    }
                }
                if let error = installer.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            }
            Section(localizer.text("settings.data")) {
                Button(localizer.text("settings.data.reveal")) { revealData() }
            }
            Section(localizer.text("settings.about")) {
                Text(localizer.format("settings.version", version))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(localizer.text("settings.title"))
        .onAppear {
            installer.refresh()
            loginItem.refresh()
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func stateLabel(_ state: AgentInstallState) -> String {
        switch state {
        case .enabled: return localizer.text("agent.state.enabled")
        case .notRegistered: return localizer.text("agent.state.notRegistered")
        case .requiresApproval: return localizer.text("agent.state.requiresApproval")
        case .notFound: return localizer.text("agent.state.notFound")
        case .unknown: return localizer.text("agent.state.unknown")
        }
    }

    private func revealData() {
        let folder = AgentPaths.standard.root
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
```

`Sources/SyncMacProUI/Views/RootView.swift` :

```swift
import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    case dashboard, history, settings
    public var id: String { rawValue }
}

/// Fenêtre principale : barre latérale (tableau de bord, historique, réglages) et accueil au premier lancement.
public struct RootView: View {
    let model: AgentModel
    let installer: AgentInstaller
    let loginItem: LoginItemModel
    let localizer: Localizer
    @State private var selection: SidebarItem? = .dashboard

    public init(model: AgentModel, installer: AgentInstaller, loginItem: LoginItemModel, localizer: Localizer = .system) {
        self.model = model
        self.installer = installer
        self.loginItem = loginItem
        self.localizer = localizer
    }

    /// L'accueil ne s'affiche que si l'agent est injoignable ET pas installé : un agent installé mais muet, ou un agent
    /// déjà connecté (développement), n'en a pas besoin.
    public static func shouldShowOnboarding(connection: ConnectionState, installState: AgentInstallState) -> Bool {
        connection == .unreachable && (installState == .notRegistered || installState == .notFound)
    }

    public var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(title(item), systemImage: icon(item)).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 560)
        .alert(
            localizer.text("alert.title"),
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            actions: { Button(localizer.text("alert.ok")) {} },
            message: { Text(model.alertMessage ?? "") }
        )
    }

    @ViewBuilder private var detail: some View {
        if Self.shouldShowOnboarding(connection: model.connection, installState: installer.state) {
            OnboardingView(installer: installer, localizer: localizer) {
                installer.install()
                model.restart()
            }
        } else {
            switch selection ?? .dashboard {
            case .dashboard: DashboardView(model: model, installer: installer, localizer: localizer)
            case .history: HistoryView(model: model, localizer: localizer)
            case .settings: SettingsView(installer: installer, loginItem: loginItem, localizer: localizer)
            }
        }
    }

    private func title(_ item: SidebarItem) -> String {
        switch item {
        case .dashboard: return localizer.text("sidebar.dashboard")
        case .history: return localizer.text("sidebar.history")
        case .settings: return localizer.text("sidebar.settings")
        }
    }

    private func icon(_ item: SidebarItem) -> String {
        switch item {
        case .dashboard: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter "RootViewTests|StringsCompletenessTests" 2>&1 | grep -E "error:|Executed .* tests|skipped" | sed -E 's|/Users/[^ ]*/||' | tail -5`
Attendu : tous passent. Si le test de complétude signale une clé absente, l'ajouter aux **deux** fichiers de chaînes (fr et en) avec le même nombre de `%@` / `%d`.

- [ ] **Étape 5 : inspecter les images**

Lire `$TMPDIR/syncmacpro-renders/onboarding-0-light.png` et `onboarding-1-light.png`.
Attendu : l'accueil montre l'icône, le titre, le texte et le bouton « Installer l'agent » ; l'état « à autoriser » montre la consigne et « Ouvrir Réglages Système ».

- [ ] **Étape 6 : suite complète puis commit**

Exécuter : `SYNCMACPRO_RSYNC=… swift test 2>&1 | tail -3` → vert.

```bash
git add Sources/SyncMacProUI/Views Tests/SyncMacProUITests
git commit -m "Interface : réglages, accueil au premier lancement, fenêtre principale" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 10 : l'app (point d'entrée, scènes) et le bundle de développement

**Fichiers :**
- Modifier : `Sources/SyncMacPro/SyncMacProApp.swift`, `scripts/make-dev-bundle.sh`

**Interfaces :**
- Consomme : tout `SyncMacProUI`, `AgentClient.machService()`.
- Produit : l'exécutable `SyncMacPro` (fenêtre unique `main`, `MenuBarExtra` en style panneau, scène `Settings`, délégué qui garde l'app ouverte sans fenêtre) ; `scripts/make-dev-bundle.sh` assemble `SyncMacPro.app` avec l'app comme programme principal, `syncmacpro-agent` et `syncmacpro-ctl` dans `Contents/MacOS/`, le bundle de ressources dans `Contents/Resources/`.

Cette tâche est du câblage : pas de test unitaire (tout ce qu'elle appelle est testé aux tâches 1 à 9) ; la vérification est un essai réel.

- [ ] **Étape 1 : écrire l'app**

`Sources/SyncMacPro/SyncMacProApp.swift` :

```swift
import AppKit
import SwiftUI
import SyncKit
import SyncMacProUI

/// Fermer la dernière fenêtre ne quitte pas l'app : elle reste dans la barre de menus. Quitter n'arrête pas l'agent.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct SyncMacProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AgentModel(agent: AgentClient.machService())
    @State private var installer = AgentInstaller()
    @State private var loginItem = LoginItemModel()
    @AppStorage("appearance") private var appearance = Appearance.auto.rawValue

    private let localizer = Localizer.system

    var body: some Scene {
        Window(localizer.text("app.name"), id: "main") {
            RootView(model: model, installer: installer, loginItem: loginItem, localizer: localizer)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .task { model.start() }
        }

        MenuBarExtra {
            MenuBarContent(model: model, localizer: localizer)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        } label: {
            MenuBarIcon(model: model, localizer: localizer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(installer: installer, loginItem: loginItem, localizer: localizer)
                .frame(width: 520, height: 520)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        }
    }
}

/// L'icône reflète l'état en direct, même fenêtre fermée.
private struct MenuBarIcon: View {
    let model: AgentModel
    let localizer: Localizer

    var body: some View {
        MenuBarLabel(
            state: MenuBarState.make(connection: model.connection, status: model.status, progress: model.progress),
            localizer: localizer
        )
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: AgentModel
    let localizer: Localizer

    var body: some View {
        MenuBarPanel(
            model: model, text: CardText(localizer: localizer),
            onOpen: {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            },
            onQuit: { NSApp.terminate(nil) }
        )
    }
}
```

- [ ] **Étape 2 : adapter le script du bundle**

Dans `scripts/make-dev-bundle.sh` :
1. Remplacer la ligne `cp "$BIN/syncmacpro-ctl" "$BIN/syncmacpro-agent" "$APP/Contents/MacOS/"` par :

```bash
cp "$BIN/SyncMacPro" "$BIN/syncmacpro-ctl" "$BIN/syncmacpro-agent" "$APP/Contents/MacOS/"
# Ressources de l'interface (chaînes fr / en) : SwiftPM les place dans des « .bundle » à côté des exécutables.
mkdir -p "$APP/Contents/Resources"
for resources in "$BIN"/*.bundle; do
  [ -e "$resources" ] && cp -R "$resources" "$APP/Contents/Resources/"
done
```

2. Dans l'`Info.plist` généré : remplacer `<key>CFBundleExecutable</key><string>syncmacpro-ctl</string>` par `<key>CFBundleExecutable</key><string>SyncMacPro</string>`, supprimer la ligne `LSUIElement` (l'app a une icône dans le Dock), changer la version en `0.3.0`, et ajouter :

```
  <key>CFBundleDisplayName</key><string>SyncMacPro</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string><string>en</string></array>
```

3. Avant les `codesign`, ajouter `codesign --force --sign - "$APP/Contents/MacOS/SyncMacPro"`. Remplacer le message final par :

```bash
echo "Bundle prêt : $APP"
echo "Ouvrir l'app : open \"$APP\""
echo "Installer l'agent : \"$APP/Contents/MacOS/syncmacpro-ctl\" agent install   (ou Réglages › Agent dans l'app)"
```

- [ ] **Étape 3 : compiler et assembler**

Exécuter : `swift build 2>&1 | grep -E "error|warning: var|Build" | tail -3` puis `scripts/make-dev-bundle.sh 2>&1 | tail -3` puis `ls ~/Applications/SyncMacPro.app/Contents/MacOS ~/Applications/SyncMacPro.app/Contents/Resources`
Attendu : compilation sans erreur ; le bundle contient `SyncMacPro`, `syncmacpro-agent`, `syncmacpro-ctl` et `SyncMacPro_SyncMacProUI.bundle` dans `Resources`.

- [ ] **Étape 4 : essai réel (agent absent, puis agent installé, puis agent tué)**

Cet essai ouvre brièvement une fenêtre et une icône de barre de menus sur ce Mac. Il installe l'agent par `SMAppService` et le retire à la fin.

```bash
APP="$HOME/Applications/SyncMacPro.app"; CTL="$APP/Contents/MacOS/syncmacpro-ctl"
open "$APP"; sleep 6
echo "--- l'app tourne :"; pgrep -x SyncMacPro | head -1
echo "--- connexion (agent absent) :"; /usr/bin/log show --last 2m --predicate 'subsystem == "com.sylvain.syncmacpro"' --style compact 2>&1 | tail -3
"$CTL" agent install; sleep 4
echo "--- connexion (agent installé) :"; /usr/bin/log show --last 2m --predicate 'subsystem == "com.sylvain.syncmacpro"' --style compact 2>&1 | tail -3
```
Attendu : un processus `SyncMacPro` ; au premier journal : « connexion : unreachable » ; après l'installation de l'agent : « connexion : connected » (le bouton Réessayer ou la boucle de reconnexion rétablit la connexion ; la boucle réessaie après 1, 2, 4 s : attendre jusqu'à 15 s si besoin).

```bash
echo "--- on tue l'agent (KeepAlive le relance) :"; kill -KILL "$(launchctl print gui/$(id -u)/com.sylvain.syncmacpro.agent | awk '/^\tpid = /{print $3}')"; sleep 16
/usr/bin/log show --last 2m --predicate 'subsystem == "com.sylvain.syncmacpro"' --style compact 2>&1 | tail -4
echo "--- on quitte l'app, l'agent doit survivre :"; osascript -e 'quit app "SyncMacPro"'; sleep 2
pgrep -x SyncMacPro | wc -l; pgrep -f "SyncMacPro.app/Contents/MacOS/syncmacpro-agent" | wc -l
```
Attendu : le journal montre « reconnecting » puis « connected » sans aucune action ; après avoir quitté l'app : 0 processus `SyncMacPro` et 1 processus agent.

Nettoyage : `"$CTL" agent uninstall; pkill -f "SyncMacPro.app/Contents/MacOS/syncmacpro-agent"; rm -rf "$APP" "$HOME/Library/Application Support/SyncMacPro"; defaults delete com.sylvain.syncmacpro 2>/dev/null; true`

- [ ] **Étape 5 : vérifier la fenêtre elle-même (facultatif)**

Si l'on veut une capture de la **seule fenêtre** de l'app (jamais de l'écran entier) : relancer l'app (étapes ci-dessus sans nettoyage), puis `swift -e 'import CoreGraphics; for w in (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]) where (w["kCGWindowOwnerName"] as? String) == "SyncMacPro" { print(w["kCGWindowNumber"]!) }'` puis `screencapture -x -o -l <numéro> /tmp/syncmacpro-fenetre.png` et lire le PNG ; supprimer le fichier ensuite. Si `screencapture` échoue faute d'autorisation d'enregistrement d'écran, ne pas insister : le rendu `ImageRenderer` des tâches 6 à 9 et l'essai ci-dessus font foi.

- [ ] **Étape 6 : commit**

```bash
git add Sources/SyncMacPro scripts/make-dev-bundle.sh
git commit -m "App : point d'entrée, fenêtre, barre de menus, réglages ; bundle de développement avec l'app comme programme principal" -m "Essai réel : connexion, reconnexion après arrêt brutal de l'agent, agent actif après avoir quitté l'app." -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 11 : documentation et liste de vérifications manuelles

**Fichiers :**
- Modifier : `README.md`
- Créer : `docs/manual-checks-ui.md`

**Interfaces :** aucune.

- [ ] **Étape 1 : écrire la liste de vérifications manuelles**

`docs/manual-checks-ui.md` :

```markdown
# Vérifications manuelles de l'interface (sous-projet 3a)

À faire avant de publier une version. Les tests automatiques couvrent la logique et le rendu des vues ;
ces vérifications couvrent ce qu'ils ne voient pas (fenêtre réelle, barre de menus, launchd, autorisations macOS).

Préparation : `scripts/make-dev-bundle.sh`, puis `open ~/Applications/SyncMacPro.app`.
Nettoyage à la fin : `syncmacpro-ctl agent uninstall`, supprimer `~/Applications/SyncMacPro.app` et
`~/Library/Application Support/SyncMacPro`.

## Premier lancement
- [ ] Sans agent installé : l'écran d'accueil s'affiche avec « Installer l'agent ».
- [ ] Cliquer sur Installer : si macOS demande une autorisation, l'écran explique où la donner et ouvre Réglages Système ; après autorisation, le tableau de bord apparaît seul.
- [ ] Sans aucune tâche : le message « Aucune tâche » indique la commande `syncmacpro-ctl add`.

## Tableau de bord
- [ ] Ajouter une tâche (`syncmacpro-ctl add --name Test --source ~/Desktop/a --dest ~/Desktop/b --every 1`) : la carte apparaît sans recharger.
- [ ] Pendant une copie volumineuse : barre de progression, fichier en cours, débit, temps restant, qui avancent en direct.
- [ ] Pause / Reprendre / Arrêter sur la carte ; Lancer sur une tâche au repos.
- [ ] Pause globale : les copies se figent, l'en-tête indique « En pause globale » ; quitter l'app, relancer : la pause est toujours là.
- [ ] Fermer la fenêtre : l'app reste dans la barre de menus ; cliquer sur l'icône du Dock rouvre la fenêtre.
- [ ] Mode miroir avec trop de suppressions : la carte indique le blocage et propose « Valider les suppressions ».

## Barre de menus
- [ ] L'icône change : repos, pourcentage pendant une copie, pause, erreur, déconnecté.
- [ ] Le panneau liste les copies actives, les prochaines exécutions, la pause globale, Ouvrir, Quitter.
- [ ] Quitter ne coupe pas l'agent (`pgrep -f syncmacpro-agent`).

## Connexion
- [ ] Tuer l'agent (`pkill -KILL -f syncmacpro-agent`) : l'interface affiche « Reconnexion… », puis se rétablit seule en une quinzaine de secondes.
- [ ] Désinstaller l'agent pendant que l'app est ouverte : bandeau « L'agent ne répond pas » avec Installer et Réessayer.

## Historique
- [ ] Les exécutions terminées apparaissent ; les filtres (tâche, état, période, recherche) fonctionnent ; les flèches haut / bas déplacent la sélection ; le détail montre le message d'un échec.

## Réglages
- [ ] Apparence : Automatique, Clair, Sombre s'appliquent tout de suite à la fenêtre et au panneau.
- [ ] « Ouvrir à la connexion » s'active et se désactive (vérifier dans Réglages Système › Éléments de connexion).
- [ ] Installer / désinstaller l'agent ; « Afficher le dossier des données » ouvre le Finder.

## Langues
- [ ] Système en français puis en anglais : aucun texte brut du type « ⚠︎clé » nulle part.

## Accessibilité
- [ ] VoiceOver annonce le nom, l'état et le pourcentage d'une carte ; ⌘, ouvre les Réglages.
```

- [ ] **Étape 2 : mettre à jour le README**

Dans `README.md` : passer le sous-projet 3 de « à venir » à « 3a livré : tableau de bord, barre de menus, historique, réglages ; 3b (tâches) et 3c (copie à deux panneaux) à venir » ; ajouter une section « Interface » après « Agent d'arrière-plan » :

```markdown
## Interface (sous-projet 3a)

L'app `SyncMacPro` affiche l'état de l'agent en direct : **tableau de bord** (une carte par tâche, progression, pause globale),
**icône de barre de menus** (repos, pourcentage, pause, erreur), **historique** (filtres, détail) et **réglages**
(apparence, ouverture à la connexion, agent). Elle n'effectue aucune synchronisation : fermer la fenêtre garde l'app dans la
barre de menus, la quitter laisse l'agent tourner. Si l'agent redémarre, l'app se reconnecte seule.

```bash
scripts/make-dev-bundle.sh          # assemble ~/Applications/SyncMacPro.app (signature ad hoc)
open ~/Applications/SyncMacPro.app
```

L'installation de l'agent se fait au premier lancement (ou dans Réglages › Agent). La création de tâches depuis l'app arrive
en 3b ; d'ici là : `syncmacpro-ctl add`. Textes en français et en anglais (`Sources/SyncMacProUI/Resources/*.lproj`).
Vérifications à la main : [`docs/manual-checks-ui.md`](docs/manual-checks-ui.md). Les tests de rendu (`ImageRenderer`) écrivent
des PNG dans `$TMPDIR/syncmacpro-renders/`.
```

- [ ] **Étape 3 : suite complète puis commit**

Exécuter : `SYNCMACPRO_RSYNC=… swift test 2>&1 | tail -3` → vert.

```bash
git add README.md docs/manual-checks-ui.md
git commit -m "Documentation de l'interface et liste de vérifications manuelles" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Auto-revue du plan

- **Couverture du spec :**
  - Coque et connexion : tâches 2, 4, 10.
  - Installation de l'agent : tâches 5, 9.
  - Tableau de bord (cartes, bandeaux, pause globale, états vides) : tâches 3, 6.
  - Barre de menus : tâches 3, 7, 10.
  - Historique : tâches 3, 8.
  - Réglages et accueil : tâches 5, 9.
  - Langues fr / en et test de complétude : tâche 2 ; clés complétées et revérifiées aux tâches 6 à 9.
  - Accessibilité : libellés VoiceOver (tâche 6), clavier de l'historique (tâche 8), ⌘, par la scène `Settings` (tâche 10), vérifications manuelles (tâche 11).
  - Ajouts côté agent : tâche 1.
  - Rendu `ImageRenderer` : tâches 6 à 9.
  - Liste manuelle : tâche 11.
- **Écarts assumés** (section « Décisions ») : `.strings` au lieu de `.xcstrings` ; `listTasks` lu avec l'état ; priorité de l'icône ; tableau d'historique dessiné à la main (pas `Table`).
- **Cohérence des types :** `ConnectionState` (tâche 3) est consommé par `MenuBarState` (3), `AgentModel` (4), `ConnectionBanner` (6) et `RootView` (9) ; `AgentConnecting.startWatching` (4) correspond à `AgentClient.watch(_:onEnd:)` (1) ; `AgentTaskInfo.progress` (1) alimente `AgentModel.apply` (4) ; `AgentInstallState` (5) est utilisé par `ConnectionBanner` (6), `OnboardingView` et `RootView` (9).
- **Risques restants :** rendu des matériaux et des grilles paresseuses par `ImageRenderer` (à constater aux étapes d'inspection) ; icône dynamique du `MenuBarExtra` (essai réel, tâche 10) ; CI Swift 5.10 (jamais de variable capturée).
