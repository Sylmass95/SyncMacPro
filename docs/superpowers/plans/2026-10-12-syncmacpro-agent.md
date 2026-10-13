# SyncMacPro — agent d'arrière-plan : plan d'implémentation

> **Pour les agents :** SOUS-COMPÉTENCE REQUISE : utiliser superpowers:subagent-driven-development (recommandé) ou superpowers:executing-plans pour exécuter ce plan tâche par tâche. Les étapes utilisent la syntaxe à cases (`- [ ]`).

**Objectif :** un agent launchd qui planifie et exécute les tâches app fermée (rattrapage, conditions, pause globale persistante, notifications, historique), piloté par XPC et par l'outil `syncmacpro-ctl`.

**Architecture :** toute la logique vit dans `SyncKit` (planificateur pur à horloge injectée, acteur `AgentCore`, contrat XPC `Codable` versionné, intégrations système). Deux exécutables fins : `syncmacpro-agent` (câblage, minuteur, serveur XPC) et `syncmacpro-ctl` (client). L'agent est le seul à écrire l'état et l'historique.

**Stack :** Swift 5.9 (mode Swift 5), SwiftPM, macOS 14, XCTest, `NSXPCConnection`, `SMAppService`, IOKit, Network, UserNotifications.

**Spec :** `docs/superpowers/specs/2026-10-12-syncmacpro-agent-design.md`

## Contraintes globales

- macOS 14 minimum, Swift 5.9 (mode de langage 5), aucune dépendance externe.
- L'agent est le **seul** à écrire `scheduler-state.json`, `history.sqlite` et (via l'app) `tasks.json` ; le CLI et l'app lisent et commandent via XPC.
- Maximum **2** exécutions en parallèle ; une tâche ne tourne **qu'une fois à la fois**.
- Rattrapage : **une seule** exécution après veille / redémarrage, **60 s** après le réveil.
- Nouvelle tentative après **3600 s**, **3** essais au maximum.
- Rétention de l'historique : **90 jours**, purge au plus une fois par jour.
- Protocole XPC : `agentProtocolVersion = 1` dans chaque échange ; client patient jusqu'à **20 s**.
- Identifiant du service Mach et libellé launchd : `com.sylvain.syncmacpro.agent`. Données : `~/Library/Application Support/SyncMacPro/` (développement : `SyncMacPro-dev`).
- Textes affichés à l'utilisateur en français ; identifiants de code en anglais ; commentaires en français comme dans le reste du dépôt.
- Chaque commit se termine par la ligne `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Les tests existants (149) restent verts. Commande de référence (rsync 3.x embarqué par Rsync GUI) :
  `SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync" swift test`

## Décisions prises en rédigeant le plan (écarts avec le spec)

- **Ruling : `--foreground` n'a pas de XPC.** Vérifié sur la machine : un processus lancé hors launchd ne peut pas ouvrir de service Mach (`Connection init failed at lookup`). `--foreground` lance donc l'agent dans le terminal avec ses journaux, sans XPC. Pour le développement, `scripts/dev-launchd.sh` déclare le service avec `launchctl bootstrap` (vérifié : fonctionne sans bundle). Les tests XPC utilisent un `NSXPCListener.anonymous()` en mémoire. Coût si faux : un test de bout en bout manuel (tâche 12) à refaire.
- **Ruling : conditions par tâche.** `SyncTask` n'avait pas de champ « conditions » : on ajoute `TaskConditions` avec un décodage compatible avec les `tasks.json` existants.
- **Ruling : validation d'une suppression** = relancer la tâche avec `deleteThresholdPercent = 100` pour cette seule exécution ; `TaskRunner` n'est pas modifié.
- **Ruling : politique de nouvelle tentative globale** (3600 s, 3 essais), non configurable par tâche (YAGNI).
- **Ruling : `agent install` passe par `SMAppService`**, qui doit être appelé depuis l'exécutable du bundle : `syncmacpro-ctl` est l'exécutable principal du bundle de développement, à lancer par son chemin complet.
- **Ruling : la reprise de la pause globale n'attend pas 60 s** (le réseau est déjà connu) ; le rattrapage s'applique immédiatement, une seule fois par tâche.
- **Ruling : `Clock` du spec s'appelle `SchedulerClock`** pour ne pas masquer `Clock` de la bibliothèque standard.

## Points de revue (cas que les tests nominaux ne couvrent pas)

1. Changement d'heure (été / hiver) : une tâche quotidienne à 02:30 ne saute pas et ne double pas. → tâche 2.
2. Fichier d'état corrompu : l'agent repart **en pause**, rien ne se lance par surprise. → tâche 3.
3. `tasks.json` illisible pendant que l'agent tourne : on garde les tâches précédentes et on le signale. → tâche 6.
4. Agent tué brutalement pendant une copie : au démarrage l'exécution est « interrompue » **et rattrapée**. → tâche 6.
5. Anciens `tasks.json` sans champ `conditions` : ils se chargent. → tâche 1.
6. Horloge qui recule ou longue veille : un seul rattrapage, après le délai de 60 s. → tâche 5.

## Structure des fichiers

| Fichier | Rôle |
|---|---|
| `Sources/SyncKit/TaskConditions.swift` | Conditions d'une tâche (secteur, réseau, plage horaire) |
| `Sources/SyncKit/Agent/Scheduler.swift` | `SchedulerClock`, `SystemClock`, calcul pur des échéances |
| `Sources/SyncKit/Agent/SchedulerState.swift` | État persistant et son stockage atomique |
| `Sources/SyncKit/Agent/AgentTypes.swift` | Configuration, protocoles injectés, DTO d'état, erreurs, événements |
| `Sources/SyncKit/Agent/TaskRunning.swift` | Interface de `TaskRunner` (faux en test) |
| `Sources/SyncKit/Agent/AgentCore.swift` | Acteur : boucle d'évaluation, file, exécutions, état |
| `Sources/SyncKit/Agent/AgentCore+Control.swift` | Commandes : lancer, pause, reprise, arrêt, pause globale, validation, arrêt de l'agent |
| `Sources/SyncKit/Agent/AgentProtocol.swift` | Contrat XPC versionné (requêtes, réponses, observateur) |
| `Sources/SyncKit/Agent/AgentXPC.swift` | Serveur (écouteur) et client XPC |
| `Sources/SyncKit/Agent/System/*.swift` | Conditions réelles, notifications, anti-veille, signature |
| `Sources/SyncKit/Agent/AgentPaths.swift` | Chemins et identifiants |
| `Sources/SyncKit/Agent/Ctl*.swift` | Analyse des commandes, résolution des tâches, affichage |
| `Sources/syncmacpro-agent/main.swift` | Programme de l'agent |
| `Sources/syncmacpro-ctl/*.swift` | Outil en ligne de commande |
| `scripts/make-dev-bundle.sh`, `scripts/dev-launchd.sh` | Bundle de développement, enregistrement launchd direct |
| `Tests/SyncKitTests/Agent*.swift`, `Scheduler*.swift` | Tests |

---

### Tâche 1 : conditions d'une tâche

**Fichiers :**
- Créer : `Sources/SyncKit/TaskConditions.swift`
- Modifier : `Sources/SyncKit/SyncTask.swift`
- Tester : `Tests/SyncKitTests/ModelsTests.swift`

**Interfaces :**
- Consomme : `SyncTask` existant.
- Produit : `HourRange(start:end:)` avec `contains(hour:)` ; `TaskConditions(requiresACPower:requiresNetwork:allowedHours:)` ; `SyncTask.conditions: TaskConditions` (paramètre `conditions:` de l'init, après `notifications:`).

- [ ] **Étape 1 : écrire les tests qui échouent**

Ajouter à la fin de `Tests/SyncKitTests/ModelsTests.swift` (dans la classe de tests existante, ou une nouvelle classe dans le même fichier) :

```swift
final class TaskConditionsTests: XCTestCase {
    func testHourRangeWithinTheDay() {
        let range = HourRange(start: 9, end: 17)
        XCTAssertTrue(range.contains(hour: 9))
        XCTAssertTrue(range.contains(hour: 16))
        XCTAssertFalse(range.contains(hour: 17))
        XCTAssertFalse(range.contains(hour: 3))
    }

    func testHourRangeAcrossMidnight() {
        let range = HourRange(start: 22, end: 6)
        XCTAssertTrue(range.contains(hour: 23))
        XCTAssertTrue(range.contains(hour: 2))
        XCTAssertFalse(range.contains(hour: 6))
        XCTAssertFalse(range.contains(hour: 12))
    }

    func testEqualBoundsMeanWholeDay() {
        XCTAssertTrue(HourRange(start: 5, end: 5).contains(hour: 14))
    }

    func testTaskWithoutConditionsKeyStillDecodes() throws {
        let task = SyncTask(name: "ancienne", source: .local(path: "/a"), destination: .local(path: "/b"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json.removeValue(forKey: "conditions")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SyncTask.self, from: legacy)
        XCTAssertEqual(decoded.name, "ancienne")
        XCTAssertEqual(decoded.conditions, TaskConditions())
    }

    func testConditionsSurviveEncoding() throws {
        var task = SyncTask(name: "nuit", source: .local(path: "/a"), destination: .local(path: "/b"))
        task.conditions = TaskConditions(requiresACPower: true, requiresNetwork: true, allowedHours: HourRange(start: 22, end: 6))
        let decoded = try JSONDecoder().decode(SyncTask.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded, task)
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter TaskConditionsTests 2>&1 | tail -15`
Attendu : erreur de compilation (`HourRange` / `TaskConditions` inconnus).

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/TaskConditions.swift` :

```swift
import Foundation

/// Plage d'heures locales [start, end[. Si `start > end`, la plage passe minuit ; si `start == end`, c'est toute la journée.
public struct HourRange: Codable, Equatable, Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public func contains(hour: Int) -> Bool {
        if start == end { return true }
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }
}

/// Ce qui doit être vrai pour qu'une tâche planifiée démarre. Sinon elle attend (ce n'est pas un échec).
public struct TaskConditions: Codable, Equatable, Hashable, Sendable {
    public var requiresACPower: Bool
    public var requiresNetwork: Bool
    public var allowedHours: HourRange?

    public init(requiresACPower: Bool = false, requiresNetwork: Bool = false, allowedHours: HourRange? = nil) {
        self.requiresACPower = requiresACPower
        self.requiresNetwork = requiresNetwork
        self.allowedHours = allowedHours
    }
}
```

Dans `Sources/SyncKit/SyncTask.swift`, struct `SyncTask` : ajouter la propriété `public var conditions: TaskConditions` après `notifications`, le paramètre `conditions: TaskConditions = TaskConditions(),` dans `init` (entre `notifications` et `isEnabled`) avec `self.conditions = conditions`, puis ce décodeur (les `tasks.json` existants n'ont pas la clé) :

```swift
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(Endpoint.self, forKey: .source)
        destination = try container.decode(Endpoint.self, forKey: .destination)
        sourceItems = try container.decode([String].self, forKey: .sourceItems)
        mode = try container.decode(SyncMode.self, forKey: .mode)
        options = try container.decode(TaskOptions.self, forKey: .options)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        notifications = try container.decode(NotificationPolicy.self, forKey: .notifications)
        conditions = try container.decodeIfPresent(TaskConditions.self, forKey: .conditions) ?? TaskConditions()
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test 2>&1 | tail -8`
Attendu : tous les tests passent (149 + 5 nouveaux).

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncKit/TaskConditions.swift Sources/SyncKit/SyncTask.swift Tests/SyncKitTests/ModelsTests.swift
git commit -m "Conditions d'une tâche (secteur, réseau, plage horaire), anciens fichiers compatibles" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 2 : horloge et calcul des échéances

**Fichiers :**
- Créer : `Sources/SyncKit/Agent/Scheduler.swift`
- Tester : `Tests/SyncKitTests/SchedulerTests.swift`

**Interfaces :**
- Consomme : `Schedule`.
- Produit : `protocol SchedulerClock: Sendable { func now() -> Date; var calendar: Calendar { get } }` ; `struct SystemClock: SchedulerClock` ; `Scheduler.nextDue(for: Schedule, after: Date?, now: Date, calendar: Calendar) -> Date?`.

Règles : `manual` et `whenAvailable` → `nil` ; `everyMinutes(n)` → `basis + n min`, ou `now` si `basis == nil` (première exécution immédiate) ; `daily` / `weekdays` → prochaine occurrence **strictement après** `basis ?? now`, heure locale, `repeatedTimePolicy: .first` (le changement d'heure ne double ni ne saute).

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncKitTests/SchedulerTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class SchedulerTests: XCTestCase {
    let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        paris.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func due(_ schedule: Schedule, after basis: Date?, now: Date? = nil) -> Date? {
        Scheduler.nextDue(for: schedule, after: basis, now: now ?? basis ?? Date(), calendar: paris)
    }

    func testManualAndWhenAvailableHaveNoCalendarDueDate() {
        XCTAssertNil(due(.manual, after: at(2026, 10, 12, 9)))
        XCTAssertNil(due(.whenAvailable, after: at(2026, 10, 12, 9)))
    }

    func testEveryMinutesRunsImmediatelyTheFirstTime() {
        let now = at(2026, 10, 12, 9)
        XCTAssertEqual(due(.everyMinutes(30), after: nil, now: now), now)
    }

    func testEveryMinutesAddsTheIntervalToTheLastStart() {
        let last = at(2026, 10, 12, 9)
        XCTAssertEqual(due(.everyMinutes(30), after: last), at(2026, 10, 12, 9, 30))
    }

    func testDailyTakesTodayIfTheTimeIsStillAhead() {
        XCTAssertEqual(due(.daily(hour: 3, minute: 0), after: at(2026, 10, 12, 1)), at(2026, 10, 12, 3))
    }

    func testDailyTakesTomorrowIfTheTimeHasPassed() {
        XCTAssertEqual(due(.daily(hour: 3, minute: 0), after: at(2026, 10, 12, 9)), at(2026, 10, 13, 3))
    }

    func testDailyIsStrictlyAfterTheBasis() {
        XCTAssertEqual(due(.daily(hour: 3, minute: 0), after: at(2026, 10, 12, 3)), at(2026, 10, 13, 3))
    }

    func testWeekdaysPicksTheEarliestSelectedDay() {
        // 2026-10-12 est un lundi ; Calendar : dimanche = 1, lundi = 2, vendredi = 6.
        let schedule = Schedule.weekdays(days: [2, 6], hour: 8, minute: 0)
        XCTAssertEqual(due(schedule, after: at(2026, 10, 12, 7)), at(2026, 10, 12, 8))
        XCTAssertEqual(due(schedule, after: at(2026, 10, 12, 9)), at(2026, 10, 16, 8))
    }

    func testWeekdaysWithNoDayNeverRuns() {
        XCTAssertNil(due(.weekdays(days: [], hour: 8, minute: 0), after: at(2026, 10, 12, 7)))
    }

    func testSpringForwardDoesNotSkipTheDailyRun() {
        // 2026-03-29 : à 02:00 il est 03:00 ; 02:30 n'existe pas ce jour-là.
        let schedule = Schedule.daily(hour: 2, minute: 30)
        let first = try! XCTUnwrap(due(schedule, after: at(2026, 3, 28, 3)))
        XCTAssertEqual(paris.component(.day, from: first), 29)
        let second = try! XCTUnwrap(due(schedule, after: first))
        XCTAssertEqual(second, at(2026, 3, 30, 2, 30))
    }

    func testFallBackDoesNotRunTheDailyTaskTwice() {
        // 2026-10-25 : 02:30 existe deux fois ; une seule exécution.
        let schedule = Schedule.daily(hour: 2, minute: 30)
        let first = try! XCTUnwrap(due(schedule, after: at(2026, 10, 24, 12)))
        XCTAssertEqual(paris.component(.day, from: first), 25)
        let second = try! XCTUnwrap(due(schedule, after: first))
        XCTAssertEqual(paris.component(.day, from: second), 26)
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter SchedulerTests 2>&1 | tail -8`
Attendu : erreur de compilation (`Scheduler` inconnu).

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/Agent/Scheduler.swift` :

```swift
import Foundation

/// Source du temps de l'agent ; remplacée par une horloge fausse dans les tests.
public protocol SchedulerClock: Sendable {
    func now() -> Date
    var calendar: Calendar { get }
}

public struct SystemClock: SchedulerClock {
    public init() {}
    public func now() -> Date { Date() }
    public var calendar: Calendar { .current }
}

/// Calcul pur des échéances : aucune horloge, aucun état.
public enum Scheduler {
    /// Prochaine échéance après `basis`. `nil` : jamais (manuelle, « dès que disponible », ou aucun jour choisi).
    /// Sans `basis`, `everyMinutes` est dû tout de suite ; les horaires fixes partent de `now`.
    public static func nextDue(for schedule: Schedule, after basis: Date?, now: Date, calendar: Calendar) -> Date? {
        switch schedule {
        case .manual, .whenAvailable:
            return nil
        case .everyMinutes(let minutes):
            guard let basis else { return now }
            return basis.addingTimeInterval(Double(max(1, minutes)) * 60)
        case .daily(let hour, let minute):
            return occurrence(after: basis ?? now, hour: hour, minute: minute, weekday: nil, calendar: calendar)
        case .weekdays(let days, let hour, let minute):
            let start = basis ?? now
            return days.compactMap {
                occurrence(after: start, hour: hour, minute: minute, weekday: $0, calendar: calendar)
            }.min()
        }
    }

    /// `repeatedTimePolicy: .first` : à l'heure d'hiver, 02:30 existe deux fois, on ne prend que la première.
    /// `matchingPolicy: .nextTime` : à l'heure d'été, une heure inexistante glisse vers l'heure suivante.
    private static func occurrence(after date: Date, hour: Int, minute: Int, weekday: Int?, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.weekday = weekday
        return calendar.nextDate(
            after: date, matching: components, matchingPolicy: .nextTime,
            repeatedTimePolicy: .first, direction: .forward
        )
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter SchedulerTests 2>&1 | tail -8`
Attendu : 10 tests passent.

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncKit/Agent/Scheduler.swift Tests/SyncKitTests/SchedulerTests.swift
git commit -m "Calcul pur des échéances (horloge injectée, changements d'heure)" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 3 : état persistant du planificateur

**Fichiers :**
- Créer : `Sources/SyncKit/Agent/SchedulerState.swift`
- Tester : `Tests/SyncKitTests/SchedulerStateTests.swift`

**Interfaces :**
- Produit :
  - `struct TaskScheduleState: Codable, Equatable, Sendable` : `firstSeen: Date`, `lastStart: Date?`, `lastSuccess: Date?`, `attempts: Int`, `retryAt: Date?`, `runningSince: Date?`, `wasAvailable: Bool?`, `awaitingApproval: Bool` ; `init(firstSeen:)`.
  - `struct SchedulerState: Codable, Equatable, Sendable` : `paused: Bool`, `lastPurge: Date?`, `tasks: [String: TaskScheduleState]` (clé = `UUID.uuidString`).
  - `struct SchedulerStateStore: Sendable` : `init(url:)`, `load() -> (state: SchedulerState, recovered: Bool)`, `save(_:) throws`.

Règle : fichier absent → état vierge (non en pause) ; fichier illisible → déplacé en `<nom>.corrupt`, état vierge **en pause**, enregistré tout de suite pour que la pause survive à un redémarrage.

- [ ] **Étape 1 : écrire les tests qui échouent**

```swift
import XCTest
@testable import SyncKit

final class SchedulerStateTests: XCTestCase {
    var directory: URL!
    var url: URL { directory.appendingPathComponent("scheduler-state.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testMissingFileGivesAFreshStateThatIsNotPaused() {
        let loaded = SchedulerStateStore(url: url).load()
        XCTAssertFalse(loaded.state.paused)
        XCTAssertFalse(loaded.recovered)
        XCTAssertTrue(loaded.state.tasks.isEmpty)
    }

    func testStateRoundTrips() throws {
        var state = SchedulerState()
        state.paused = true
        var entry = TaskScheduleState(firstSeen: Date(timeIntervalSince1970: 1_000_000))
        entry.attempts = 2
        entry.retryAt = Date(timeIntervalSince1970: 2_000_000)
        entry.awaitingApproval = true
        state.tasks["A"] = entry
        let store = SchedulerStateStore(url: url)
        try store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded.state, state)
        XCTAssertFalse(loaded.recovered)
    }

    func testCorruptFileIsSetAsideAndTheAgentStartsPaused() throws {
        try "{ pas du json".write(to: url, atomically: true, encoding: .utf8)
        let store = SchedulerStateStore(url: url)
        let loaded = store.load()
        XCTAssertTrue(loaded.state.paused)
        XCTAssertTrue(loaded.recovered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
        // La pause est déjà enregistrée : un redémarrage ne relance rien.
        let again = store.load()
        XCTAssertTrue(again.state.paused)
        XCTAssertFalse(again.recovered)
    }

    func testSaveCreatesTheFolder() throws {
        let nested = directory.appendingPathComponent("a/b/state.json")
        try SchedulerStateStore(url: nested).save(SchedulerState())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter SchedulerStateTests 2>&1 | tail -8`
Attendu : erreur de compilation.

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/Agent/SchedulerState.swift` :

```swift
import Foundation

/// Ce que l'agent retient d'une tâche entre deux exécutions.
public struct TaskScheduleState: Codable, Equatable, Sendable {
    /// Première fois où l'agent a vu la tâche : point de départ des horaires fixes d'une tâche jamais lancée.
    public var firstSeen: Date
    public var lastStart: Date?
    public var lastSuccess: Date?
    /// Échecs consécutifs depuis la dernière réussite.
    public var attempts: Int = 0
    /// Prochain essai (nouvelle tentative, rattrapage après interruption, disponibilité retrouvée).
    public var retryAt: Date?
    /// Renseigné pendant une exécution : s'il reste au démarrage, l'agent a été tué en route.
    public var runningSince: Date?
    public var wasAvailable: Bool?
    /// Bloquée par le garde-fou de suppression, en attente d'une validation de l'utilisateur.
    public var awaitingApproval: Bool = false

    public init(firstSeen: Date) { self.firstSeen = firstSeen }
}

public struct SchedulerState: Codable, Equatable, Sendable {
    public var paused: Bool = false
    public var lastPurge: Date?
    /// Clé : identifiant de la tâche (`UUID.uuidString`).
    public var tasks: [String: TaskScheduleState] = [:]

    public init() {}
}

public struct SchedulerStateStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Un fichier absent donne un état vierge. Un fichier illisible est mis de côté (`.corrupt`) et l'agent repart
    /// **en pause** : mieux vaut ne rien lancer que relancer d'anciennes copies par surprise.
    public func load() -> (state: SchedulerState, recovered: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (SchedulerState(), false) }
        do {
            return (try Self.decoder.decode(SchedulerState.self, from: Data(contentsOf: url)), false)
        } catch {
            let aside = URL(fileURLWithPath: url.path + ".corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            var state = SchedulerState()
            state.paused = true
            try? save(state)
            return (state, true)
        }
    }

    public func save(_ state: SchedulerState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(state).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter SchedulerStateTests 2>&1 | tail -8`
Attendu : 4 tests passent.

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncKit/Agent/SchedulerState.swift Tests/SyncKitTests/SchedulerStateTests.swift
git commit -m "État persistant du planificateur, écriture atomique, démarrage en pause si corrompu" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 4 : types de l'agent, interface d'exécution et doubles de test

**Fichiers :**
- Créer : `Sources/SyncKit/Agent/AgentTypes.swift`, `Sources/SyncKit/Agent/TaskRunning.swift`
- Créer : `Tests/SyncKitTests/AgentTestSupport.swift`
- Tester : `Tests/SyncKitTests/AgentTestSupportTests.swift`

**Interfaces :**
- Produit (module `SyncKit`, tout `public`) :
  - `AgentConfiguration` : `maxParallel = 2`, `retryDelay: TimeInterval = 3600`, `maxAttempts = 3`, `wakeGap: TimeInterval = 150`, `wakeHold: TimeInterval = 60`, `startupHold: TimeInterval = 60`, `historyRetentionDays = 90`.
  - `protocol SystemConditions: Sendable { func isOnACPower() -> Bool; func isNetworkAvailable() -> Bool; func isReachable(_ endpoint: Endpoint) -> Bool }`
  - `protocol AgentNotifier: Sendable { func notify(title: String, body: String) }`
  - `protocol ActivityHolding: Sendable { func begin(); func end() }`
  - `protocol TaskRunning: AnyObject, Sendable { run(_:dryRun:onUpdate:) async throws -> RunResult; pause(); resume(); stop() }` ; `extension TaskRunner: TaskRunning {}`
  - `AgentError` (`Error, Codable, Equatable, Sendable, LocalizedError`) : `unknownTask`, `notRunning`, `alreadyRunning`, `globallyPaused`, `notAwaitingApproval`, `versionMismatch(agent: Int, client: Int)`, `internalFailure(String)`.
  - `TaskRunState` (`Codable, Equatable, Sendable`) : `idle`, `queued`, `running`, `paused`, `waiting(reason: String)`, `awaitingApproval`, `disabled`.
  - `AgentTaskInfo` (`id`, `name`, `state`, `nextDue: Date?`, `lastRun: RunRecord?`) ; `AgentStatus` (`globalPause`, `stateRecovered`, `taskLoadError: String?`, `tasks: [AgentTaskInfo]`).
  - `ProgressInfo` (`Codable`) construit depuis `TransferSnapshot` ; `AgentEvent` : `taskStarted(UUID)`, `progress(UUID, ProgressInfo)`, `taskFinished(UUID, RunStatus, String?)`, `stateChanged`.
- Produit (tests) : `FakeClock`, `FakeConditions`, `FakeNotifier`, `FakeActivity`, `Gate`, `FakeRunner`, `RunnerFactory`, `eventually(_:)`.

- [ ] **Étape 1 : écrire le test des doubles**

`Tests/SyncKitTests/AgentTestSupportTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentTestSupportTests: XCTestCase {
    func testGatedRunnerWaitsForReleaseThenReportsItsStatus() async throws {
        let runner = FakeRunner(status: .succeeded, gated: true)
        let task = SyncTask(name: "t", source: .local(path: "/s"), destination: .local(path: "/d"))
        let job = Task { try await runner.run(task, dryRun: false, onUpdate: { _ in }) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(runner.calls.get(), ["run"])
        runner.release()
        let result = try await job.value
        XCTAssertEqual(result.status, .succeeded)
    }

    func testStopReleasesTheGateAndReportsStopped() async throws {
        let runner = FakeRunner(gated: true)
        let task = SyncTask(name: "t", source: .local(path: "/s"), destination: .local(path: "/d"))
        let job = Task { try await runner.run(task, dryRun: false, onUpdate: { _ in }) }
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.stop()
        let result = try await job.value
        XCTAssertEqual(result.status, .stopped)
    }

    func testFakeClockMoves() {
        let clock = FakeClock(Date(timeIntervalSince1970: 1000))
        clock.advance(60)
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 1060))
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter AgentTestSupportTests 2>&1 | tail -8`
Attendu : erreur de compilation.

- [ ] **Étape 3 : implémenter les types**

`Sources/SyncKit/Agent/TaskRunning.swift` :

```swift
import Foundation

/// Ce que l'agent attend d'un exécuteur de tâche ; `TaskRunner` y répond, les tests utilisent un faux.
public protocol TaskRunning: AnyObject, Sendable {
    func run(
        _ task: SyncTask, dryRun: Bool, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult
    func pause()
    func resume()
    func stop()
}

extension TaskRunner: TaskRunning {}
```

`Sources/SyncKit/Agent/AgentTypes.swift` :

```swift
import Foundation

public struct AgentConfiguration: Sendable {
    public var maxParallel = 2
    /// Délai avant une nouvelle tentative après un échec.
    public var retryDelay: TimeInterval = 3600
    public var maxAttempts = 3
    /// Un intervalle entre deux évaluations plus long que cela signifie que le Mac a dormi.
    public var wakeGap: TimeInterval = 150
    /// Attente après un réveil avant de lancer le rattrapage (le réseau doit revenir).
    public var wakeHold: TimeInterval = 60
    /// Même attente au démarrage de l'agent.
    public var startupHold: TimeInterval = 60
    public var historyRetentionDays = 90

    public init() {}
}

public protocol SystemConditions: Sendable {
    func isOnACPower() -> Bool
    func isNetworkAvailable() -> Bool
    /// Le dossier ou le volume existe ; pour un service en ligne : le réseau est disponible.
    func isReachable(_ endpoint: Endpoint) -> Bool
}

public protocol AgentNotifier: Sendable {
    func notify(title: String, body: String)
}

/// Empêche la mise en veille tant qu'une exécution est en cours.
public protocol ActivityHolding: Sendable {
    func begin()
    func end()
}

public enum AgentError: Error, Codable, Equatable, Sendable, LocalizedError {
    case unknownTask
    case notRunning
    case alreadyRunning
    case globallyPaused
    case notAwaitingApproval
    case versionMismatch(agent: Int, client: Int)
    case internalFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTask: return "Tâche inconnue."
        case .notRunning: return "Cette tâche n'est pas en cours d'exécution."
        case .alreadyRunning: return "Cette tâche est déjà en cours ou en file d'attente."
        case .globallyPaused: return "L'agent est en pause globale."
        case .notAwaitingApproval: return "Cette tâche n'attend aucune validation."
        case .versionMismatch(let agent, let client):
            return "Versions incompatibles (agent \(agent), outil \(client)) : mettez à jour l'agent ou l'application."
        case .internalFailure(let message): return "Erreur interne de l'agent : \(message)"
        }
    }
}

public enum TaskRunState: Codable, Equatable, Sendable {
    case idle
    case queued
    case running
    case paused
    case waiting(reason: String)
    case awaitingApproval
    case disabled
}

public struct AgentTaskInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var state: TaskRunState
    public var nextDue: Date?
    public var lastRun: RunRecord?

    public init(id: UUID, name: String, state: TaskRunState, nextDue: Date? = nil, lastRun: RunRecord? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.nextDue = nextDue
        self.lastRun = lastRun
    }
}

public struct AgentStatus: Codable, Equatable, Sendable {
    public var globalPause: Bool
    /// Vrai si le fichier d'état était illisible : l'agent est reparti en pause.
    public var stateRecovered: Bool
    public var taskLoadError: String?
    public var tasks: [AgentTaskInfo]

    public init(globalPause: Bool, stateRecovered: Bool, taskLoadError: String?, tasks: [AgentTaskInfo]) {
        self.globalPause = globalPause
        self.stateRecovered = stateRecovered
        self.taskLoadError = taskLoadError
        self.tasks = tasks
    }
}

/// Avancement d'une exécution, sous une forme qui traverse XPC.
public struct ProgressInfo: Codable, Equatable, Sendable {
    public var currentName: String?
    public var currentBytes: Int64
    public var currentSize: Int64
    public var currentSpeed: Double
    public var doneBytes: Int64
    public var totalBytes: Int64?
    public var filesDone: Int
    public var totalFiles: Int?
    public var overallPercent: Int?
    public var totalETA: TimeInterval?
    public var activeTime: TimeInterval

    public init(_ snapshot: TransferSnapshot) {
        currentName = snapshot.currentName
        currentBytes = snapshot.currentBytes
        currentSize = snapshot.currentSize
        currentSpeed = snapshot.currentSpeed
        doneBytes = snapshot.doneBytes
        totalBytes = snapshot.totalBytes
        filesDone = snapshot.filesDone
        totalFiles = snapshot.totalFiles
        overallPercent = snapshot.overallPercent
        totalETA = snapshot.totalETA
        activeTime = snapshot.activeTime
    }
}

public enum AgentEvent: Codable, Equatable, Sendable {
    case taskStarted(UUID)
    case progress(UUID, ProgressInfo)
    case taskFinished(UUID, RunStatus, String?)
    /// Pause globale, file d'attente ou liste de tâches modifiée : relire `status`.
    case stateChanged
}
```

- [ ] **Étape 4 : implémenter les doubles de test**

`Tests/SyncKitTests/AgentTestSupport.swift` :

```swift
import Foundation
import XCTest
@testable import SyncKit

final class FakeClock: SchedulerClock, @unchecked Sendable {
    private let current: Locked<Date>
    let calendar: Calendar

    init(_ start: Date, calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()) {
        current = Locked(start)
        self.calendar = calendar
    }

    func now() -> Date { current.get() }
    func set(_ date: Date) { current.set(date) }
    func advance(_ seconds: TimeInterval) { current.set(current.get().addingTimeInterval(seconds)) }
}

final class FakeConditions: SystemConditions, @unchecked Sendable {
    let acPower = Locked(true)
    let network = Locked(true)
    let reachable = Locked(true)

    func isOnACPower() -> Bool { acPower.get() }
    func isNetworkAvailable() -> Bool { network.get() }
    func isReachable(_ endpoint: Endpoint) -> Bool { reachable.get() }
}

final class FakeNotifier: AgentNotifier, @unchecked Sendable {
    let messages = Locked<[(title: String, body: String)]>([])
    func notify(title: String, body: String) { messages.set(messages.get() + [(title, body)]) }
}

final class FakeActivity: ActivityHolding, @unchecked Sendable {
    let begins = Locked(0)
    let ends = Locked(0)
    func begin() { begins.set(begins.get() + 1) }
    func end() { ends.set(ends.get() + 1) }
}

/// Porte que le test ouvre quand il veut qu'une exécution se termine.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

final class FakeRunner: TaskRunning, @unchecked Sendable {
    let calls = Locked<[String]>([])
    let ranTasks = Locked<[SyncTask]>([])
    let status = Locked<RunStatus>(.succeeded)
    let message = Locked<String?>(nil)
    let failure = Locked<Error?>(nil)
    private let gate: Gate?
    private let stopped = Locked(false)

    init(status: RunStatus = .succeeded, gated: Bool = false) {
        self.status.set(status)
        gate = gated ? Gate() : nil
    }

    func release() { gate?.release() }

    func run(
        _ task: SyncTask, dryRun: Bool, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        calls.set(calls.get() + ["run"])
        ranTasks.set(ranTasks.get() + [task])
        onUpdate(.phase(.running))
        if let gate { await gate.wait() }
        if let failure = failure.get() { throw failure }
        let final = stopped.get() ? RunStatus.stopped : status.get()
        return RunResult(
            status: final, engine: .rsync,
            summary: RunSummary(filesTransferred: 1, message: message.get()), snapshot: TransferSnapshot()
        )
    }

    func pause() { calls.set(calls.get() + ["pause"]) }
    func resume() { calls.set(calls.get() + ["resume"]) }
    func stop() {
        calls.set(calls.get() + ["stop"])
        stopped.set(true)
        gate?.release()
    }
}

/// Fabrique de faux exécuteurs : un par exécution, tous conservés pour que le test les pilote.
final class RunnerFactory: @unchecked Sendable {
    let runners = Locked<[FakeRunner]>([])
    let status = Locked<RunStatus>(.succeeded)
    let failure = Locked<Error?>(nil)
    let gated: Bool

    init(gated: Bool = false) { self.gated = gated }

    func make() -> TaskRunning {
        let runner = FakeRunner(status: status.get(), gated: gated)
        runner.failure.set(failure.get())
        runners.set(runners.get() + [runner])
        return runner
    }

    /// Exécutions réellement lancées (`run` appelé) : asynchrone, à n'utiliser qu'après `waitForIdle`.
    var runCount: Int { runners.get().reduce(0) { $0 + $1.ranTasks.get().count } }
    /// Exécuteurs créés : synchrone avec le démarrage d'une tâche, sûr à lire juste après `tick()`.
    var created: Int { runners.get().count }
}

/// Attend qu'une condition devienne vraie (2 s au plus) ; faux si elle ne l'est jamais.
func eventually(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
```

- [ ] **Étape 5 : vérifier**

Exécuter : `swift test --filter AgentTestSupportTests 2>&1 | tail -8` puis `swift build 2>&1 | tail -3`
Attendu : 3 tests passent ; la compilation complète réussit (`TaskRunner` répond bien à `TaskRunning`).

- [ ] **Étape 6 : commit**

```bash
git add Sources/SyncKit/Agent Tests/SyncKitTests/AgentTestSupport.swift Tests/SyncKitTests/AgentTestSupportTests.swift
git commit -m "Types de l'agent, interface d'exécution et doubles de test" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 5 : AgentCore, évaluation, file et exécution

**Fichiers :**
- Créer : `Sources/SyncKit/Agent/AgentCore.swift`
- Tester : `Tests/SyncKitTests/AgentCoreTests.swift`

**Interfaces :**
- Consomme : tâches 1 à 4.
- Produit : `public actor AgentCore` avec
  - `init(configuration: AgentConfiguration, taskStore: TaskStore, stateStore: SchedulerStateStore, history: HistoryStore, clock: SchedulerClock, conditions: SystemConditions, notifier: AgentNotifier, activity: ActivityHolding, log: @escaping @Sendable (String) -> Void = { _ in }, makeRunner: @escaping @Sendable () -> TaskRunning)`
  - `start()`, `tick()`, `reloadTasks()`, `status() -> AgentStatus`, `listTasks() -> [SyncTask]`, `runHistory(taskID: UUID?, limit: Int) throws -> [RunRecord]`, `waitForIdle() async`
  - `addObserver(_ handler: @escaping @Sendable (AgentEvent) -> Void) -> UUID`, `removeObserver(_ token: UUID)`
  - (les commandes arrivent à la tâche 6)

Comportement :
- `start()` : charge les tâches, marque `running` → `interrupted` dans l'historique, et toute tâche dont l'état garde `runningSince` (agent tué en route) reçoit `retryAt = maintenant` ; applique `startupHold`.
- `tick()` : détecte une veille (écart > `wakeGap` depuis le tick précédent → attente `wakeHold`), purge l'historique au plus une fois par jour, ne fait rien en pause globale ou pendant l'attente ; sinon met en file les tâches activées, dues, hors file, non en cours, non en attente de validation, **dont les conditions sont remplies** (sinon : état « en attente », pas d'échec) ; trie par échéance ; démarre jusqu'à `maxParallel`.
- Échéance : `retryAt` s'il existe ; sinon `Scheduler.nextDue` avec comme base `lastStart`, ou `firstSeen` pour les horaires fixes d'une tâche jamais lancée (`everyMinutes` jamais lancé = tout de suite).
- `whenAvailable` : passage de « inaccessible » (ou inconnu) à « accessible » → `retryAt = maintenant`.
- Fin d'exécution : réussite → `lastSuccess`, essais remis à 0 ; échec ou quota → essais +1 et `retryAt = +retryDelay` tant que essais < `maxAttempts`, sinon retour à l'échéance normale ; bloquée → « en attente de validation » ; arrêtée → rien à rattraper ; interrompue (arrêt de l'agent) → `retryAt = maintenant`. Notification selon `NotificationPolicy` (jamais pour arrêtée / interrompue). Assertion anti-veille tenue de 0 à 1 exécution et relâchée à 1 → 0.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncKitTests/AgentCoreTests.swift` :

```swift
import XCTest
@testable import SyncKit

/// Tout ce qu'il faut pour piloter un AgentCore dans le temps, sans processus ni attente réelle.
final class AgentHarness {
    let directory: URL
    let clock: FakeClock
    let conditions = FakeConditions()
    let notifier = FakeNotifier()
    let activity = FakeActivity()
    let factory: RunnerFactory
    let taskStore: TaskStore
    let stateStore: SchedulerStateStore
    let history: HistoryStore
    var configuration = AgentConfiguration()

    init(start: Date, gated: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        clock = FakeClock(start)
        factory = RunnerFactory(gated: gated)
        taskStore = TaskStore(url: directory.appendingPathComponent("tasks.json"))
        stateStore = SchedulerStateStore(url: directory.appendingPathComponent("scheduler-state.json"))
        history = try HistoryStore(path: directory.appendingPathComponent("history.sqlite").path)
        configuration.startupHold = 0
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        clock.calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    func save(_ tasks: [SyncTask]) throws { try taskStore.save(tasks) }

    func makeCore(runner: (@Sendable () -> TaskRunning)? = nil) -> AgentCore {
        let factory = self.factory
        return AgentCore(
            configuration: configuration, taskStore: taskStore, stateStore: stateStore, history: history,
            clock: clock, conditions: conditions, notifier: notifier, activity: activity,
            makeRunner: runner ?? { factory.make() }
        )
    }

    /// Avance minute par minute en évaluant à chaque pas, comme le minuteur de l'agent.
    func step(_ core: AgentCore, minutes: Int, wait: Bool = true) async {
        for _ in 0..<minutes {
            clock.advance(60)
            await core.tick()
            if wait { await core.waitForIdle() }
        }
    }
}

func makeTask(
    _ name: String = "tâche", schedule: Schedule = .everyMinutes(1), mode: SyncMode = .copy,
    notifications: NotificationPolicy = .always, conditions: TaskConditions = TaskConditions()
) -> SyncTask {
    SyncTask(
        name: name, source: .local(path: "/source"), destination: .local(path: "/dest"), mode: mode,
        schedule: schedule, notifications: notifications, conditions: conditions
    )
}

final class AgentSchedulingTests: XCTestCase {
    func testDailyTaskRunsAtItsTimeExactlyOnce() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 2, 0))
        let task = makeTask("nuit", schedule: .daily(hour: 3, minute: 0))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await h.step(core, minutes: 30)
        XCTAssertEqual(h.factory.runCount, 0)
        await h.step(core, minutes: 40)   // 03:10
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 30)
        XCTAssertEqual(h.factory.runCount, 1)
        XCTAssertEqual(try h.history.list(taskID: task.id).map(\.status), [.succeeded])
    }

    func testEveryMinutesRunsImmediatelyThenWaitsForTheInterval() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 9))
        try h.save([makeTask(schedule: .everyMinutes(10))])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 9)
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 1)
        XCTAssertEqual(h.factory.runCount, 2)
    }

    func testManualTaskNeverRunsByItself() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        try h.save([makeTask(schedule: .manual)])
        let core = h.makeCore()
        await core.start()
        await h.step(core, minutes: 120)
        XCTAssertEqual(h.factory.runCount, 0)
    }

    func testDisabledTaskDoesNotRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        var task = makeTask()
        task.isEnabled = false
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await h.step(core, minutes: 3)
        XCTAssertEqual(h.factory.runCount, 0)
        let state = await core.status().tasks.first?.state
        XCTAssertEqual(state, .disabled)
    }

    func testMissedRunsAfterSleepCatchUpOnlyOnceAfterTheWakeDelay() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 2, 0))
        try h.save([makeTask(schedule: .daily(hour: 3, minute: 0))])
        let core = h.makeCore()
        await core.start()
        await h.step(core, minutes: 70)            // 03:10, première exécution
        XCTAssertEqual(h.factory.runCount, 1)
        h.clock.set(h.at(2026, 10, 15, 9, 0))      // le Mac a dormi trois jours
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1, "attente de 60 s après le réveil")
        h.clock.advance(61)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2, "une seule exécution de rattrapage")
        await h.step(core, minutes: 5)
        XCTAssertEqual(h.factory.runCount, 2)
    }

    func testStartupHoldDelaysTheFirstEvaluation() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.configuration.startupHold = 60
        try h.save([makeTask(schedule: .everyMinutes(5))])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        h.clock.advance(61)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testUnmetConditionsMakeTheTaskWaitInsteadOfFailing() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.conditions.acPower.set(false)
        let task = makeTask(conditions: TaskConditions(requiresACPower: true))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        let waiting = await core.status().tasks[0].state
        guard case .waiting = waiting else { return XCTFail("attendu : en attente, trouvé \(waiting)") }
        XCTAssertTrue(try h.history.list().isEmpty)
        h.conditions.acPower.set(true)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testHoursWindowBlocksOutsideTheRange() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 14, 0))
        try h.save([makeTask(conditions: TaskConditions(allowedHours: HourRange(start: 22, end: 6)))])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        h.clock.set(h.at(2026, 10, 12, 23, 0))   // un saut de 9 h ressemble à une veille : attente de 60 s
        await core.tick()
        h.clock.advance(61)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testUnreachableDestinationMakesTheTaskWait() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.conditions.reachable.set(false)
        try h.save([makeTask()])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        h.conditions.reachable.set(true)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testWhenAvailableRunsOnceEachTimeTheVolumeAppears() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.conditions.reachable.set(false)
        try h.save([makeTask(schedule: .whenAvailable)])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        h.conditions.reachable.set(true)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 3)
        XCTAssertEqual(h.factory.runCount, 1, "toujours branché : pas de nouvelle exécution")
        h.conditions.reachable.set(false)
        await core.tick()
        h.conditions.reachable.set(true)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2)
    }
}

final class AgentConcurrencyTests: XCTestCase {
    func testAtMostTwoRunsInParallelAndTheThirdStartsWhenASlotFrees() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        try h.save([makeTask("A"), makeTask("B"), makeTask("C")])
        let core = h.makeCore()
        await core.start()
        await core.tick()
        var states = await core.status().tasks.map(\.state)
        XCTAssertEqual(states.filter { $0 == .running }.count, 2)
        XCTAssertEqual(states.filter { $0 == .queued }.count, 1)
        XCTAssertEqual(h.activity.begins.get(), 1)

        h.factory.runners.get()[0].release()
        let started = await eventually { h.factory.runners.get().count == 3 }
        XCTAssertTrue(started, "la troisième tâche démarre quand une place se libère")
        states = await core.status().tasks.map(\.state)
        XCTAssertEqual(states.filter { $0 == .queued }.count, 0)

        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        XCTAssertEqual(h.activity.begins.get(), 1)
        XCTAssertEqual(h.activity.ends.get(), 1, "l'anti-veille est relâché quand la file est vide")
    }

    func testATaskNeverRunsTwiceAtTheSameTime() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        try h.save([makeTask(schedule: .everyMinutes(1))])
        let core = h.makeCore()
        await core.start()
        await core.tick()
        await h.step(core, minutes: 3, wait: false)
        XCTAssertEqual(h.factory.created, 1)
        h.factory.runners.get()[0].release()
        await core.waitForIdle()
    }
}

final class AgentFailureTests: XCTestCase {
    func testFailuresRetryAfterAnHourThreeTimesThenFollowTheNormalSchedule() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.status.set(.failed)
        try h.save([makeTask(schedule: .everyMinutes(1))])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 30)
        XCTAssertEqual(h.factory.runCount, 1, "la nouvelle tentative attend une heure")
        await h.step(core, minutes: 30)
        XCTAssertEqual(h.factory.runCount, 2)
        await h.step(core, minutes: 60)
        XCTAssertEqual(h.factory.runCount, 3)
        XCTAssertEqual(h.notifier.messages.get().count, 3)
        await h.step(core, minutes: 1)
        XCTAssertEqual(h.factory.runCount, 4, "après trois essais : retour à l'échéance normale")
    }

    func testNotificationPolicyErrorsOnlyStaysSilentOnSuccess() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        try h.save([makeTask(notifications: .errorsOnly)])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        XCTAssertTrue(h.notifier.messages.get().isEmpty)
    }

    func testRunnerThatThrowsIsRecordedAsFailed() async throws {
        struct Boom: Error {}
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.failure.set(Boom())
        let task = makeTask()
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        let record = try XCTUnwrap(try h.history.list(taskID: task.id).first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.summary?.message?.contains("Boom") == true)
    }

    func testHistoryOlderThanRetentionIsPurged() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 9))
        try h.save([makeTask(schedule: .manual)])
        let old = RunRecord(
            taskID: UUID(), taskName: "vieille", engine: .rsync, mode: .copy,
            startedAt: h.clock.now().addingTimeInterval(-100 * 86400),
            finishedAt: h.clock.now().addingTimeInterval(-100 * 86400), status: .succeeded
        )
        try h.history.save(old)
        let core = h.makeCore()
        await core.start()
        await core.tick()
        XCTAssertNil(try h.history.record(id: old.id))
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter "AgentSchedulingTests|AgentConcurrencyTests|AgentFailureTests" 2>&1 | tail -10`
Attendu : erreur de compilation (`AgentCore` inconnu).

- [ ] **Étape 3 : implémenter `AgentCore`**

`Sources/SyncKit/Agent/AgentCore.swift` :

```swift
import Foundation

/// Cerveau de l'agent : décide quelles tâches lancer et quand, les exécute (2 à la fois au plus),
/// tient l'état et l'historique. Aucune horloge, aucun système en dur : tout est injecté, donc testable.
public actor AgentCore {
    struct QueuedRun {
        var id: UUID
        var dueDate: Date
        var overrideGuard = false
    }

    struct Job {
        var task: SyncTask
        var runner: TaskRunning
        var record: RunRecord
        var paused = false
        var pausedByGlobal = false
        var lastProgressEmit: Date?
        var latest: ProgressInfo?
    }

    let configuration: AgentConfiguration
    let taskStore: TaskStore
    let stateStore: SchedulerStateStore
    let history: HistoryStore
    let clock: SchedulerClock
    let conditions: SystemConditions
    let notifier: AgentNotifier
    let activity: ActivityHolding
    let log: @Sendable (String) -> Void
    let makeRunner: @Sendable () -> TaskRunning

    var tasks: [SyncTask] = []
    var state: SchedulerState
    let stateRecovered: Bool
    var taskLoadError: String?
    var jobs: [UUID: Job] = [:]
    var jobTasks: [UUID: Task<Void, Never>] = [:]
    var queue: [QueuedRun] = []
    var waiting: [UUID: String] = [:]
    var holdUntil: Date?
    var lastTick: Date?
    var shuttingDown = false
    var observers: [UUID: @Sendable (AgentEvent) -> Void] = [:]

    public init(
        configuration: AgentConfiguration, taskStore: TaskStore, stateStore: SchedulerStateStore,
        history: HistoryStore, clock: SchedulerClock, conditions: SystemConditions,
        notifier: AgentNotifier, activity: ActivityHolding,
        log: @escaping @Sendable (String) -> Void = { _ in },
        makeRunner: @escaping @Sendable () -> TaskRunning
    ) {
        self.configuration = configuration
        self.taskStore = taskStore
        self.stateStore = stateStore
        self.history = history
        self.clock = clock
        self.conditions = conditions
        self.notifier = notifier
        self.activity = activity
        self.log = log
        self.makeRunner = makeRunner
        let loaded = stateStore.load()
        state = loaded.state
        stateRecovered = loaded.recovered
    }

    // MARK: démarrage

    /// À appeler une fois au lancement de l'agent.
    public func start() {
        let now = clock.now()
        loadTasks()
        _ = try? history.markRunningAsInterrupted(at: now)
        // Une tâche encore « en cours » dans l'état : l'agent a été tué en route. Elle sera rattrapée.
        for key in state.tasks.keys where state.tasks[key]?.runningSince != nil {
            state.tasks[key]?.runningSince = nil
            state.tasks[key]?.retryAt = now
        }
        if configuration.startupHold > 0 { holdUntil = now.addingTimeInterval(configuration.startupHold) }
        persist()
    }

    /// Relit `tasks.json`. En cas d'erreur de lecture, on garde la liste précédente et on le signale.
    public func reloadTasks() {
        loadTasks()
        persist()
        emit(.stateChanged)
    }

    func loadTasks() {
        do {
            tasks = try taskStore.load()
            taskLoadError = nil
        } catch {
            taskLoadError = "\(error)"
            log("tasks.json illisible : \(error)")
            return
        }
        let now = clock.now()
        for task in tasks where state.tasks[task.id.uuidString] == nil {
            state.tasks[task.id.uuidString] = TaskScheduleState(firstSeen: now)
        }
        let known = Set(tasks.map { $0.id.uuidString })
        state.tasks = state.tasks.filter { key, _ in
            known.contains(key) || UUID(uuidString: key).map { jobs[$0] != nil } == true
        }
    }

    // MARK: évaluation

    /// Appelée chaque minute et à chaque réveil par le programme de l'agent.
    public func tick() {
        let now = clock.now()
        defer { lastTick = now }
        if let last = lastTick, now.timeIntervalSince(last) > configuration.wakeGap {
            holdUntil = now.addingTimeInterval(configuration.wakeHold)
        }
        purgeHistoryIfNeeded(now)
        guard !state.paused else { return }
        if let hold = holdUntil {
            if now < hold { return }
            holdUntil = nil
        }
        var changed = false
        for task in tasks where task.isEnabled {
            let key = task.id.uuidString
            guard jobs[task.id] == nil, !queue.contains(where: { $0.id == task.id }),
                  var entry = state.tasks[key], !entry.awaitingApproval else { continue }
            if task.schedule == .whenAvailable {
                let available = conditions.isReachable(task.source) && conditions.isReachable(task.destination)
                if entry.wasAvailable != available {
                    if available { entry.retryAt = now }
                    entry.wasAvailable = available
                    state.tasks[key] = entry
                    changed = true
                }
            }
            guard let due = dueDate(task, entry, now), due <= now else { continue }
            if let reason = unmetCondition(task, now: now) {
                waiting[task.id] = reason
                continue
            }
            waiting[task.id] = nil
            queue.append(QueuedRun(id: task.id, dueDate: due))
        }
        queue.sort { $0.dueDate < $1.dueDate }
        if changed { persist() }
        startQueued()
    }

    /// Échéance d'une tâche : le prochain essai s'il y en a un, sinon la prochaine occurrence de son horaire.
    func dueDate(_ task: SyncTask, _ entry: TaskScheduleState, _ now: Date) -> Date? {
        if let retry = entry.retryAt { return retry }
        let usesCalendar: Bool
        switch task.schedule {
        case .daily, .weekdays: usesCalendar = true
        case .everyMinutes, .manual, .whenAvailable: usesCalendar = false
        }
        let basis = entry.lastStart ?? (usesCalendar ? entry.firstSeen : nil)
        return Scheduler.nextDue(for: task.schedule, after: basis, now: now, calendar: clock.calendar)
    }

    func unmetCondition(_ task: SyncTask, now: Date) -> String? {
        let required = task.conditions
        if required.requiresACPower && !conditions.isOnACPower() { return "branchement secteur requis" }
        let needsNetwork = required.requiresNetwork || task.source.isCloud || task.destination.isCloud
        if needsNetwork && !conditions.isNetworkAvailable() { return "réseau indisponible" }
        if let range = required.allowedHours,
           !range.contains(hour: clock.calendar.component(.hour, from: now)) {
            return "hors de la plage horaire autorisée"
        }
        if !conditions.isReachable(task.source) { return "source inaccessible" }
        if !conditions.isReachable(task.destination) { return "destination inaccessible" }
        return nil
    }

    func purgeHistoryIfNeeded(_ now: Date) {
        if let last = state.lastPurge, now.timeIntervalSince(last) < 86400 { return }
        let limit = now.addingTimeInterval(-Double(configuration.historyRetentionDays) * 86400)
        _ = try? history.purge(finishedBefore: limit)
        state.lastPurge = now
        persist()
    }

    // MARK: exécution

    func startQueued() {
        guard !state.paused, !shuttingDown else { return }
        while jobs.count < configuration.maxParallel, !queue.isEmpty {
            let next = queue.removeFirst()
            guard let task = tasks.first(where: { $0.id == next.id }), jobs[task.id] == nil else { continue }
            startJob(task, overrideGuard: next.overrideGuard)
        }
    }

    func startJob(_ task: SyncTask, overrideGuard: Bool) {
        var runTask = task
        if overrideGuard { runTask.options.deleteThresholdPercent = 100 }
        let now = clock.now()
        let key = task.id.uuidString
        let engine = (try? EngineSelector.engine(for: runTask)) ?? .rsync
        let record = RunRecord(taskID: task.id, taskName: task.name, engine: engine, mode: task.mode, startedAt: now)
        try? history.save(record)

        var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: now)
        entry.lastStart = now
        entry.runningSince = now
        entry.retryAt = nil
        entry.awaitingApproval = false
        state.tasks[key] = entry
        persist()

        let runner = makeRunner()
        jobs[task.id] = Job(task: task, runner: runner, record: record)
        waiting[task.id] = nil
        if jobs.count == 1 { activity.begin() }
        emit(.taskStarted(task.id))

        let id = task.id
        jobTasks[id] = Task.detached { [weak self] in
            let outcome: Result<RunResult, Error>
            do {
                outcome = .success(try await runner.run(runTask, dryRun: false) { update in
                    if case .snapshot(let snapshot) = update { Task { await self?.progress(id, snapshot) } }
                })
            } catch {
                outcome = .failure(error)
            }
            await self?.finish(id, outcome)
        }
    }

    func progress(_ id: UUID, _ snapshot: TransferSnapshot) {
        guard var job = jobs[id] else { return }
        let now = clock.now()
        let info = ProgressInfo(snapshot)
        job.latest = info
        // Au plus deux messages par seconde et par tâche : l'interface n'a pas besoin de plus.
        if let last = job.lastProgressEmit, now.timeIntervalSince(last) < 0.5 {
            jobs[id] = job
            return
        }
        job.lastProgressEmit = now
        jobs[id] = job
        emit(.progress(id, info))
    }

    func finish(_ id: UUID, _ outcome: Result<RunResult, Error>) {
        jobTasks[id] = nil
        guard var job = jobs.removeValue(forKey: id) else { return }
        let now = clock.now()
        var status: RunStatus
        let summary: RunSummary
        switch outcome {
        case .success(let result):
            status = result.status
            summary = result.summary
        case .failure(let error):
            status = .failed
            summary = RunSummary(
                errors: 1, durationSeconds: now.timeIntervalSince(job.record.startedAt), message: "\(error)"
            )
        }
        if shuttingDown && status == .stopped { status = .interrupted }

        job.record.status = status
        job.record.summary = summary
        job.record.finishedAt = now
        try? history.save(job.record)

        let key = id.uuidString
        var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: now)
        entry.runningSince = nil
        switch status {
        case .succeeded:
            entry.lastSuccess = now
            entry.attempts = 0
            entry.retryAt = nil
        case .failed, .quotaReached:
            entry.attempts += 1
            if entry.attempts < configuration.maxAttempts {
                entry.retryAt = now.addingTimeInterval(configuration.retryDelay)
            } else {
                entry.attempts = 0
                entry.retryAt = nil
            }
        case .blocked:
            entry.awaitingApproval = true
            entry.attempts = 0
            entry.retryAt = nil
        case .interrupted:
            entry.retryAt = now
        case .stopped:
            entry.attempts = 0
            entry.retryAt = nil
        case .running:
            break
        }
        state.tasks[key] = entry
        persist()

        notify(job.task, status, summary)
        if jobs.isEmpty { activity.end() }
        emit(.taskFinished(id, status, summary.message))
        startQueued()
    }

    func notify(_ task: SyncTask, _ status: RunStatus, _ summary: RunSummary) {
        if shuttingDown || status == .stopped || status == .interrupted || status == .running { return }
        let isError = status == .failed || status == .blocked || status == .quotaReached
        switch task.notifications {
        case .never: return
        case .errorsOnly: if !isError { return }
        case .always: break
        }
        let title: String
        switch status {
        case .succeeded: title = "\(task.name) : terminée"
        case .blocked: title = "\(task.name) : validation requise"
        case .quotaReached: title = "\(task.name) : quota atteint"
        default: title = "\(task.name) : échec"
        }
        let body = summary.message
            ?? "\(summary.filesTransferred) fichier(s), \(Formatting.bytes(summary.bytesTransferred))"
        notifier.notify(title: title, body: body)
    }

    // MARK: lecture

    public func listTasks() -> [SyncTask] { tasks }

    public func runHistory(taskID: UUID?, limit: Int) throws -> [RunRecord] {
        try history.list(taskID: taskID, limit: limit)
    }

    public func status() -> AgentStatus {
        let now = clock.now()
        let infos = tasks.map { task -> AgentTaskInfo in
            let entry = state.tasks[task.id.uuidString]
            let runState: TaskRunState
            if let job = jobs[task.id] {
                runState = job.paused ? .paused : .running
            } else if queue.contains(where: { $0.id == task.id }) {
                runState = .queued
            } else if !task.isEnabled {
                runState = .disabled
            } else if entry?.awaitingApproval == true {
                runState = .awaitingApproval
            } else if let reason = waiting[task.id] {
                runState = .waiting(reason: reason)
            } else {
                runState = .idle
            }
            let next = task.isEnabled ? entry.flatMap { dueDate(task, $0, now) } : nil
            let last = (try? history.list(taskID: task.id, limit: 1))?.first
            return AgentTaskInfo(id: task.id, name: task.name, state: runState, nextDue: next, lastRun: last)
        }
        return AgentStatus(
            globalPause: state.paused, stateRecovered: stateRecovered, taskLoadError: taskLoadError, tasks: infos
        )
    }

    /// Attend la fin de toutes les exécutions en cours (tests, arrêt de l'agent).
    public func waitForIdle() async {
        while let running = jobTasks.values.first { await running.value }
    }

    // MARK: observateurs

    public func addObserver(_ handler: @escaping @Sendable (AgentEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) { observers[token] = nil }

    func emit(_ event: AgentEvent) {
        for handler in observers.values { handler(event) }
    }

    func persist() {
        do { try stateStore.save(state) } catch { log("état non enregistré : \(error)") }
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter "AgentSchedulingTests|AgentConcurrencyTests|AgentFailureTests" 2>&1 | tail -15`
Attendu : tous passent. En cas d'échec sur le rattrapage, relire `tick()` : l'écart de 3 jours doit déclencher l'attente de 60 s **avant** l'évaluation des tâches.

- [ ] **Étape 5 : suite complète puis commit**

Exécuter : `SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync" swift test 2>&1 | tail -5`
Attendu : tout est vert.

```bash
git add Sources/SyncKit/Agent/AgentCore.swift Tests/SyncKitTests/AgentCoreTests.swift
git commit -m "AgentCore : évaluation, file à 2 exécutions, rattrapage, conditions, nouvelles tentatives" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 6 : commandes, pause globale, validation, arrêt de l'agent

**Fichiers :**
- Créer : `Sources/SyncKit/Agent/AgentCore+Control.swift`
- Tester : `Tests/SyncKitTests/AgentControlTests.swift`

**Interfaces :**
- Consomme : `AgentCore` (tâche 5, membres internes `jobs`, `queue`, `state`, `startQueued`, `emit`, `persist`).
- Produit : sur `AgentCore` : `runNow(_:) throws`, `pause(_:) throws`, `resume(_:) throws`, `stop(_:) throws`, `setGlobalPause(_:)`, `approveDeletion(_:) throws`, `shutdown() async`.

Comportement :
- `runNow` : refuse en pause globale (`globallyPaused`), tâche inconnue (`unknownTask`), déjà en cours ou en file (`alreadyRunning`) ; ignore planification et conditions ; passe devant la file.
- `pause` / `resume` / `stop` : tâche en cours sinon `notRunning` ; `stop` retire aussi une tâche en file ; `resume` refusé en pause globale ; `TaskRunner.terminate` reprend déjà un processus figé avant de l'arrêter.
- `setGlobalPause(true)` : enregistre `paused`, met en pause toutes les exécutions (`pausedByGlobal`) ; `false` : reprend celles-là, efface l'attente, évalue tout de suite (rattrapage).
- `approveDeletion` : exige `awaitingApproval` ; relance avec `overrideGuard`.
- `shutdown` : plus aucun démarrage, arrête les exécutions, statut `interrupted` (rattrapées au prochain démarrage), attend leur fin.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncKitTests/AgentControlTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentControlTests: XCTestCase {
    func testRunNowIgnoresScheduleAndConditions() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.conditions.acPower.set(false)
        let task = makeTask(schedule: .manual, conditions: TaskConditions(requiresACPower: true))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testRunNowErrors() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        do { try await core.runNow(UUID()); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .unknownTask) }
        try await core.runNow(task.id)
        do { try await core.runNow(task.id); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .alreadyRunning) }
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testPauseResumeStopAreForwardedToTheRunner() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        do { try await core.pause(task.id); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .notRunning) }
        try await core.runNow(task.id)
        let started = await eventually { h.factory.runners.get()[0].calls.get().contains("run") }
        XCTAssertTrue(started)
        try await core.pause(task.id)
        var state = await core.status().tasks[0].state
        XCTAssertEqual(state, .paused)
        try await core.resume(task.id)
        state = await core.status().tasks[0].state
        XCTAssertEqual(state, .running)
        try await core.stop(task.id)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runners.get()[0].calls.get(), ["run", "pause", "resume", "stop"])
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .stopped)
    }

    func testStoppedTaskIsNotRetried() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        try await core.stop(task.id)
        await core.waitForIdle()
        await h.step(core, minutes: 120)
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testGlobalPausePausesRunsStopsNewOnesAndSurvivesARestart() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let running = makeTask("A", schedule: .manual)
        let scheduled = makeTask("B", schedule: .everyMinutes(1))
        try h.save([running, scheduled])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(running.id)

        await core.setGlobalPause(true)
        XCTAssertTrue(h.factory.runners.get()[0].calls.get().contains("pause"))
        let before = h.factory.created
        await h.step(core, minutes: 5, wait: false)
        XCTAssertEqual(h.factory.created, before, "rien ne démarre en pause globale")
        do { try await core.runNow(scheduled.id); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .globallyPaused) }

        // Redémarrage de l'agent : la pause est relue sur le disque.
        let restarted = h.makeCore()
        await restarted.start()
        let paused = await restarted.status().globalPause
        XCTAssertTrue(paused)

        await core.setGlobalPause(false)
        XCTAssertTrue(h.factory.runners.get()[0].calls.get().contains("resume"))
        let caughtUp = await eventually { h.factory.created > before }
        XCTAssertTrue(caughtUp, "à la reprise, la tâche en retard est rattrapée")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testBlockedTaskWaitsForApprovalThenRunsWithTheGuardRaised() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.status.set(.blocked)
        let task = makeTask(schedule: .everyMinutes(1), mode: .mirror)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        let state = await core.status().tasks[0].state
        XCTAssertEqual(state, .awaitingApproval)
        XCTAssertEqual(h.notifier.messages.get().count, 1)
        await h.step(core, minutes: 5)
        XCTAssertEqual(h.factory.runCount, 1, "pas de relance tant que l'utilisateur n'a pas validé")

        h.factory.status.set(.succeeded)
        try await core.approveDeletion(task.id)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2)
        let lastRun = h.factory.runners.get()[1].ranTasks.get()[0]
        XCTAssertEqual(lastRun.options.deleteThresholdPercent, 100)
        let after = await core.status().tasks[0].state
        XCTAssertEqual(after, .idle)
    }

    func testApproveRequiresAPendingApproval() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        do { try await core.approveDeletion(task.id); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .notAwaitingApproval)
        }
    }

    func testShutdownMarksRunsInterruptedAndTheyAreCaughtUpOnTheNextStart() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .daily(hour: 3, minute: 0))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.shutdown()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .interrupted)
        XCTAssertTrue(h.notifier.messages.get().isEmpty)

        let next = h.makeCore()
        await next.start()
        await next.tick()
        XCTAssertEqual(h.factory.created, 2, "l'exécution interrompue est rattrapée")
        h.factory.runners.get().forEach { $0.release() }
        await next.waitForIdle()
    }

    func testKilledAgentLeavesARunningRecordThatIsInterruptedAndCaughtUp() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .daily(hour: 3, minute: 0))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        // L'agent est tué net : aucun `shutdown`, l'enregistrement reste « en cours ».
        let restarted = h.makeCore()
        await restarted.start()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .interrupted)
        await restarted.tick()
        XCTAssertEqual(h.factory.created, 2)
        h.factory.runners.get().forEach { $0.release() }
        await restarted.waitForIdle()
        await core.waitForIdle()
    }

    func testUnreadableTasksFileKeepsThePreviousTasks() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        try h.save([makeTask("A", schedule: .manual)])
        let core = h.makeCore()
        await core.start()
        try h.save([makeTask("A", schedule: .manual), makeTask("B", schedule: .manual)])
        await core.reloadTasks()
        var status = await core.status()
        XCTAssertEqual(status.tasks.count, 2)
        try "{ cassé".write(to: h.taskStore.url, atomically: true, encoding: .utf8)
        await core.reloadTasks()
        status = await core.status()
        XCTAssertEqual(status.tasks.count, 2)
        XCTAssertNotNil(status.taskLoadError)
    }

    func testObserversReceiveStartAndFinishEvents() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        let events = Locked<[AgentEvent]>([])
        let token = await core.addObserver { events.set(events.get() + [$0]) }
        try await core.runNow(task.id)
        await core.waitForIdle()
        await core.removeObserver(token)
        let all = events.get()
        XCTAssertTrue(all.contains(.taskStarted(task.id)))
        XCTAssertTrue(all.contains { if case .taskFinished(task.id, .succeeded, _) = $0 { return true } else { return false } })
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter AgentControlTests 2>&1 | tail -8`
Attendu : erreur de compilation (`runNow` etc. absents).

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/Agent/AgentCore+Control.swift` :

```swift
import Foundation

extension AgentCore {
    /// Lance la tâche maintenant, sans tenir compte de l'horaire ni des conditions.
    public func runNow(_ id: UUID) throws {
        try enqueueNow(id, overrideGuard: false)
    }

    /// L'utilisateur accepte les suppressions qui avaient bloqué la tâche : une exécution avec le seuil relevé.
    public func approveDeletion(_ id: UUID) throws {
        guard tasks.contains(where: { $0.id == id }) else { throw AgentError.unknownTask }
        guard state.tasks[id.uuidString]?.awaitingApproval == true else { throw AgentError.notAwaitingApproval }
        try enqueueNow(id, overrideGuard: true)
    }

    private func enqueueNow(_ id: UUID, overrideGuard: Bool) throws {
        guard !state.paused else { throw AgentError.globallyPaused }
        guard tasks.contains(where: { $0.id == id }) else { throw AgentError.unknownTask }
        guard jobs[id] == nil, !queue.contains(where: { $0.id == id }) else { throw AgentError.alreadyRunning }
        queue.insert(QueuedRun(id: id, dueDate: .distantPast, overrideGuard: overrideGuard), at: 0)
        startQueued()
        emit(.stateChanged)
    }

    public func pause(_ id: UUID) throws {
        guard var job = jobs[id] else { throw AgentError.notRunning }
        guard !job.paused else { return }
        job.runner.pause()
        job.paused = true
        jobs[id] = job
        emit(.stateChanged)
    }

    public func resume(_ id: UUID) throws {
        guard var job = jobs[id] else { throw AgentError.notRunning }
        guard !state.paused else { throw AgentError.globallyPaused }
        guard job.paused else { return }
        job.runner.resume()
        job.paused = false
        job.pausedByGlobal = false
        jobs[id] = job
        emit(.stateChanged)
    }

    /// Arrête une exécution, ou retire la tâche de la file d'attente.
    public func stop(_ id: UUID) throws {
        if let job = jobs[id] {
            job.runner.stop()   // `TaskRunner` reprend d'abord un processus figé, puis l'arrête
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { throw AgentError.notRunning }
        queue.remove(at: index)
        emit(.stateChanged)
    }

    /// Pause globale : plus rien ne démarre, les exécutions en cours sont figées. Enregistrée sur le disque.
    public func setGlobalPause(_ paused: Bool) {
        guard paused != state.paused else { return }
        state.paused = paused
        persist()
        if paused {
            for id in Array(jobs.keys) {
                guard var job = jobs[id], !job.paused else { continue }
                job.runner.pause()
                job.paused = true
                job.pausedByGlobal = true
                jobs[id] = job
            }
        } else {
            for id in Array(jobs.keys) {
                guard var job = jobs[id], job.pausedByGlobal else { continue }
                job.runner.resume()
                job.paused = false
                job.pausedByGlobal = false
                jobs[id] = job
            }
            holdUntil = nil
            tick()
        }
        emit(.stateChanged)
    }

    /// Arrêt de l'agent (SIGTERM, déconnexion) : les exécutions sont arrêtées proprement,
    /// marquées « interrompues » et rattrapées au prochain démarrage.
    public func shutdown() async {
        shuttingDown = true
        queue.removeAll()
        for job in jobs.values { job.runner.stop() }
        await waitForIdle()
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter AgentControlTests 2>&1 | tail -15`
Attendu : tous passent. Puis la suite complète : `SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync" swift test 2>&1 | tail -5` → vert.

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncKit/Agent/AgentCore+Control.swift Tests/SyncKitTests/AgentControlTests.swift
git commit -m "Commandes de l'agent : lancer, pause, reprise, arrêt, pause globale persistante, validation, arrêt propre" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 7 : contrat XPC versionné et routeur de requêtes

**Fichiers :**
- Créer : `Sources/SyncKit/Agent/AgentProtocol.swift`, `Sources/SyncKit/Agent/AgentRouter.swift`
- Tester : `Tests/SyncKitTests/AgentProtocolTests.swift`

**Interfaces :**
- Consomme : `AgentCore`, `AgentStatus`, `AgentError`, `AgentEvent` (tâches 4 à 6).
- Produit :
  - `let agentProtocolVersion = 1`
  - `enum AgentRequest` (`status`, `listTasks`, `history(taskID: UUID?, limit: Int)`, `runNow(UUID)`, `pause(UUID)`, `resume(UUID)`, `stop(UUID)`, `setGlobalPause(Bool)`, `approveDeletion(UUID)`, `reloadTasks`) et `enum AgentResponse` (`ok`, `status(AgentStatus)`, `tasks([SyncTask])`, `history([RunRecord])`, `error(AgentError)`), tous `Codable, Equatable, Sendable`
  - `struct AgentRequestEnvelope { version: Int; request: AgentRequest }`, `struct AgentResponseEnvelope { version: Int; response: AgentResponse }`
  - `@objc protocol AgentXPCProtocol { request(_:reply:); subscribe(_:reply:) }`, `@objc protocol AgentObserverXPC { event(_:) }`
  - `enum AgentXPC { static func makeInterface() -> NSXPCInterface }`
  - `enum AgentRouter { static func handle(_ data: Data, core: AgentCore) async -> Data }`

Règle : le routeur lit d'abord **seulement** le numéro de version ; si elle diffère, il répond `error(.versionMismatch(agent:client:))` sans interpréter le reste.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncKitTests/AgentProtocolTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentProtocolTests: XCTestCase {
    func roundTrip(_ request: AgentRequest) throws -> AgentRequest {
        let data = try JSONEncoder().encode(AgentRequestEnvelope(version: agentProtocolVersion, request: request))
        return try JSONDecoder().decode(AgentRequestEnvelope.self, from: data).request
    }

    func testEveryRequestSurvivesEncoding() throws {
        let id = UUID()
        let requests: [AgentRequest] = [
            .status, .listTasks, .history(taskID: id, limit: 5), .history(taskID: nil, limit: 20),
            .runNow(id), .pause(id), .resume(id), .stop(id), .setGlobalPause(true), .approveDeletion(id), .reloadTasks,
        ]
        for request in requests { XCTAssertEqual(try roundTrip(request), request) }
    }

    func testResponsesSurviveEncoding() throws {
        let task = makeTask("a")
        let responses: [AgentResponse] = [
            .ok, .tasks([task]), .error(.versionMismatch(agent: 1, client: 2)), .error(.unknownTask),
            .status(AgentStatus(
                globalPause: true, stateRecovered: false, taskLoadError: nil,
                tasks: [AgentTaskInfo(id: task.id, name: "a", state: .waiting(reason: "réseau"))]
            )),
        ]
        for response in responses {
            let data = try JSONEncoder().encode(AgentResponseEnvelope(version: 1, response: response))
            XCTAssertEqual(try JSONDecoder().decode(AgentResponseEnvelope.self, from: data).response, response)
        }
    }

    func decode(_ data: Data) throws -> AgentResponseEnvelope {
        try JSONDecoder().decode(AgentResponseEnvelope.self, from: data)
    }

    func encode(version: Int, _ request: AgentRequest) throws -> Data {
        try JSONEncoder().encode(AgentRequestEnvelope(version: version, request: request))
    }

    func testRouterAnswersStatusAndCommands() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()

        let status = try decode(await AgentRouter.handle(encode(version: 1, .status), core: core))
        guard case .status(let info) = status.response else { return XCTFail("attendu : status") }
        XCTAssertEqual(info.tasks.map(\.name), ["tâche"])
        XCTAssertEqual(status.version, agentProtocolVersion)

        let ran = try decode(await AgentRouter.handle(encode(version: 1, .runNow(task.id)), core: core))
        XCTAssertEqual(ran.response, .ok)
        await core.waitForIdle()
        let history = try decode(await AgentRouter.handle(encode(version: 1, .history(taskID: task.id, limit: 5)), core: core))
        guard case .history(let records) = history.response else { return XCTFail("attendu : history") }
        XCTAssertEqual(records.map(\.status), [.succeeded])
    }

    func testRouterMapsAgentErrors() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let reply = try decode(await AgentRouter.handle(encode(version: 1, .pause(UUID())), core: core))
        XCTAssertEqual(reply.response, .error(.notRunning))
    }

    func testRouterRejectsAnotherProtocolVersionWithoutReadingTheRequest() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        let futureRequest = Data(#"{"version":99,"request":{"quelqueChoseDeNouveau":{}}}"#.utf8)
        let reply = try decode(await AgentRouter.handle(futureRequest, core: core))
        XCTAssertEqual(reply.response, .error(.versionMismatch(agent: agentProtocolVersion, client: 99)))
    }

    func testRouterRejectsGarbage() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        let reply = try decode(await AgentRouter.handle(Data("pas du json".utf8), core: core))
        guard case .error(.internalFailure) = reply.response else { return XCTFail("attendu : erreur interne") }
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter AgentProtocolTests 2>&1 | tail -8`
Attendu : erreur de compilation.

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/Agent/AgentProtocol.swift` :

```swift
import Foundation

/// Numéro du contrat XPC. À incrémenter quand un message change de forme.
public let agentProtocolVersion = 1

public enum AgentIdentifiers {
    /// Nom du service Mach déclaré dans le plist de l'agent.
    public static let machService = "com.sylvain.syncmacpro.agent"
    public static let launchdLabel = machService
    public static let bundleIdentifier = "com.sylvain.syncmacpro"
}

public enum AgentRequest: Codable, Equatable, Sendable {
    case status
    case listTasks
    case history(taskID: UUID?, limit: Int)
    case runNow(UUID)
    case pause(UUID)
    case resume(UUID)
    case stop(UUID)
    case setGlobalPause(Bool)
    case approveDeletion(UUID)
    case reloadTasks
}

public enum AgentResponse: Codable, Equatable, Sendable {
    case ok
    case status(AgentStatus)
    case tasks([SyncTask])
    case history([RunRecord])
    case error(AgentError)
}

public struct AgentRequestEnvelope: Codable, Sendable {
    public var version: Int
    public var request: AgentRequest

    public init(version: Int = agentProtocolVersion, request: AgentRequest) {
        self.version = version
        self.request = request
    }
}

public struct AgentResponseEnvelope: Codable, Sendable {
    public var version: Int
    public var response: AgentResponse

    public init(version: Int = agentProtocolVersion, response: AgentResponse) {
        self.version = version
        self.response = response
    }
}

/// Ce que l'agent expose. Les messages sont du JSON (`Data`) pour rester évolutifs.
@objc public protocol AgentXPCProtocol {
    func request(_ data: Data, reply: @escaping (Data) -> Void)
    /// Le client donne un objet qui recevra les événements (avancement, début, fin).
    func subscribe(_ observer: AgentObserverXPC, reply: @escaping () -> Void)
}

@objc public protocol AgentObserverXPC {
    /// `AgentEvent` encodé en JSON.
    func event(_ data: Data)
}

public enum AgentXPC {
    public static func makeInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: AgentXPCProtocol.self)
        interface.setInterface(
            NSXPCInterface(with: AgentObserverXPC.self),
            for: #selector(AgentXPCProtocol.subscribe(_:reply:)), argumentIndex: 0, ofReply: false
        )
        return interface
    }
}
```

`Sources/SyncKit/Agent/AgentRouter.swift` :

```swift
import Foundation

/// Traduit une requête XPC en appel à `AgentCore`. Séparé du transport pour être testable sans XPC.
public enum AgentRouter {
    private struct VersionProbe: Decodable { let version: Int }

    public static func handle(_ data: Data, core: AgentCore) async -> Data {
        reply(await response(for: data, core: core))
    }

    private static func response(for data: Data, core: AgentCore) async -> AgentResponse {
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return .error(.internalFailure("requête illisible"))
        }
        guard probe.version == agentProtocolVersion else {
            return .error(.versionMismatch(agent: agentProtocolVersion, client: probe.version))
        }
        guard let envelope = try? JSONDecoder().decode(AgentRequestEnvelope.self, from: data) else {
            return .error(.internalFailure("requête illisible"))
        }
        do {
            switch envelope.request {
            case .status: return .status(await core.status())
            case .listTasks: return .tasks(await core.listTasks())
            case .history(let id, let limit): return .history(try await core.runHistory(taskID: id, limit: limit))
            case .runNow(let id): try await core.runNow(id)
            case .pause(let id): try await core.pause(id)
            case .resume(let id): try await core.resume(id)
            case .stop(let id): try await core.stop(id)
            case .setGlobalPause(let paused): await core.setGlobalPause(paused)
            case .approveDeletion(let id): try await core.approveDeletion(id)
            case .reloadTasks: await core.reloadTasks()
            }
            return .ok
        } catch let error as AgentError {
            return .error(error)
        } catch {
            return .error(.internalFailure("\(error)"))
        }
    }

    private static func reply(_ response: AgentResponse) -> Data {
        let envelope = AgentResponseEnvelope(response: response)
        return (try? JSONEncoder().encode(envelope))
            ?? Data(#"{"version":1,"response":{"error":{"internalFailure":{"_0":"réponse non encodable"}}}}"#.utf8)
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter AgentProtocolTests 2>&1 | tail -8`
Attendu : 6 tests passent.

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncKit/Agent/AgentProtocol.swift Sources/SyncKit/Agent/AgentRouter.swift Tests/SyncKitTests/AgentProtocolTests.swift
git commit -m "Contrat XPC versionné et routeur de requêtes" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 8 : serveur et client XPC

**Fichiers :**
- Créer : `Sources/SyncKit/Agent/AgentXPC.swift`
- Tester : `Tests/SyncKitTests/AgentXPCTests.swift`

**Interfaces :**
- Consomme : tâche 7 (dont `AgentIdentifiers`).
- Produit :
  - `final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate` — `init(core:codeSigningRequirement: String? = nil)` ; refuse tout client d'un autre utilisateur ; applique l'exigence de signature si elle est fournie.
  - `enum AgentClientError: Error, LocalizedError, Equatable { unreachable, badReply, agent(AgentError) }`
  - `final class AgentClient` — `init(timeout: TimeInterval = 20, connectionFactory:)`, `static machService(_:timeout:)`, `send(_:) async throws -> AgentResponse` (convertit `.error` en `AgentClientError.agent`, détecte une version différente), `status()`, `listTasks()`, `history(taskID:limit:)`, `perform(_:)`, `watch(_:) async throws -> AgentWatch` ; `AgentWatch.cancel()`.

Les tests utilisent un `NSXPCListener.anonymous()` : le vrai XPC, sans launchd. (Un service Mach nommé exige launchd — voir « Décisions ».)

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncKitTests/AgentXPCTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentXPCTests: XCTestCase {
    struct Server {
        let client: AgentClient
        let core: AgentCore
        let listener: NSXPCListener
        let delegate: AgentListenerDelegate
    }

    func makeServer(_ h: AgentHarness, timeout: TimeInterval = 5) async -> Server {
        let core = h.makeCore()
        await core.start()
        let delegate = AgentListenerDelegate(core: core)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        let client = AgentClient(timeout: timeout) { NSXPCConnection(listenerEndpoint: endpoint) }
        return Server(client: client, core: core, listener: listener, delegate: delegate)
    }

    func testStatusAndTaskListGoThroughXPC() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        try h.save([makeTask("alpha", schedule: .manual)])
        let server = await makeServer(h)
        let status = try await server.client.status()
        XCTAssertEqual(status.tasks.map(\.name), ["alpha"])
        let tasks = try await server.client.listTasks()
        XCTAssertEqual(tasks.map(\.name), ["alpha"])
        withExtendedLifetime(server) {}
    }

    func testCommandsAndHistoryGoThroughXPC() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let server = await makeServer(h)
        try await server.client.perform(.runNow(task.id))
        await server.core.waitForIdle()
        let records = try await server.client.history(taskID: task.id, limit: 5)
        XCTAssertEqual(records.map(\.status), [.succeeded])
        withExtendedLifetime(server) {}
    }

    func testAgentErrorsComeBackAsClientErrors() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let server = await makeServer(h)
        do {
            try await server.client.perform(.pause(UUID()))
            XCTFail("une erreur était attendue")
        } catch {
            XCTAssertEqual(error as? AgentClientError, .agent(.notRunning))
        }
        withExtendedLifetime(server) {}
    }

    func testWatcherReceivesEvents() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let server = await makeServer(h)
        let events = Locked<[AgentEvent]>([])
        let watch = try await server.client.watch { events.set(events.get() + [$0]) }
        try await server.client.perform(.runNow(task.id))
        let done = await eventually {
            events.get().contains { if case .taskFinished(task.id, .succeeded, _) = $0 { return true } else { return false } }
        }
        XCTAssertTrue(done)
        XCTAssertTrue(events.get().contains(.taskStarted(task.id)))
        watch.cancel()
        withExtendedLifetime(server) {}
    }

    func testIncompatibleVersionIsReportedClearly() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let server = await makeServer(h)
        let raw = Data(#"{"version":99,"request":"status"}"#.utf8)
        let reply = try await server.client.sendRaw(raw)
        let envelope = try JSONDecoder().decode(AgentResponseEnvelope.self, from: reply)
        XCTAssertEqual(envelope.response, .error(.versionMismatch(agent: agentProtocolVersion, client: 99)))
        withExtendedLifetime(server) {}
    }

    func testAbsentAgentIsReportedAsUnreachable() async {
        let client = AgentClient(timeout: 2) { NSXPCConnection(machServiceName: "com.sylvain.syncmacpro.tests.absent") }
        do {
            _ = try await client.status()
            XCTFail("une erreur était attendue")
        } catch {
            XCTAssertEqual(error as? AgentClientError, .unreachable)
        }
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter AgentXPCTests 2>&1 | tail -8`
Attendu : erreur de compilation.

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/Agent/AgentXPC.swift` :

```swift
import Darwin
import Foundation

// MARK: serveur

/// Un objet par connexion : traduit les appels XPC et retire ses observateurs à la fermeture.
final class AgentConnectionHandler: NSObject, AgentXPCProtocol, @unchecked Sendable {
    private let core: AgentCore
    private let tokens = Locked<[UUID]>([])

    init(core: AgentCore) { self.core = core }

    func request(_ data: Data, reply: @escaping (Data) -> Void) {
        let core = self.core
        Task { reply(await AgentRouter.handle(data, core: core)) }
    }

    func subscribe(_ observer: AgentObserverXPC, reply: @escaping () -> Void) {
        let core = self.core
        Task {
            let token = await core.addObserver { event in
                if let data = try? JSONEncoder().encode(event) { observer.event(data) }
            }
            tokens.set(tokens.get() + [token])
            reply()
        }
    }

    func tearDown() {
        let pending = tokens.get()
        tokens.set([])
        let core = self.core
        Task { for token in pending { await core.removeObserver(token) } }
    }
}

public final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let core: AgentCore
    private let requirement: String?

    /// `codeSigningRequirement` : exigence de signature du client (app signée avec une équipe) ;
    /// `nil` en signature ad hoc, où l'on se limite au même utilisateur.
    public init(core: AgentCore, codeSigningRequirement: String? = nil) {
        self.core = core
        requirement = codeSigningRequirement
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        if let requirement { connection.setCodeSigningRequirement(requirement) }
        let handler = AgentConnectionHandler(core: core)
        connection.exportedInterface = AgentXPC.makeInterface()
        connection.exportedObject = handler
        connection.remoteObjectInterface = NSXPCInterface(with: AgentObserverXPC.self)
        connection.invalidationHandler = { handler.tearDown() }
        connection.resume()
        return true
    }
}

// MARK: client

public enum AgentClientError: Error, LocalizedError, Equatable {
    /// L'agent ne répond pas (non installé, arrêté, ou pas encore relancé par launchd).
    case unreachable
    case badReply
    case agent(AgentError)

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            return "L'agent ne répond pas. Installez-le avec « syncmacpro-ctl agent install » ou attendez quelques secondes."
        case .badReply: return "Réponse de l'agent illisible."
        case .agent(let error): return error.errorDescription
        }
    }
}

/// Résultat unique d'un appel XPC : réponse, erreur de connexion ou délai écoulé, au premier arrivé.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

final class ClientObserver: NSObject, AgentObserverXPC, @unchecked Sendable {
    private let handler: @Sendable (AgentEvent) -> Void

    init(_ handler: @escaping @Sendable (AgentEvent) -> Void) { self.handler = handler }

    func event(_ data: Data) {
        if let event = try? JSONDecoder().decode(AgentEvent.self, from: data) { handler(event) }
    }
}

public final class AgentWatch: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let observer: ClientObserver

    init(connection: NSXPCConnection, observer: ClientObserver) {
        self.connection = connection
        self.observer = observer
    }

    public func cancel() { connection.invalidate() }
}

public final class AgentClient: @unchecked Sendable {
    public typealias ConnectionFactory = @Sendable () -> NSXPCConnection

    private let factory: ConnectionFactory
    private let timeout: TimeInterval

    /// `timeout` : après un arrêt brutal, launchd met environ 10 s à relancer l'agent ; 20 s laissent la marge.
    public init(timeout: TimeInterval = 20, connectionFactory: @escaping ConnectionFactory) {
        self.timeout = timeout
        factory = connectionFactory
    }

    public static func machService(_ name: String = AgentIdentifiers.machService, timeout: TimeInterval = 20) -> AgentClient {
        AgentClient(timeout: timeout) { NSXPCConnection(machServiceName: name) }
    }

    // MARK: appels

    public func send(_ request: AgentRequest) async throws -> AgentResponse {
        let payload = try JSONEncoder().encode(AgentRequestEnvelope(request: request))
        let reply = try await sendRaw(payload)
        struct Probe: Decodable { let version: Int }
        if let probe = try? JSONDecoder().decode(Probe.self, from: reply), probe.version != agentProtocolVersion {
            throw AgentClientError.agent(.versionMismatch(agent: probe.version, client: agentProtocolVersion))
        }
        guard let envelope = try? JSONDecoder().decode(AgentResponseEnvelope.self, from: reply) else {
            throw AgentClientError.badReply
        }
        if case .error(let error) = envelope.response { throw AgentClientError.agent(error) }
        return envelope.response
    }

    func sendRaw(_ data: Data) async throws -> Data {
        let connection = factory()
        connection.remoteObjectInterface = AgentXPC.makeInterface()
        connection.resume()
        defer { connection.invalidate() }
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
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
            proxy.request(data) { reply in
                timer.cancel()
                shot.finish(.success(reply))
            }
        }
    }

    public func status() async throws -> AgentStatus {
        guard case .status(let status) = try await send(.status) else { throw AgentClientError.badReply }
        return status
    }

    public func listTasks() async throws -> [SyncTask] {
        guard case .tasks(let tasks) = try await send(.listTasks) else { throw AgentClientError.badReply }
        return tasks
    }

    public func history(taskID: UUID?, limit: Int) async throws -> [RunRecord] {
        guard case .history(let records) = try await send(.history(taskID: taskID, limit: limit)) else {
            throw AgentClientError.badReply
        }
        return records
    }

    /// Commande sans résultat (lancer, pause, reprise, arrêt, pause globale, validation, rechargement).
    public func perform(_ request: AgentRequest) async throws {
        _ = try await send(request)
    }

    /// Reçoit les événements de l'agent jusqu'à `cancel()` ou à la fermeture de l'agent.
    public func watch(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentWatch {
        let connection = factory()
        let observer = ClientObserver(onEvent)
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
            connection.invalidate()
            throw error
        }
        return AgentWatch(connection: connection, observer: observer)
    }
}
```

- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter AgentXPCTests 2>&1 | tail -12`
Attendu : tous passent. Si un test se bloque, la cause probable est un `reply` jamais appelé : vérifier que `AgentConnectionHandler.request` rappelle bien `reply` pour chaque requête.

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncKit/Agent Tests/SyncKitTests/AgentXPCTests.swift
git commit -m "Serveur et client XPC (écouteur, observateurs, version, délai de 20 s)" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 9 : chemins, conditions réelles, notifications, anti-veille, signature

**Fichiers :**
- Créer : `Sources/SyncKit/Agent/AgentPaths.swift`, `Sources/SyncKit/Agent/System/MacSystemConditions.swift`, `Sources/SyncKit/Agent/System/UserNotifier.swift`, `Sources/SyncKit/Agent/System/SleepActivity.swift`, `Sources/SyncKit/Agent/System/CodeSigning.swift`
- Tester : `Tests/SyncKitTests/AgentSystemTests.swift`

**Interfaces :**
- Produit : `AgentPaths(root:)` avec `tasks`, `state`, `history`, `work`, `standard`, `development` ; `MacSystemConditions: SystemConditions` ; `UserNotifier: AgentNotifier` ; `SleepActivity: ActivityHolding` ; `CodeSigning.ownTeamIdentifier()`, `CodeSigning.requirement(forTeam:)`.

- [ ] **Étape 1 : écrire les tests qui échouent**

```swift
import XCTest
@testable import SyncKit

final class AgentSystemTests: IntegrationTestCase {
    func testPathsLiveUnderTheRoot() {
        let paths = AgentPaths(root: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertEqual(paths.tasks.path, "/tmp/x/tasks.json")
        XCTAssertEqual(paths.state.path, "/tmp/x/scheduler-state.json")
        XCTAssertEqual(paths.history.path, "/tmp/x/history.sqlite")
        XCTAssertTrue(AgentPaths.standard.root.path.hasSuffix("Application Support/SyncMacPro"))
        XCTAssertTrue(AgentPaths.development.root.path.hasSuffix("Application Support/SyncMacPro-dev"))
    }

    func testReachabilityOfLocalFolders() throws {
        let conditions = MacSystemConditions()
        let folder = try folder("present")
        let file = try write(sandbox.appendingPathComponent("fichier.txt").path, "x")
        XCTAssertTrue(conditions.isReachable(.local(path: folder)))
        XCTAssertFalse(conditions.isReachable(.local(path: sandbox.appendingPathComponent("absent").path)))
        XCTAssertFalse(conditions.isReachable(.local(path: file)), "un fichier n'est pas un dossier")
        XCTAssertTrue(conditions.isReachable(.network(url: "smb://nas/partage", mountPath: folder)))
        XCTAssertFalse(conditions.isReachable(.network(url: "smb://nas/partage", mountPath: sandbox.appendingPathComponent("démonté").path)))
    }

    func testPowerAndNetworkQueriesDoNotCrash() {
        let conditions = MacSystemConditions()
        _ = conditions.isOnACPower()
        _ = conditions.isNetworkAvailable()
    }

    func testSleepActivityIsIdempotent() {
        let activity = SleepActivity()
        activity.begin(); activity.begin(); activity.end(); activity.end()
    }

    func testSigningRequirementNamesTheTeam() {
        XCTAssertEqual(
            CodeSigning.requirement(forTeam: "ABCDE12345"),
            #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#
        )
        _ = CodeSigning.ownTeamIdentifier()   // nil pour un binaire ad hoc : ne doit pas planter
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter AgentSystemTests 2>&1 | tail -8`
Attendu : erreur de compilation.

- [ ] **Étape 3 : implémenter**

`Sources/SyncKit/Agent/AgentPaths.swift` :

```swift
import Foundation

/// Où l'agent range ses données.
public struct AgentPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var tasks: URL { root.appendingPathComponent("tasks.json") }
    public var state: URL { root.appendingPathComponent("scheduler-state.json") }
    public var history: URL { root.appendingPathComponent("history.sqlite") }
    /// Dossier d'état propre aux tâches (bisync y garde ses listes).
    public var work: URL { root.appendingPathComponent("work") }

    private static func support(_ name: String) -> AgentPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AgentPaths(root: base.appendingPathComponent(name))
    }

    public static var standard: AgentPaths { support("SyncMacPro") }
    /// Pour le développement : ne touche pas aux données réelles.
    public static var development: AgentPaths { support("SyncMacPro-dev") }
}
```

`Sources/SyncKit/Agent/System/MacSystemConditions.swift` :

```swift
import Foundation
import IOKit.ps
import Network

/// Conditions réelles du Mac : secteur, réseau, dossiers et volumes présents.
public final class MacSystemConditions: SystemConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    /// Optimiste tant que le moniteur n'a rien dit : mieux vaut tenter qu'attendre indéfiniment.
    private let networkUp = Locked(true)

    public init() {
        let flag = networkUp
        monitor.pathUpdateHandler = { path in flag.set(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "syncmacpro.network"))
    }

    deinit { monitor.cancel() }

    /// Un Mac de bureau (sans batterie) est toujours « sur secteur ».
    public func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPSACPowerValue
    }

    public func isNetworkAvailable() -> Bool { networkUp.get() }

    public func isReachable(_ endpoint: Endpoint) -> Bool {
        guard let path = endpoint.filesystemPath else { return isNetworkAvailable() }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
```

`Sources/SyncKit/Agent/System/UserNotifier.swift` :

```swift
import Foundation
import UserNotifications

/// Notifications macOS. Elles exigent que l'agent appartienne à un bundle d'app ; sinon (outil lancé à la main),
/// le message part sur la sortie d'erreur.
public final class UserNotifier: AgentNotifier, @unchecked Sendable {
    private let fallback: @Sendable (String) -> Void

    public init(fallback: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.fallback = fallback
    }

    public func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            fallback("\(title) — \(body)")
            return
        }
        let center = UNUserNotificationCenter.current()
        let fallback = self.fallback
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                fallback("\(title) — \(body)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
```

`Sources/SyncKit/Agent/System/SleepActivity.swift` :

```swift
import Foundation

/// Empêche la mise en veille du Mac tant qu'une copie tourne.
public final class SleepActivity: ActivityHolding, @unchecked Sendable {
    private let token = Locked<NSObjectProtocol?>(nil)

    public init() {}

    public func begin() {
        guard token.get() == nil else { return }
        token.set(ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled], reason: "Synchronisation en cours"
        ))
    }

    public func end() {
        guard let current = token.get() else { return }
        ProcessInfo.processInfo.endActivity(current)
        token.set(nil)
    }
}
```

`Sources/SyncKit/Agent/System/CodeSigning.swift` :

```swift
import Foundation
import Security

public enum CodeSigning {
    /// Identifiant d'équipe de ce programme ; `nil` en signature ad hoc (pas de compte développeur).
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess, let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Exigence à imposer au client XPC : signé par la même équipe.
    public static func requirement(forTeam team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
```


- [ ] **Étape 4 : vérifier**

Exécuter : `swift test --filter AgentSystemTests 2>&1 | tail -8` puis `swift build 2>&1 | tail -3`
Attendu : 5 tests passent ; compilation sans erreur.

- [ ] **Étape 5 : commit**

```bash
git add Sources/SyncKit/Agent Tests/SyncKitTests/AgentSystemTests.swift
git commit -m "Intégrations système : conditions réelles, notifications, anti-veille, signature, chemins" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 10 : outil `syncmacpro-ctl`

**Fichiers :**
- Créer : `Sources/SyncKit/Agent/CtlParser.swift`, `Sources/SyncKit/Agent/CtlSupport.swift`, `Sources/syncmacpro-ctl/main.swift`, `Sources/syncmacpro-ctl/AgentRegistration.swift`
- Modifier : `Package.swift`
- Tester : `Tests/SyncKitTests/CtlTests.swift`

**Interfaces :**
- Consomme : `AgentClient`, `AgentPaths`, `TaskStore`.
- Produit : `CtlCommand`, `NewTask`, `CtlInvocation`, `CtlParseError`, `CtlParser.parse(_:)`, `CtlParser.usage` ; `TaskReference.resolve(_:in:)`, `TaskReferenceError` ; `CtlFormatter` (`statusLines`, `taskLines`, `historyLines`, `eventLine`, `scheduleDescription`, `stateLabel`, `json`).

Commandes : `status`, `list`, `run|pause|resume|stop|approve <tâche>`, `pause-all`, `resume-all`, `history [<tâche>] [--limit N]`, `watch`, `add --name N --source P --dest P [--mode M] [--every MIN | --daily HH:MM] [--ac-power]`, `remove <tâche>`, `agent install|uninstall|status`. Options globales : `--json`, `--state-dir DOSSIER`, `--service NOM`. Alias français : `statut`, `liste`, `lancer`, `reprendre`, `arreter`, `historique`, `valider`, `pause-tout`, `reprendre-tout`, `ajouter`, `supprimer`, `aide`.
Codes de sortie : 0 succès, 1 erreur, 64 usage incorrect, 69 agent injoignable.

- [ ] **Étape 1 : écrire les tests qui échouent**

`Tests/SyncKitTests/CtlTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class CtlParserTests: XCTestCase {
    func parse(_ arguments: String...) throws -> CtlInvocation { try CtlParser.parse(arguments) }

    func testSimpleCommandsAndGlobalOptionsAnywhere() throws {
        let invocation = try parse("--json", "status", "--state-dir", "/tmp/x", "--service", "svc")
        XCTAssertEqual(invocation.command, .status)
        XCTAssertTrue(invocation.json)
        XCTAssertEqual(invocation.stateDirectory, "/tmp/x")
        XCTAssertEqual(invocation.service, "svc")
    }

    func testFrenchAliases() throws {
        XCTAssertEqual(try parse("statut").command, .status)
        XCTAssertEqual(try parse("liste").command, .list)
        XCTAssertEqual(try parse("lancer", "nuit").command, .run("nuit"))
        XCTAssertEqual(try parse("reprendre", "nuit").command, .resume("nuit"))
        XCTAssertEqual(try parse("arreter", "nuit").command, .stop("nuit"))
        XCTAssertEqual(try parse("valider", "nuit").command, .approve("nuit"))
        XCTAssertEqual(try parse("pause-tout").command, .pauseAll)
        XCTAssertEqual(try parse("reprendre-tout").command, .resumeAll)
        XCTAssertEqual(try parse("aide").command, .help)
    }

    func testTaskCommandsNeedATask() {
        XCTAssertThrowsError(try parse("run")) { XCTAssertEqual($0 as? CtlParseError, .missingValue("tâche")) }
        XCTAssertThrowsError(try parse("pause"))
    }

    func testHistoryTakesAnOptionalTaskAndLimit() throws {
        XCTAssertEqual(try parse("history").command, .history(nil, limit: 20))
        XCTAssertEqual(try parse("history", "nuit", "--limit", "5").command, .history("nuit", limit: 5))
    }

    func testAgentSubcommands() throws {
        XCTAssertEqual(try parse("agent", "install").command, .agentInstall)
        XCTAssertEqual(try parse("agent", "uninstall").command, .agentUninstall)
        XCTAssertEqual(try parse("agent", "status").command, .agentStatus)
        XCTAssertThrowsError(try parse("agent"))
        XCTAssertThrowsError(try parse("agent", "danser"))
    }

    func testAddBuildsATask() throws {
        let invocation = try parse(
            "add", "--name", "Nuit", "--source", "/a", "--dest", "/b", "--mode", "mirror", "--daily", "03:30", "--ac-power"
        )
        guard case .add(let task) = invocation.command else { return XCTFail("attendu : add") }
        XCTAssertEqual(task.name, "Nuit")
        XCTAssertEqual(task.source, .local(path: "/a"))
        XCTAssertEqual(task.destination, .local(path: "/b"))
        XCTAssertEqual(task.mode, .mirror)
        XCTAssertEqual(task.schedule, .daily(hour: 3, minute: 30))
        XCTAssertTrue(task.requiresACPower)
    }

    func testAddParsesCloudEndpointsAndIntervals() throws {
        let invocation = try parse("add", "--name", "n", "--source", "/a", "--dest", "drive:Sauvegardes/NAS", "--every", "15")
        guard case .add(let task) = invocation.command else { return XCTFail("attendu : add") }
        XCTAssertEqual(task.destination, .cloud(remote: "drive", path: "Sauvegardes/NAS"))
        XCTAssertEqual(task.schedule, .everyMinutes(15))
    }

    func testAddRejectsInvalidInput() {
        XCTAssertThrowsError(try parse("add", "--name", "n", "--source", "/a"))
        XCTAssertThrowsError(try parse("add", "--name", "n", "--source", "/a", "--dest", "/b", "--daily", "25:99"))
        XCTAssertThrowsError(try parse("add", "--name", "n", "--source", "/a", "--dest", "/b", "--every", "5", "--daily", "03:00"))
        XCTAssertThrowsError(try parse("add", "--name", "n", "--source", "/a", "--dest", "/b", "--mode", "inconnu"))
    }

    func testUnknownCommandAndOption() {
        XCTAssertThrowsError(try parse("danser")) { XCTAssertEqual($0 as? CtlParseError, .unknownCommand("danser")) }
        XCTAssertThrowsError(try parse("status", "--bizarre"))
        XCTAssertThrowsError(try CtlParser.parse([])) { XCTAssertEqual($0 as? CtlParseError, .missingCommand) }
    }
}

final class TaskReferenceTests: XCTestCase {
    let tasks = [makeTask("Archives NAS"), makeTask("Archives Drive"), makeTask("Photos")]

    func testExactNameIgnoringCase() throws {
        XCTAssertEqual(try TaskReference.resolve("photos", in: tasks).name, "Photos")
    }

    func testUniquePrefix() throws {
        XCTAssertEqual(try TaskReference.resolve("pho", in: tasks).name, "Photos")
    }

    func testAmbiguousPrefix() {
        XCTAssertThrowsError(try TaskReference.resolve("arch", in: tasks)) {
            guard case .ambiguous = $0 as? TaskReferenceError else { return XCTFail("attendu : ambiguë") }
        }
    }

    func testNotFound() {
        XCTAssertThrowsError(try TaskReference.resolve("zzz", in: tasks)) {
            XCTAssertEqual($0 as? TaskReferenceError, .notFound("zzz"))
        }
    }

    func testByFullIdentifierAndIdentifierPrefix() throws {
        let id = tasks[2].id.uuidString
        XCTAssertEqual(try TaskReference.resolve(id, in: tasks).name, "Photos")
        XCTAssertEqual(try TaskReference.resolve(String(id.prefix(8)), in: tasks).name, "Photos")
    }
}

final class CtlFormatterTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testScheduleDescriptions() {
        XCTAssertEqual(CtlFormatter.scheduleDescription(.manual), "manuelle")
        XCTAssertEqual(CtlFormatter.scheduleDescription(.daily(hour: 3, minute: 5)), "tous les jours à 03:05")
        XCTAssertEqual(CtlFormatter.scheduleDescription(.everyMinutes(15)), "toutes les 15 min")
        XCTAssertEqual(CtlFormatter.scheduleDescription(.weekdays(days: [2, 6], hour: 8, minute: 0)), "lun, ven à 08:00")
        XCTAssertEqual(CtlFormatter.scheduleDescription(.whenAvailable), "dès que disponible")
    }

    func testStatusShowsPauseWarningsAndTasks() {
        let task = makeTask("Nuit")
        let record = RunRecord(
            taskID: task.id, taskName: "Nuit", engine: .rsync, mode: .copy,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000), status: .succeeded
        )
        let status = AgentStatus(
            globalPause: true, stateRecovered: true, taskLoadError: "boum",
            tasks: [AgentTaskInfo(
                id: task.id, name: "Nuit", state: .waiting(reason: "réseau indisponible"),
                nextDue: Date(timeIntervalSince1970: 1_760_086_400), lastRun: record
            )]
        )
        let text = CtlFormatter.statusLines(status, timeZone: utc).joined(separator: "\n")
        XCTAssertTrue(text.contains("Pause globale : oui"))
        XCTAssertTrue(text.contains("illisible"))
        XCTAssertTrue(text.contains("boum"))
        XCTAssertTrue(text.contains("Nuit"))
        XCTAssertTrue(text.contains("en attente (réseau indisponible)"))
        XCTAssertTrue(text.contains("réussie"))
    }

    func testEventLines() {
        let id = UUID()
        let names = [id: "Nuit"]
        XCTAssertEqual(CtlFormatter.eventLine(.taskStarted(id), names: names), "▶ Nuit démarre")
        XCTAssertEqual(CtlFormatter.eventLine(.taskFinished(id, .failed, "disque plein"), names: names), "■ Nuit : échec — disque plein")
        XCTAssertNotNil(CtlFormatter.eventLine(.stateChanged, names: names))
    }

    func testJSONOutputIsStable() {
        let text = CtlFormatter.json(AgentTaskInfo(id: UUID(), name: "a", state: .idle))
        XCTAssertTrue(text.contains("\"name\" : \"a\""))
    }
}
```

- [ ] **Étape 2 : vérifier l'échec**

Exécuter : `swift test --filter "CtlParserTests|TaskReferenceTests|CtlFormatterTests" 2>&1 | tail -8`
Attendu : erreur de compilation.

- [ ] **Étape 3 : implémenter l'analyse et l'affichage**

`Sources/SyncKit/Agent/CtlParser.swift` :

```swift
import Foundation

public struct NewTask: Equatable, Sendable {
    public var name: String
    public var source: Endpoint
    public var destination: Endpoint
    public var mode: SyncMode
    public var schedule: Schedule
    public var requiresACPower: Bool
}

public enum CtlCommand: Equatable, Sendable {
    case status, list, watch, help
    case run(String), pause(String), resume(String), stop(String), approve(String), remove(String)
    case pauseAll, resumeAll
    case history(String?, limit: Int)
    case add(NewTask)
    case agentInstall, agentUninstall, agentStatus
}

public struct CtlInvocation: Equatable, Sendable {
    public var command: CtlCommand
    public var json: Bool
    public var stateDirectory: String?
    public var service: String?
}

public enum CtlParseError: Error, Equatable, LocalizedError {
    case missingCommand
    case unknownCommand(String)
    case missingValue(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .missingCommand: return "Commande attendue.\n\n" + CtlParser.usage
        case .unknownCommand(let name): return "Commande inconnue : \(name).\n\n" + CtlParser.usage
        case .missingValue(let what): return "Valeur manquante : \(what)."
        case .invalid(let message): return message
        }
    }
}

public enum CtlParser {
    public static let usage = """
    Usage : syncmacpro-ctl <commande> [options]

      status                         état de l'agent et des tâches
      list                           liste des tâches
      run | pause | resume | stop <tâche>
      approve <tâche>                accepte les suppressions qui ont bloqué la tâche
      pause-all | resume-all         pause globale (conservée après un redémarrage)
      history [<tâche>] [--limit N]  dernières exécutions
      watch                          avancement en direct
      add --name N --source P --dest P [--mode copy|mirror|bidirectional|move|versioned|verify]
          [--every MINUTES | --daily HH:MM] [--ac-power]
      remove <tâche>
      agent install | uninstall | status

    Options : --json   --state-dir DOSSIER   --service NOM
    Une tâche se désigne par son nom (ou un début de nom) ou par son identifiant.
    """

    private static let aliases: [String: String] = [
        "statut": "status", "liste": "list", "lancer": "run", "reprendre": "resume", "arreter": "stop",
        "arrêter": "stop", "historique": "history", "valider": "approve", "pause-tout": "pause-all",
        "reprendre-tout": "resume-all", "ajouter": "add", "supprimer": "remove", "aide": "help",
    ]

    private static let valued: Set<String> = [
        "state-dir", "service", "name", "source", "dest", "mode", "every", "daily", "limit",
    ]
    private static let flags: Set<String> = ["json", "ac-power", "help"]

    public static func parse(_ arguments: [String]) throws -> CtlInvocation {
        var json = false
        var stateDirectory: String?
        var service: String?
        var positional: [String] = []
        var values: [String: String] = [:]
        var flagged: Set<String> = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "-h" { flagged.insert("help"); continue }
            guard argument.hasPrefix("--") else { positional.append(argument); continue }
            let name = String(argument.dropFirst(2))
            if flags.contains(name) {
                flagged.insert(name)
            } else if valued.contains(name) {
                guard index < arguments.count else { throw CtlParseError.missingValue("--\(name)") }
                values[name] = arguments[index]
                index += 1
            } else {
                throw CtlParseError.invalid("Option inconnue : --\(name)")
            }
        }
        json = flagged.contains("json")
        stateDirectory = values["state-dir"]
        service = values["service"]
        func invocation(_ command: CtlCommand) -> CtlInvocation {
            CtlInvocation(command: command, json: json, stateDirectory: stateDirectory, service: service)
        }
        if flagged.contains("help") { return invocation(.help) }

        guard let first = positional.first else { throw CtlParseError.missingCommand }
        let name = aliases[first] ?? first
        let rest = Array(positional.dropFirst())

        func single() throws -> String {
            guard let value = rest.first else { throw CtlParseError.missingValue("tâche") }
            return value
        }

        switch name {
        case "status": return invocation(.status)
        case "list": return invocation(.list)
        case "watch": return invocation(.watch)
        case "help": return invocation(.help)
        case "pause-all": return invocation(.pauseAll)
        case "resume-all": return invocation(.resumeAll)
        case "run": return invocation(.run(try single()))
        case "pause": return invocation(.pause(try single()))
        case "resume": return invocation(.resume(try single()))
        case "stop": return invocation(.stop(try single()))
        case "approve": return invocation(.approve(try single()))
        case "remove": return invocation(.remove(try single()))
        case "history":
            let limit = try values["limit"].map { text -> Int in
                guard let value = Int(text), value > 0 else { throw CtlParseError.invalid("--limit attend un nombre positif") }
                return value
            } ?? 20
            return invocation(.history(rest.first, limit: limit))
        case "agent":
            switch rest.first {
            case "install": return invocation(.agentInstall)
            case "uninstall": return invocation(.agentUninstall)
            case "status": return invocation(.agentStatus)
            default: throw CtlParseError.invalid("agent attend : install, uninstall ou status")
            }
        case "add": return invocation(.add(try newTask(values, flagged)))
        default: throw CtlParseError.unknownCommand(first)
        }
    }

    private static func newTask(_ values: [String: String], _ flagged: Set<String>) throws -> NewTask {
        guard let name = values["name"] else { throw CtlParseError.missingValue("--name") }
        guard let source = values["source"] else { throw CtlParseError.missingValue("--source") }
        guard let destination = values["dest"] else { throw CtlParseError.missingValue("--dest") }
        let mode: SyncMode
        if let text = values["mode"] {
            guard let parsed = SyncMode(rawValue: text) else { throw CtlParseError.invalid("Mode inconnu : \(text)") }
            mode = parsed
        } else {
            mode = .copy
        }
        if values["every"] != nil && values["daily"] != nil {
            throw CtlParseError.invalid("--every et --daily s'excluent")
        }
        var schedule = Schedule.manual
        if let text = values["every"] {
            guard let minutes = Int(text), minutes > 0 else { throw CtlParseError.invalid("--every attend un nombre de minutes") }
            schedule = .everyMinutes(minutes)
        } else if let text = values["daily"] {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
                throw CtlParseError.invalid("--daily attend une heure HH:MM")
            }
            schedule = .daily(hour: parts[0], minute: parts[1])
        }
        return NewTask(
            name: name, source: endpoint(source), destination: endpoint(destination), mode: mode,
            schedule: schedule, requiresACPower: flagged.contains("ac-power")
        )
    }

    /// `remote:chemin` désigne un service en ligne ; tout le reste est un dossier local ou un volume monté.
    static func endpoint(_ text: String) -> Endpoint {
        if text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix(".") { return .local(path: (text as NSString).expandingTildeInPath) }
        if let colon = text.firstIndex(of: ":") {
            return .cloud(remote: String(text[..<colon]), path: String(text[text.index(after: colon)...]))
        }
        return .local(path: text)
    }
}
```

`Sources/SyncKit/Agent/CtlSupport.swift` :

```swift
import Foundation

public enum TaskReferenceError: Error, Equatable, LocalizedError {
    case notFound(String)
    case ambiguous(String, [String])

    public var errorDescription: String? {
        switch self {
        case .notFound(let text): return "Aucune tâche ne correspond à « \(text) »."
        case .ambiguous(let text, let names):
            return "« \(text) » correspond à plusieurs tâches : \(names.joined(separator: ", "))."
        }
    }
}

public enum TaskReference {
    /// Nom exact, début de nom, identifiant complet ou début d'identifiant (4 caractères au moins).
    public static func resolve(_ text: String, in tasks: [SyncTask]) throws -> SyncTask {
        let wanted = text.lowercased()
        if let byID = tasks.first(where: { $0.id.uuidString.lowercased() == wanted }) { return byID }
        let exact = tasks.filter { $0.name.lowercased() == wanted }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw TaskReferenceError.ambiguous(text, exact.map(\.name)) }
        let candidates = tasks.filter {
            $0.name.lowercased().hasPrefix(wanted) || (wanted.count >= 4 && $0.id.uuidString.lowercased().hasPrefix(wanted))
        }
        switch candidates.count {
        case 0: throw TaskReferenceError.notFound(text)
        case 1: return candidates[0]
        default: throw TaskReferenceError.ambiguous(text, candidates.map(\.name))
        }
    }
}

public enum CtlFormatter {
    static func date(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter.string(from: date)
    }

    public static func scheduleDescription(_ schedule: Schedule) -> String {
        func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
        switch schedule {
        case .manual: return "manuelle"
        case .whenAvailable: return "dès que disponible"
        case .everyMinutes(let minutes): return "toutes les \(minutes) min"
        case .daily(let hour, let minute): return "tous les jours à \(clock(hour, minute))"
        case .weekdays(let days, let hour, let minute):
            let names = ["dim", "lun", "mar", "mer", "jeu", "ven", "sam"]
            let list = days.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }
            return "\(list.joined(separator: ", ")) à \(clock(hour, minute))"
        }
    }

    public static func stateLabel(_ state: TaskRunState) -> String {
        switch state {
        case .idle: return "au repos"
        case .queued: return "en file"
        case .running: return "en cours"
        case .paused: return "en pause"
        case .waiting(let reason): return "en attente (\(reason))"
        case .awaitingApproval: return "validation requise"
        case .disabled: return "désactivée"
        }
    }

    public static func statusLabel(_ status: RunStatus) -> String {
        switch status {
        case .running: return "en cours"
        case .succeeded: return "réussie"
        case .failed: return "échec"
        case .blocked: return "bloquée"
        case .quotaReached: return "quota atteint"
        case .interrupted: return "interrompue"
        case .stopped: return "arrêtée"
        }
    }

    public static func statusLines(_ status: AgentStatus, timeZone: TimeZone = .current) -> [String] {
        var lines = ["Pause globale : \(status.globalPause ? "oui" : "non")"]
        if status.stateRecovered {
            lines.append("⚠︎ Le fichier d'état était illisible : l'agent est reparti en pause.")
        }
        if let error = status.taskLoadError {
            lines.append("⚠︎ tasks.json illisible (les tâches précédentes sont conservées) : \(error)")
        }
        for task in status.tasks {
            let next = task.nextDue.map { date($0, timeZone: timeZone) } ?? "—"
            let last = task.lastRun.map { "\(statusLabel($0.status)) \(date($0.startedAt, timeZone: timeZone))" } ?? "—"
            lines.append("• \(task.name)  [\(stateLabel(task.state))]  prochaine : \(next)  dernière : \(last)")
        }
        if status.tasks.isEmpty { lines.append("Aucune tâche.") }
        return lines
    }

    public static func taskLines(_ tasks: [SyncTask]) -> [String] {
        tasks.map { "• \($0.name)  [\($0.mode.rawValue)]  \(scheduleDescription($0.schedule))  \($0.id.uuidString.prefix(8))" }
    }

    public static func historyLines(_ records: [RunRecord], timeZone: TimeZone = .current) -> [String] {
        records.map { record in
            let message = record.summary?.message.map { " — \($0)" } ?? ""
            return "\(date(record.startedAt, timeZone: timeZone))  \(statusLabel(record.status).padding(toLength: 13, withPad: " ", startingAt: 0))  \(record.taskName)\(message)"
        }
    }

    public static func eventLine(_ event: AgentEvent, names: [UUID: String]) -> String? {
        switch event {
        case .taskStarted(let id): return "▶ \(names[id] ?? id.uuidString) démarre"
        case .taskFinished(let id, let status, let message):
            return "■ \(names[id] ?? id.uuidString) : \(statusLabel(status))" + (message.map { " — \($0)" } ?? "")
        case .progress(let id, let info):
            let percent = info.overallPercent.map { "\($0) %" } ?? "…"
            return "  \(names[id] ?? id.uuidString) : \(percent) \(info.currentName ?? "")"
        case .stateChanged: return "↻ état modifié"
        }
    }

    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "{}"
    }
}
```

- [ ] **Étape 4 : vérifier les tests**

Exécuter : `swift test --filter "CtlParserTests|TaskReferenceTests|CtlFormatterTests" 2>&1 | tail -12`
Attendu : tous passent.

- [ ] **Étape 5 : ajouter l'exécutable**

`Package.swift` : ajouter dans `products` `.executable(name: "syncmacpro-ctl", targets: ["syncmacpro-ctl"]),` et dans `targets` `.executableTarget(name: "syncmacpro-ctl", dependencies: ["SyncKit"]),`.

`Sources/syncmacpro-ctl/AgentRegistration.swift` :

```swift
import Foundation
import ServiceManagement
import SyncKit

/// Enregistrement de l'agent auprès de macOS. `SMAppService` n'agit que sur le bundle de l'appelant :
/// l'outil doit donc être lancé depuis `SyncMacPro.app/Contents/MacOS/` (voir scripts/make-dev-bundle.sh).
enum AgentRegistration {
    static let plistName = "\(AgentIdentifiers.launchdLabel).plist"

    private static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    private static func requireBundle() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw RegistrationError.notInBundle
        }
    }

    enum RegistrationError: Error, LocalizedError {
        case notInBundle

        var errorDescription: String? {
            "L'enregistrement de l'agent exige de lancer l'outil depuis l'app : "
                + "~/Applications/SyncMacPro.app/Contents/MacOS/syncmacpro-ctl (voir scripts/make-dev-bundle.sh)."
        }
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "installé et actif"
        case .requiresApproval:
            return "installé, mais à autoriser dans Réglages Système › Général › Éléments de connexion et extensions"
        case .notRegistered: return "non installé"
        case .notFound: return "introuvable dans le bundle (le plist de l'agent manque)"
        @unknown default: return "état inconnu"
        }
    }

    static func status() throws -> String {
        try requireBundle()
        return describe(service.status)
    }

    static func install() throws -> String {
        try requireBundle()
        if service.status != .enabled { try service.register() }
        let status = service.status
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return describe(status)
    }

    static func uninstall() throws -> String {
        try requireBundle()
        try service.unregister()
        return describe(service.status)
    }
}
```

`Sources/syncmacpro-ctl/main.swift` :

```swift
import Darwin
import Foundation
import SyncKit

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("Erreur : \(message)\n".utf8))
    exit(code)
}

let invocation: CtlInvocation
do {
    invocation = try CtlParser.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error.localizedDescription)", code: 64)
}

let paths = invocation.stateDirectory.map { AgentPaths(root: URL(fileURLWithPath: $0)) } ?? .standard
let client = AgentClient.machService(invocation.service ?? AgentIdentifiers.machService)

func show<T: Encodable>(_ value: T, lines: [String]) {
    print(invocation.json ? CtlFormatter.json(value) : lines.joined(separator: "\n"))
}

func resolve(_ text: String) async throws -> SyncTask {
    try TaskReference.resolve(text, in: try await client.listTasks())
}

do {
    switch invocation.command {
    case .help:
        print(CtlParser.usage)

    case .status:
        let status = try await client.status()
        show(status, lines: CtlFormatter.statusLines(status))

    case .list:
        let tasks = try await client.listTasks()
        show(tasks, lines: CtlFormatter.taskLines(tasks))

    case .run(let text):
        let task = try await resolve(text)
        try await client.perform(.runNow(task.id))
        print("« \(task.name) » lancée.")

    case .pause(let text):
        let task = try await resolve(text)
        try await client.perform(.pause(task.id))
        print("« \(task.name) » en pause.")

    case .resume(let text):
        let task = try await resolve(text)
        try await client.perform(.resume(task.id))
        print("« \(task.name) » reprise.")

    case .stop(let text):
        let task = try await resolve(text)
        try await client.perform(.stop(task.id))
        print("« \(task.name) » arrêtée.")

    case .approve(let text):
        let task = try await resolve(text)
        try await client.perform(.approveDeletion(task.id))
        print("Suppressions acceptées : « \(task.name) » relancée.")

    case .pauseAll:
        try await client.perform(.setGlobalPause(true))
        print("Pause globale activée (conservée après un redémarrage).")

    case .resumeAll:
        try await client.perform(.setGlobalPause(false))
        print("Pause globale levée.")

    case .history(let text, let limit):
        var id: UUID?
        if let text { id = try await resolve(text).id }
        let records = try await client.history(taskID: id, limit: limit)
        show(records, lines: CtlFormatter.historyLines(records))

    case .watch:
        let names = Dictionary(uniqueKeysWithValues: try await client.listTasks().map { ($0.id, $0.name) })
        let watch = try await client.watch { event in
            if let line = CtlFormatter.eventLine(event, names: names) { print(line); fflush(stdout) }
        }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { watch.cancel(); exit(0) }
        interrupt.resume()
        print("Suivi en direct (Ctrl-C pour quitter)…")
        withExtendedLifetime(interrupt) { RunLoop.main.run() }

    case .add(let new):
        var task = SyncTask(
            name: new.name, source: new.source, destination: new.destination, mode: new.mode, schedule: new.schedule
        )
        task.conditions.requiresACPower = new.requiresACPower
        try TaskStore(url: paths.tasks).upsert(task)
        print("Tâche « \(task.name) » ajoutée (\(CtlFormatter.scheduleDescription(task.schedule))).")
        // L'agent surveille tasks.json ; on le prévient pour qu'il relise tout de suite (s'il tourne).
        try? await client.perform(.reloadTasks)

    case .remove(let text):
        let store = TaskStore(url: paths.tasks)
        let task = try TaskReference.resolve(text, in: try store.load())
        try store.remove(id: task.id)
        print("Tâche « \(task.name) » supprimée.")
        try? await client.perform(.reloadTasks)

    case .agentInstall: print("Agent : \(try AgentRegistration.install())")
    case .agentUninstall: print("Agent : \(try AgentRegistration.uninstall())")
    case .agentStatus: print("Agent : \(try AgentRegistration.status())")
    }
} catch let error as AgentClientError where error == .unreachable {
    fail(error.localizedDescription, code: 69)
} catch {
    fail(error.localizedDescription)
}
```

- [ ] **Étape 6 : vérifier**

Exécuter : `swift build 2>&1 | tail -5` puis `.build/debug/syncmacpro-ctl aide | head -5` puis `.build/debug/syncmacpro-ctl status --service com.sylvain.syncmacpro.absent; echo "code $?"`
Attendu : compilation sans erreur ; l'aide s'affiche ; le dernier appel affiche « L'agent ne répond pas… » en environ 20 s et `code 69`.

- [ ] **Étape 7 : commit**

```bash
git add Package.swift Sources/SyncKit/Agent/Ctl*.swift Sources/syncmacpro-ctl Tests/SyncKitTests/CtlTests.swift
git commit -m "Outil syncmacpro-ctl : commandes, alias français, résolution des tâches, enregistrement SMAppService" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 11 : programme de l'agent

**Fichiers :**
- Créer : `Sources/syncmacpro-agent/main.swift`
- Modifier : `Package.swift`

**Interfaces :**
- Consomme : `AgentCore`, `AgentListenerDelegate`, `MacSystemConditions`, `UserNotifier`, `SleepActivity`, `CodeSigning`, `AgentPaths`, `TaskRunner`.
- Produit : exécutable `syncmacpro-agent` — options `--foreground`, `--state-dir DOSSIER`, `--mach-service NOM`, `--startup-hold SECONDES`.

Comportement : démarre le cœur, ouvre le service Mach (sauf `--foreground`), évalue tout de suite puis chaque minute, relit `tasks.json` quand son horodatage change, et sur SIGTERM / SIGINT arrête proprement (`shutdown`) avant de quitter.

Cette tâche est du câblage : pas de test unitaire (tout ce qu'elle appelle est testé aux tâches 4 à 10) ; la vérification est un essai de bout en bout, sans launchd.

- [ ] **Étape 1 : ajouter la cible**

`Package.swift` : ajouter dans `products` `.executable(name: "syncmacpro-agent", targets: ["syncmacpro-agent"]),` et dans `targets` `.executableTarget(name: "syncmacpro-agent", dependencies: ["SyncKit"]),`.

- [ ] **Étape 2 : écrire le programme**

`Sources/syncmacpro-agent/main.swift` :

```swift
import Darwin
import Foundation
import SyncKit

// Agent d'arrière-plan de SyncMacPro.
//
//   syncmacpro-agent [--foreground] [--state-dir DOSSIER] [--mach-service NOM] [--startup-hold SECONDES]
//
// Lancé par launchd (SMAppService) il répond aux requêtes XPC. Avec --foreground il tourne dans le terminal
// sans XPC : un service Mach exige launchd (voir scripts/dev-launchd.sh pour le développement).

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[\(Date().formatted(.iso8601))] \(message)\n".utf8))
}

let foreground = arguments.contains("--foreground")
let paths = option("--state-dir").map { AgentPaths(root: URL(fileURLWithPath: $0)) } ?? .standard
let serviceName = option("--mach-service") ?? AgentIdentifiers.machService

try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
let history = try HistoryStore(path: paths.history.path)
let runnerConfiguration = RunnerConfiguration(
    rsyncPath: BinaryLocator.locate(.rsync), rclonePath: BinaryLocator.locate(.rclone), workDirectory: paths.work
)
var agentConfiguration = AgentConfiguration()
if let hold = option("--startup-hold").flatMap(Double.init) { agentConfiguration.startupHold = hold }

let core = AgentCore(
    configuration: agentConfiguration,
    taskStore: TaskStore(url: paths.tasks),
    stateStore: SchedulerStateStore(url: paths.state),
    history: history,
    clock: SystemClock(),
    conditions: MacSystemConditions(),
    notifier: UserNotifier(),
    activity: SleepActivity(),
    log: { log($0) },
    makeRunner: { TaskRunner(configuration: runnerConfiguration) }
)
await core.start()
log("agent démarré (données : \(paths.root.path), rsync : \(runnerConfiguration.rsyncPath ?? "introuvable"))")

// XPC : le service doit être déclaré par launchd ; sans lui, rien à écouter.
let delegate = AgentListenerDelegate(
    core: core, codeSigningRequirement: CodeSigning.ownTeamIdentifier().map(CodeSigning.requirement(forTeam:))
)
let listener = NSXPCListener(machServiceName: serviceName)
listener.delegate = delegate
if foreground {
    log("mode terminal : pas de service XPC")
} else {
    listener.resume()
}

// Évaluation : tout de suite, puis chaque minute. tasks.json est relu quand son horodatage change.
func modificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}
final class StampBox: @unchecked Sendable { var value: Date? }
let tasksStamp = StampBox()
tasksStamp.value = modificationDate(paths.tasks)

func evaluate() async {
    let stamp = modificationDate(paths.tasks)
    if stamp != tasksStamp.value {
        tasksStamp.value = stamp
        await core.reloadTasks()
    }
    await core.tick()
}

await evaluate()
let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task.detached { await evaluate() } }

// Arrêt propre : les copies en cours sont arrêtées, marquées « interrompues » et rattrapées au prochain démarrage.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
// File dédiée : appelée depuis le code asynchrone de main.swift, `RunLoop.main.run()` ne sert pas la file principale.
let signalQueue = DispatchQueue(label: "syncmacpro.signals")
let signalSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        // `Task.detached` : le code de main.swift est lié à l'acteur principal, bloqué dans RunLoop.main.run().
        Task.detached {
            log("arrêt demandé")
            await core.shutdown()
            exit(0)
        }
    }
    source.resume()
    return source
}

withExtendedLifetime((timer, signalSources, listener, delegate)) { RunLoop.main.run() }
```

- [ ] **Étape 3 : compiler**

Exécuter : `swift build 2>&1 | tail -5`
Attendu : compilation sans erreur (des avertissements de concurrence sur des variables globales sont acceptables en mode Swift 5).

- [ ] **Étape 4 : essai de bout en bout sans launchd**

```bash
D=$(mktemp -d) && mkdir -p "$D/src" "$D/dst" && echo bonjour > "$D/src/a.txt" && echo salut > "$D/src/b.txt"
export SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync"
.build/debug/syncmacpro-ctl add --state-dir "$D/state" --name smoke --source "$D/src" --dest "$D/dst" --every 1
.build/debug/syncmacpro-agent --foreground --state-dir "$D/state" --startup-hold 0 2> "$D/agent.log" &
AGENT=$!
sleep 6
ls "$D/dst"
kill -TERM $AGENT; wait $AGENT; echo "agent arrêté, code $?"
.build/debug/synckit-cli history --state-dir "$D/state"
cat "$D/agent.log"
```
Attendu : `a.txt` et `b.txt` dans `dst` ; `agent arrêté, code 0` ; l'historique montre une exécution `succeeded` pour « smoke » ; le journal contient « agent démarré » puis « arrêt demandé ». Nettoyer : `rm -rf "$D"`.

- [ ] **Étape 5 : commit**

```bash
git add Package.swift Sources/syncmacpro-agent
git commit -m "Programme de l'agent : boucle minute, XPC, arrêt propre" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 12 : bundle de développement, enregistrement launchd et essai réel

**Fichiers :**
- Créer : `scripts/make-dev-bundle.sh`, `scripts/dev-launchd.sh`

**Interfaces :**
- Produit : `scripts/make-dev-bundle.sh [DOSSIER]` assemble `SyncMacPro.app` (signature ad hoc) avec `syncmacpro-ctl` comme exécutable principal, l'agent et le plist de l'agent ; `scripts/dev-launchd.sh install|uninstall|status` déclare un agent de développement via `launchctl bootstrap` (sans bundle), avec ses propres données (`SyncMacPro-dev`) et un autre nom de service.

Cette tâche est un essai réel sur la machine : **pas de test automatique**, mais des résultats attendus précis. L'étape 5 enregistre un agent dans Éléments de connexion : le retirer à la fin.

- [ ] **Étape 1 : écrire `scripts/make-dev-bundle.sh`**

```bash
#!/bin/bash
# Assemble SyncMacPro.app (signature ad hoc) : l'outil ctl comme exécutable principal,
# l'agent et son plist. SMAppService n'accepte d'enregistrer l'agent que depuis ce bundle.
#
#   scripts/make-dev-bundle.sh [DOSSIER]        (défaut : ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$HOME/Applications}"
APP="$OUT/SyncMacPro.app"
LABEL="com.sylvain.syncmacpro.agent"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/syncmacpro-ctl" "$BIN/syncmacpro-agent" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sylvain.syncmacpro</string>
  <key>CFBundleName</key><string>SyncMacPro</string>
  <key>CFBundleExecutable</key><string>syncmacpro-ctl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

cat > "$APP/Contents/Library/LaunchAgents/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>BundleProgram</key><string>Contents/MacOS/syncmacpro-agent</string>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/syncmacpro-agent"
codesign --force --sign - "$APP/Contents/MacOS/syncmacpro-ctl"
codesign --force --sign - "$APP"

echo "Bundle prêt : $APP"
echo "Installer l'agent : \"$APP/Contents/MacOS/syncmacpro-ctl\" agent install"
```

- [ ] **Étape 2 : écrire `scripts/dev-launchd.sh`**

```bash
#!/bin/bash
# Agent de développement sans bundle : launchctl déclare le service Mach (un processus lancé à la main ne le peut pas).
# Données dans ~/Library/Application Support/SyncMacPro-dev, service « com.sylvain.syncmacpro.agent.dev ».
#
#   scripts/dev-launchd.sh install | uninstall | status
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.sylvain.syncmacpro.agent.dev"
DATA="$HOME/Library/Application Support/SyncMacPro-dev"
PLIST="$DATA/$LABEL.plist"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
  install)
    swift build
    mkdir -p "$DATA"
    cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$PWD/.build/debug/syncmacpro-agent</string>
    <string>--state-dir</string><string>$DATA</string>
    <string>--mach-service</string><string>$LABEL</string>
    <string>--startup-hold</string><string>0</string>
  </array>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$DATA/agent.log</string>
</dict></plist>
XML
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "Agent de développement lancé. Essayer :"
    echo "  .build/debug/syncmacpro-ctl status --service $LABEL --state-dir \"$DATA\""
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Agent de développement retiré (les données restent dans $DATA)."
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | head -12 || echo "non installé"
    ;;
  *)
    echo "Usage : $0 install | uninstall | status" >&2
    exit 64
    ;;
esac
```

Puis `chmod +x scripts/make-dev-bundle.sh scripts/dev-launchd.sh`.

- [ ] **Étape 3 : essai XPC réel avec l'agent de développement**

```bash
export SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync"
scripts/dev-launchd.sh install
D="$HOME/Library/Application Support/SyncMacPro-dev"; S=com.sylvain.syncmacpro.agent.dev
mkdir -p /tmp/smp-e2e/src /tmp/smp-e2e/dst && echo un > /tmp/smp-e2e/src/a.txt
.build/debug/syncmacpro-ctl add --service $S --state-dir "$D" --name e2e --source /tmp/smp-e2e/src --dest /tmp/smp-e2e/dst
.build/debug/syncmacpro-ctl status --service $S --state-dir "$D"
.build/debug/syncmacpro-ctl run e2e --service $S
sleep 4; ls /tmp/smp-e2e/dst
.build/debug/syncmacpro-ctl history --service $S
.build/debug/syncmacpro-ctl pause-all --service $S && .build/debug/syncmacpro-ctl status --service $S | head -2
```
Attendu : `status` liste la tâche « e2e » ; après `run`, `a.txt` est dans `dst` et l'historique montre « réussie » ; la pause globale s'affiche « oui ».

- [ ] **Étape 4 : essai de survie et de relance**

```bash
pkill -f "syncmacpro-agent.*agent.dev"; sleep 1
time .build/debug/syncmacpro-ctl status --service $S | head -2
```
Attendu : la commande aboutit après environ 10 s (relance par launchd) avec **« Pause globale : oui »** : la pause a survécu à l'arrêt brutal. (Si `time` dépasse 20 s : l'agent n'est pas relancé, vérifier `scripts/dev-launchd.sh status`.)

Nettoyer : `.build/debug/syncmacpro-ctl resume-all --service $S; scripts/dev-launchd.sh uninstall; rm -rf /tmp/smp-e2e "$D"`.

- [ ] **Étape 5 : essai du bundle et de SMAppService**

```bash
scripts/make-dev-bundle.sh
~/Applications/SyncMacPro.app/Contents/MacOS/syncmacpro-ctl agent install
~/Applications/SyncMacPro.app/Contents/MacOS/syncmacpro-ctl status
~/Applications/SyncMacPro.app/Contents/MacOS/syncmacpro-ctl agent uninstall
```
Attendu : `agent install` répond « installé et actif » (ou indique l'autorisation à donner dans Réglages Système) ; `status` répond (liste vide d'abord) ; `agent uninstall` répond « non installé ». Noter le résultat dans le message de commit. Supprimer ensuite `~/Applications/SyncMacPro.app` si l'on ne veut pas le garder.

Si `agent install` échoue sur cette machine alors que le spike avait réussi, relever le message exact : c'est un écart à signaler avant de continuer.

- [ ] **Étape 6 : commit**

```bash
git add scripts
git commit -m "Scripts de développement : bundle ad hoc avec agent, agent launchd sans bundle" -m "Essai réel : XPC, survie de la pause globale après arrêt brutal, SMAppService vérifiés sur macOS 26." -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Tâche 13 : tests d'intégration réels, documentation, CI

**Fichiers :**
- Modifier : `README.md`
- Créer : `Tests/SyncKitTests/AgentIntegrationTests.swift`

**Interfaces :**
- Consomme : tout ce qui précède, plus `IntegrationTestCase` (vrai rsync, dossiers temporaires).
- Produit : 2 tests d'intégration (copie planifiée réelle ; interruption puis rattrapage réels) et la documentation de l'agent.

- [ ] **Étape 1 : écrire les tests d'intégration**

`Tests/SyncKitTests/AgentIntegrationTests.swift` :

```swift
import XCTest
@testable import SyncKit

/// Le vrai rsync derrière l'agent, avec une horloge pilotée : planification, copie, interruption, rattrapage.
final class AgentIntegrationTests: IntegrationTestCase {
    func testScheduledCopyReallyCopiesTheFiles() async throws {
        let configuration = try makeRunner(rsync: true).configuration
        let source = try folder("src"), destination = try folder("dst")
        try write("\(source)/a.txt", "bonjour")
        try write("\(source)/sous/b.txt", "salut")

        let h = try AgentHarness(start: Date(timeIntervalSince1970: 1_760_000_000))
        var task = makeTask("réelle", schedule: .everyMinutes(1))
        task.source = .local(path: source)
        task.destination = .local(path: destination)
        try h.save([task])

        let core = h.makeCore(runner: { TaskRunner(configuration: configuration) })
        await core.start()
        await core.tick()
        await core.waitForIdle()

        XCTAssertEqual(try String(contentsOfFile: "\(destination)/a.txt"), "bonjour")
        XCTAssertEqual(try String(contentsOfFile: "\(destination)/sous/b.txt"), "salut")
        let record = try XCTUnwrap(try h.history.list(taskID: task.id).first)
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertGreaterThanOrEqual(record.summary?.filesTransferred ?? 0, 2)
    }

    func testCopyInterruptedByAgentShutdownIsCaughtUpAfterRestart() async throws {
        let configuration = try makeRunner(rsync: true).configuration
        let source = try folder("src"), destination = try folder("dst")
        try writeBytes("\(source)/gros.bin", megabytes: 2)

        let h = try AgentHarness(start: Date(timeIntervalSince1970: 1_760_000_000))
        var task = makeTask("lente", schedule: .everyMinutes(1))
        task.source = .local(path: source)
        task.destination = .local(path: destination)
        task.options.bandwidthLimitKBps = 400   // ~5 s pour 2 Mo : le temps de l'interrompre
        try h.save([task])

        let first = h.makeCore(runner: { TaskRunner(configuration: configuration) })
        await first.start()
        await first.tick()
        let running = await eventually(timeout: 5) { await first.status().tasks.first?.state == .running }
        XCTAssertTrue(running)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        await first.shutdown()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .interrupted)

        // L'agent redémarre, sans limite de débit cette fois : la copie est rattrapée et se termine.
        task.options.bandwidthLimitKBps = nil
        try h.save([task])
        let second = h.makeCore(runner: { TaskRunner(configuration: configuration) })
        await second.start()
        await second.tick()
        await second.waitForIdle()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .succeeded)
        let copied = try FileManager.default.attributesOfItem(atPath: "\(destination)/gros.bin")[.size] as? Int
        XCTAssertEqual(copied, 2 * 1_048_576)
    }
}
```

- [ ] **Étape 2 : lancer**

Exécuter : `SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync" swift test --filter AgentIntegrationTests 2>&1 | tail -10`
Attendu : 2 tests passent (ils sont ignorés, avec un message, si rsync 3.x est introuvable). Puis la suite complète : `SYNCMACPRO_RSYNC=… swift test 2>&1 | tail -5` → tout est vert.

- [ ] **Étape 3 : documenter**

Dans `README.md`, ajouter une section « Agent d'arrière-plan » : ce qu'il fait ; les commandes de `syncmacpro-ctl` (liste de `CtlParser.usage`) ; les fichiers de données (`tasks.json`, `scheduler-state.json`, `history.sqlite`) ; `scripts/make-dev-bundle.sh` + `agent install` ; `scripts/dev-launchd.sh` pour le développement ; le fait que `--foreground` n'ouvre pas de XPC ; le rattrapage unique et la pause globale persistante ; la limite connue (essayé seulement sur macOS 26 ; macOS 14 / 15 à confirmer).

- [ ] **Étape 4 : commit**

```bash
git add README.md Tests/SyncKitTests
git commit -m "Tests d'intégration de l'agent (vrai rsync, interruption, rattrapage) et documentation" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Auto-revue du plan

- **Couverture du spec :** planification et rattrapage (tâches 2, 5) ; conditions (1, 5) ; échec et reprises (5) ; pause globale persistante (3, 6) ; exécution, concurrence, anti-veille, garde miroir (5, 6, 9) ; arrêt de l'agent et rattrapage des interruptions (6, 13) ; état et corruption (3) ; rétention (5) ; notifications (5, 9) ; contrat XPC versionné, observateurs, sécurité (7, 8, 9) ; CLI et alias (10) ; enregistrement, repli, désinstallation (10, 12) ; tests planificateur / file / état / XPC / intégration (2 à 13).
- **Écarts assumés** (section « Décisions ») : `--foreground` sans XPC ; tests XPC par écouteur anonyme ; `SchedulerClock` ; conditions ajoutées à `SyncTask`.
- **Cohérence des types :** `AgentCore.runNow/pause/resume/stop/setGlobalPause/approveDeletion/shutdown` (tâche 6) sont appelées par `AgentRouter` (tâche 7) avec les mêmes signatures ; `AgentClient.perform` / `status` / `listTasks` / `history` (tâche 8) sont celles qu'utilise `main.swift` du ctl (tâche 10) ; `AgentIdentifiers` (tâche 7) et `AgentPaths` (tâche 9) servent aux tâches 8, 10, 11.
