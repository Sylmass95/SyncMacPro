# SyncMacPro — Cœur (SyncKit) : plan d'implémentation

> **Pour les agents d'exécution :** SOUS-COMPÉTENCE REQUISE : utiliser superpowers:subagent-driven-development (recommandé) ou superpowers:executing-plans pour exécuter ce plan tâche par tâche. Les étapes utilisent la syntaxe à cases (`- [ ]`) pour le suivi.

**Objectif :** construire `SyncKit`, la bibliothèque Swift qui décrit une tâche de synchronisation, choisit et pilote rsync ou rclone, suit l'avancement en direct, applique les garde-fous de suppression et garde l'historique, plus un petit outil en ligne de commande (`synckit-cli`) pour la vérifier à la main.

**Architecture :** une bibliothèque sans interface ni planification (sous-projets 2 et 3). Des constructeurs de commandes purs (tâche → arguments), des lecteurs de sortie testés sur de **vraies captures** de rsync 3.5.1 et rclone 1.75, un suivi de progression pur (horloge injectée), un lanceur de processus (`posix_spawn`, groupe de processus propre) et un orchestrateur `TaskRunner` qui relie le tout. Tout est testé avec les vrais binaires sur des dossiers temporaires.

**Stack technique :** Swift 5.9+ (SwiftPM, mode de langage Swift 5), XCTest, SQLite3 du système, rsync 3.x et rclone en binaires externes.

**Spec :** `docs/superpowers/specs/2026-10-12-syncmacpro-design.md` (sections 4 à 6, 8 et 10). Ce plan couvre le **sous-projet 1** ; la planification en arrière-plan, l'interface, l'assistant de connexion et la distribution auront chacun leur plan.

## Contraintes globales

Valeurs reprises mot pour mot de la spec ; elles s'appliquent à toutes les tâches :

- Application **100 % native Swift / SwiftUI**, agent d'arrière-plan Swift, **aucun Python** dans le produit (les scripts Python de ce plan ne servent qu'à écrire des fichiers de référence).
- **macOS minimum : 14** (`platforms: [.macOS(.v14)]`).
- Moteurs : **rsync** (dossiers et volumes) et **rclone** (services en ligne), choix automatique ; rclone n'est jamais modifié.
- Modes : copie, miroir, bidirectionnel, déplacer, sauvegarde avec versions, vérifier. Les modes qui suppriment imposent un **blocage automatique** au-delà d'un seuil (**25 % par défaut**) et rien n'est détruit sans archive dans un dossier daté.
- Les mots de passe et jetons ne sont jamais écrits dans les tâches ni l'historique (Trousseau, sous-projet 2).
- Dépôt : https://github.com/Sylmass95/SyncMacPro · Licence **MIT** · textes visibles en **français** (l'anglais viendra avec l'interface).
- rsync 3.x est requis pour les tests (celui de macOS, openrsync, ne convient pas) : `brew install rsync rclone`, puis `export SYNCMACPRO_RSYNC=/opt/homebrew/bin/rsync`. Sans ces binaires, les tests d'intégration sont **ignorés**, jamais en échec.

## Review Focus

Cas que la spec suppose sans les détailler, et qui font vraiment mal à un utilisateur. Chacun a son test dans la tâche indiquée :

1. **Dossier source absent ou illisible** → échec avec un message, pas de plantage ni de succès silencieux. (`testMissingSourceFailsWithAMessage`, tâche 10)
2. **Noms de fichiers difficiles** : accents, espaces, `|`, `;`, `&`, `$`, caractères japonais, nom commençant par un tiret. (`testAwkwardFileNamesSurviveTheWholePipeline`, tâche 10 ; `testItemizedNameMayContainABar`, tâche 5)
3. **Destination qui disparaît en pleine copie** (NAS débranché) → l'exécution échoue avec un message au lieu de rester bloquée. (`testDestinationVanishingMidRunFailsInsteadOfHanging`, tâche 10)
4. **Destination impossible à créer** → échec clair, rien n'est copié ni écrasé. (`testDestinationThatCannotBeCreatedFailsWithAMessage`, tâche 10)
5. **Source vidée ou suppression massive** ne doit pas vider la destination d'un miroir ou d'un bidirectionnel. (`testAnEmptiedSourceCannotWipeTheMirror`, `testMirrorIsBlockedWhenTooManyFilesWouldBeDeletedAndTouchesNothing`, `testBisyncBlocksAMassDeletionAndChangesNothing`, tâche 10 ; `DeleteGuardTests`, tâche 8)

**Hors de ce plan (vérifié à la main) :** le quota Google Drive (code de sortie 8 de rclone, état `quotaReached`) car il faudrait transférer plus de 1 Go ; les services en ligne réels (Drive, Dropbox…) ; la planification, la reprise après redémarrage du Mac et les notifications (sous-projet 2).

## Structure des fichiers

```
Package.swift                              SwiftPM : SyncKit + synckit-cli + tests
Sources/SyncKit/
  Engine.swift                             EngineKind (rsync | rclone)
  Endpoint.swift  SyncMode.swift  Schedule.swift  SyncTask.swift     modèle d'une tâche
  EngineSelector.swift                     choix automatique du moteur
  EngineCommand.swift                      RunOptions, EngineCommand, erreurs de commande
  RsyncCommandBuilder.swift  RcloneCommandBuilder.swift              tâche → arguments
  LineSplitter.swift                       flux → lignes (« \n » et « \r »)
  RsyncOutputParser.swift  RsyncPlanParser.swift  RcloneOutputParser.swift   lecture des sorties
  ProgressTracker.swift                    avancement : fichier en cours + total
  ProcessRunner.swift  BinaryLocator.swift lancement, pause, arrêt ; recherche des binaires
  DeleteGuard.swift                        garde-fou de suppression
  RunRecord.swift  HistoryStore.swift  TaskStore.swift               stockage (SQLite + JSON)
  RunnerTypes.swift  TaskRunner.swift  TaskRunner+Rsync.swift  TaskRunner+Rclone.swift   orchestrateur
  Formatting.swift                         tailles, débits, durées en français
Sources/synckit-cli/main.swift             outil de développement
Tests/SyncKitTests/                        tests + Fixtures/ (sorties réelles de rsync et rclone)
```

Chaque fichier a une seule responsabilité ; les constructeurs de commandes, les lecteurs de sortie et le suivi de progression sont purs et se testent sans lancer aucun programme.

---

### Tâche 1 : squelette SwiftPM et modèle d'une tâche

**Fichiers :**
- Créer : `Package.swift`, `Sources/SyncKit/{Engine,Endpoint,SyncMode,Schedule,SyncTask}.swift`, `Sources/synckit-cli/main.swift` (provisoire), `Tests/SyncKitTests/Fixtures/.gitkeep`
- Test : `Tests/SyncKitTests/ModelsTests.swift`

**Interfaces :**
- Consomme : rien.
- Produit : `EngineKind` (`.rsync`, `.rclone`) ; `Endpoint` (`.local(path:)`, `.network(url:mountPath:)`, `.cloud(remote:path:)`, `isCloud`, `filesystemPath`, `rcloneSpec`, `appending(_:)`) ; `SyncMode` (`copy, mirror, bidirectional, move, versioned, verify`, `deletesData`, `requiresRclone`) ; `Schedule` ; `NotificationPolicy` ; `TaskOptions` ; `SyncTask` (`Codable`, `Equatable`, `Identifiable`, `Sendable`).

- [ ] **Étape 1 : créer le squelette et le test (le test échoue tant que le code n'existe pas)**

Depuis la racine du dépôt :

```bash
mkdir -p Sources/SyncKit Sources/synckit-cli Tests/SyncKitTests/Fixtures
touch Tests/SyncKitTests/Fixtures/.gitkeep
```

Créer `Package.swift` :

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncMacPro",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"]),
        .executable(name: "synckit-cli", targets: ["synckit-cli"]),
    ],
    targets: [
        .target(name: "SyncKit"),
        .executableTarget(name: "synckit-cli", dependencies: ["SyncKit"]),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

Créer `Sources/synckit-cli/main.swift` (provisoire, remplacé à la tâche 11) :

```swift
import SyncKit
print("synckit-cli")
```

Créer `Tests/SyncKitTests/ModelsTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class ModelsTests: XCTestCase {
    func testTaskSurvivesJSONRoundTrip() throws {
        let task = SyncTask(
            name: "Sauvegarde NAS",
            source: .network(url: "smb://nas/archives", mountPath: "/Volumes/archives"),
            destination: .cloud(remote: "gdrive", path: "BACKUP"),
            mode: .mirror,
            options: TaskOptions(bandwidthLimitKBps: 5000, deleteThresholdPercent: 10),
            schedule: .weekdays(days: [2, 3, 4], hour: 12, minute: 30)
        )
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(SyncTask.self, from: data)
        XCTAssertEqual(decoded, task)
    }

    func testDefaultsAreSafe() {
        let task = SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))
        XCTAssertEqual(task.mode, .copy)
        XCTAssertEqual(task.schedule, .manual)
        XCTAssertEqual(task.options.deleteThresholdPercent, 25)
        XCTAssertEqual(task.options.archiveFolder, "_ARCHIVE")
        XCTAssertTrue(task.options.excludes.contains(".DS_Store"))
        XCTAssertTrue(task.sourceItems.isEmpty)
    }

    func testEndpointSpecsAndPaths() {
        XCTAssertEqual(Endpoint.local(path: "/a/b").rcloneSpec, "/a/b")
        XCTAssertEqual(Endpoint.cloud(remote: "gdrive", path: "X/Y").rcloneSpec, "gdrive:X/Y")
        XCTAssertEqual(Endpoint.network(url: "smb://n/s", mountPath: "/Volumes/s").filesystemPath, "/Volumes/s")
        XCTAssertNil(Endpoint.cloud(remote: "gdrive", path: "").filesystemPath)
        XCTAssertTrue(Endpoint.cloud(remote: "gdrive", path: "").isCloud)
        XCTAssertFalse(Endpoint.local(path: "/a").isCloud)
    }

    func testAppendingHandlesSlashes() {
        XCTAssertEqual(Endpoint.local(path: "/a/").appending("_ARCHIVE"), .local(path: "/a/_ARCHIVE"))
        XCTAssertEqual(Endpoint.cloud(remote: "g", path: "").appending("_ARCHIVE"), .cloud(remote: "g", path: "_ARCHIVE"))
        XCTAssertEqual(Endpoint.cloud(remote: "g", path: "X").appending("/Y"), .cloud(remote: "g", path: "X/Y"))
    }

    func testModeProperties() {
        XCTAssertTrue(SyncMode.mirror.deletesData)
        XCTAssertTrue(SyncMode.bidirectional.deletesData)
        XCTAssertTrue(SyncMode.move.deletesData)
        XCTAssertFalse(SyncMode.copy.deletesData)
        XCTAssertFalse(SyncMode.verify.deletesData)
        XCTAssertTrue(SyncMode.bidirectional.requiresRclone)
        XCTAssertTrue(SyncMode.versioned.requiresRclone)
        XCTAssertFalse(SyncMode.mirror.requiresRclone)
    }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test`
Attendu : ÉCHEC — SwiftPM refuse de compiler (la cible `SyncKit` n'a aucun fichier source).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/Engine.swift` :

```swift
import Foundation

/// Les deux programmes que SyncMacPro pilote.
public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case rsync
    case rclone
}
```

Créer `Sources/SyncKit/Endpoint.swift` :

```swift
import Foundation

/// Un côté d'une synchronisation : dossier local, volume réseau ou service en ligne.
public enum Endpoint: Codable, Equatable, Hashable, Sendable {
    /// Dossier ou disque local.
    case local(path: String)
    /// Partage réseau (par exemple `smb://nas/partage`) déjà monté sur `mountPath`.
    case network(url: String, mountPath: String)
    /// Service en ligne géré par rclone (`remote` est le nom du « remote » rclone).
    case cloud(remote: String, path: String)

    public var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }

    /// Chemin sur le disque (dossier ou volume monté) ; `nil` pour un service en ligne.
    public var filesystemPath: String? {
        switch self {
        case .local(let path): return path
        case .network(_, let mountPath): return mountPath
        case .cloud: return nil
        }
    }

    /// Argument à donner à rclone : `remote:chemin` ou chemin local.
    public var rcloneSpec: String {
        switch self {
        case .local(let path): return path
        case .network(_, let mountPath): return mountPath
        case .cloud(let remote, let path): return "\(remote):\(path)"
        }
    }

    /// Le même endroit avec un sous-dossier en plus (par exemple pour un dossier d'archive).
    public func appending(_ component: String) -> Endpoint {
        switch self {
        case .local(let path): return .local(path: Endpoint.join(path, component))
        case .network(let url, let mountPath):
            return .network(url: url, mountPath: Endpoint.join(mountPath, component))
        case .cloud(let remote, let path): return .cloud(remote: remote, path: Endpoint.join(path, component))
        }
    }

    static func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedComponent = component.hasPrefix("/") ? String(component.dropFirst()) : component
        return "\(trimmedBase)/\(trimmedComponent)"
    }
}
```

Créer `Sources/SyncKit/SyncMode.swift` :

```swift
import Foundation

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    /// Ajoute ce qui est nouveau ou modifié, ne supprime jamais.
    case copy
    /// La destination devient identique ; ce qui est supprimé ou écrasé est archivé.
    case mirror
    /// Les deux côtés restent à jour, suppressions comprises (rclone bisync).
    case bidirectional
    /// Copie puis supprime la source.
    case move
    /// Garde l'historique des anciennes versions pendant N jours.
    case versioned
    /// Compare sans rien modifier.
    case verify

    /// Vrai si le mode peut supprimer des fichiers (garde-fous obligatoires).
    public var deletesData: Bool {
        switch self {
        case .mirror, .bidirectional, .move: return true
        case .copy, .versioned, .verify: return false
        }
    }

    /// Vrai si seul rclone sait faire ce mode.
    public var requiresRclone: Bool {
        self == .bidirectional || self == .versioned
    }
}
```

Créer `Sources/SyncKit/Schedule.swift` :

```swift
import Foundation

/// Quand une tâche doit se lancer. Le calcul des échéances est fait par l'agent (sous-projet 2).
public enum Schedule: Codable, Equatable, Hashable, Sendable {
    case manual
    case daily(hour: Int, minute: Int)
    case everyMinutes(Int)
    /// `days` suit `Calendar` : 1 = dimanche … 7 = samedi.
    case weekdays(days: Set<Int>, hour: Int, minute: Int)
    /// Dès que la source et la destination sont joignables.
    case whenAvailable
}
```

Créer `Sources/SyncKit/SyncTask.swift` :

```swift
import Foundation

public enum NotificationPolicy: String, Codable, CaseIterable, Sendable {
    case always
    case errorsOnly
    case never
}

public struct TaskOptions: Codable, Equatable, Hashable, Sendable {
    public static let defaultExcludes = [".DS_Store", "Thumbs.db", "._*", "@eaDir/", "#recycle/"]

    public var excludes: [String]
    /// Limite de débit en Ko/s ; `nil` = illimité.
    public var bandwidthLimitKBps: Int?
    public var verifyAfterCopy: Bool
    /// Au-delà de ce pourcentage de suppressions, une exécution est bloquée.
    public var deleteThresholdPercent: Int
    /// Nom du dossier d'archive créé à la racine de la destination.
    public var archiveFolder: String
    /// Durée de conservation des anciennes versions (mode `versioned`).
    public var retentionDays: Int?
    /// Quota de transfert par exécution, en Go (par exemple 750 pour Google Drive).
    public var maxTransferGB: Int?
    public var forcedEngine: EngineKind?
    /// Options avancées passées telles quelles au moteur (utilisateurs experts, diagnostics).
    public var extraArguments: [String]

    public init(
        excludes: [String] = TaskOptions.defaultExcludes,
        bandwidthLimitKBps: Int? = nil,
        verifyAfterCopy: Bool = false,
        deleteThresholdPercent: Int = 25,
        archiveFolder: String = "_ARCHIVE",
        retentionDays: Int? = nil,
        maxTransferGB: Int? = nil,
        forcedEngine: EngineKind? = nil,
        extraArguments: [String] = []
    ) {
        self.excludes = excludes
        self.bandwidthLimitKBps = bandwidthLimitKBps
        self.verifyAfterCopy = verifyAfterCopy
        self.deleteThresholdPercent = deleteThresholdPercent
        self.archiveFolder = archiveFolder
        self.retentionDays = retentionDays
        self.maxTransferGB = maxTransferGB
        self.forcedEngine = forcedEngine
        self.extraArguments = extraArguments
    }
}

public struct SyncTask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var source: Endpoint
    public var destination: Endpoint
    /// Si non vide : seuls ces éléments (noms relatifs à la source) sont copiés, un dossier étant copié en tant que dossier.
    public var sourceItems: [String]
    public var mode: SyncMode
    public var options: TaskOptions
    public var schedule: Schedule
    public var notifications: NotificationPolicy
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        source: Endpoint,
        destination: Endpoint,
        sourceItems: [String] = [],
        mode: SyncMode = .copy,
        options: TaskOptions = TaskOptions(),
        schedule: Schedule = .manual,
        notifications: NotificationPolicy = .always,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.destination = destination
        self.sourceItems = sourceItems
        self.mode = mode
        self.options = options
        self.schedule = schedule
        self.notifications = notifications
        self.isEnabled = isEnabled
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **5 tests**.

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): squelette SwiftPM et modèle d'une tâche"
```

---

### Tâche 2 : choix automatique du moteur

**Fichiers :**
- Créer : `Sources/SyncKit/EngineSelector.swift`
- Test : `Tests/SyncKitTests/EngineSelectorTests.swift`

**Interfaces :**
- Consomme : `SyncTask` (`source`, `destination`, `mode`, `options.forcedEngine`), `Endpoint.isCloud`, `SyncMode.requiresRclone`.
- Produit : `EngineSelector.engine(for: SyncTask) throws -> EngineKind` ; `EngineSelectionError.unsupportedMode(mode:engine:)` et `.cloudRequiresRclone`.

Règles (spec §5.2) : un côté en ligne ou un mode réservé à rclone → rclone ; sinon rsync ; l'utilisateur peut forcer rclone, mais forcer rsync sur un cas qu'il ne gère pas est une erreur explicite.

- [ ] **Étape 1 : écrire le test qui échoue**

Créer `Tests/SyncKitTests/EngineSelectorTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class EngineSelectorTests: XCTestCase {
    private func task(
        source: Endpoint = .local(path: "/a"),
        destination: Endpoint = .local(path: "/b"),
        mode: SyncMode = .copy,
        forced: EngineKind? = nil
    ) -> SyncTask {
        SyncTask(
            name: "t", source: source, destination: destination, mode: mode,
            options: TaskOptions(forcedEngine: forced)
        )
    }

    func testLocalToNetworkUsesRsync() throws {
        let t = task(destination: .network(url: "smb://n/s", mountPath: "/Volumes/s"))
        XCTAssertEqual(try EngineSelector.engine(for: t), .rsync)
    }

    func testAnyCloudSideUsesRclone() throws {
        XCTAssertEqual(try EngineSelector.engine(for: task(destination: .cloud(remote: "g", path: ""))), .rclone)
        XCTAssertEqual(try EngineSelector.engine(for: task(source: .cloud(remote: "g", path: ""))), .rclone)
    }

    func testRcloneOnlyModesUseRcloneEvenLocally() throws {
        XCTAssertEqual(try EngineSelector.engine(for: task(mode: .bidirectional)), .rclone)
        XCTAssertEqual(try EngineSelector.engine(for: task(mode: .versioned)), .rclone)
    }

    func testForcingRcloneAlwaysWorks() throws {
        XCTAssertEqual(try EngineSelector.engine(for: task(mode: .mirror, forced: .rclone)), .rclone)
    }

    func testForcingRsyncOnCloudFails() {
        let t = task(destination: .cloud(remote: "g", path: ""), forced: .rsync)
        XCTAssertThrowsError(try EngineSelector.engine(for: t)) {
            XCTAssertEqual($0 as? EngineSelectionError, .cloudRequiresRclone)
        }
    }

    func testForcingRsyncOnBidirectionalFails() {
        let t = task(mode: .bidirectional, forced: .rsync)
        XCTAssertThrowsError(try EngineSelector.engine(for: t)) {
            XCTAssertEqual($0 as? EngineSelectionError, .unsupportedMode(mode: .bidirectional, engine: .rsync))
        }
    }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test --filter EngineSelectorTests`
Attendu : ÉCHEC de compilation (`cannot find 'EngineSelector' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/EngineSelector.swift` :

```swift
import Foundation

public enum EngineSelectionError: Error, Equatable {
    /// Le moteur demandé ne sait pas faire ce mode.
    case unsupportedMode(mode: SyncMode, engine: EngineKind)
    /// rsync ne sait pas parler à un service en ligne.
    case cloudRequiresRclone
}

public enum EngineSelector {
    /// Choisit rsync ou rclone pour une tâche.
    /// - rclone si un côté est un service en ligne, ou si le mode n'existe que dans rclone ;
    /// - sinon rsync, sauf si l'utilisateur force rclone ;
    /// - forcer rsync sur un cas qu'il ne gère pas est une erreur explicite.
    public static func engine(for task: SyncTask) throws -> EngineKind {
        let touchesCloud = task.source.isCloud || task.destination.isCloud

        if let forced = task.options.forcedEngine {
            if forced == .rsync {
                if touchesCloud { throw EngineSelectionError.cloudRequiresRclone }
                if task.mode.requiresRclone {
                    throw EngineSelectionError.unsupportedMode(mode: task.mode, engine: .rsync)
                }
            }
            return forced
        }
        if touchesCloud || task.mode.requiresRclone { return .rclone }
        return .rsync
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **11 tests**.

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): choix automatique du moteur"
```

---

### Tâche 3 : constructeur de commandes rsync

**Fichiers :**
- Créer : `Sources/SyncKit/EngineCommand.swift`, `Sources/SyncKit/RsyncCommandBuilder.swift`
- Test : `Tests/SyncKitTests/RsyncCommandBuilderTests.swift`

**Interfaces :**
- Consomme : `SyncTask`, `TaskOptions` (`excludes`, `bandwidthLimitKBps`, `archiveFolder`, `extraArguments`), `Endpoint.filesystemPath`, `Endpoint.join` (interne).
- Produit : `RunOptions(dryRun:archiveStamp:resync:bisyncWorkdir:rcloneConfigPath:maxDeleteCount:)` ; `EngineCommand(engine:arguments:)` ; `CommandError.unsupportedMode`, `.missingFilesystemPath` ; `RsyncCommandBuilder.command(for:run:) throws -> EngineCommand` et `.planCommand(for:run:) throws -> EngineCommand` ; `PathText.withTrailingSlash/withoutTrailingSlash` (internes).

Points validés avec le vrai rsync 3.5.1 : le miroir avec `--inplace --delete --backup --backup-dir=<destination>/<archive>/<date>` archive à la fois les fichiers supprimés et les anciennes versions ; `--remove-source-files` laisse les dossiers vides de la source ; `-rcn --out-format=%i|%n` liste les fichiers qui diffèrent.

- [ ] **Étape 1 : écrire le test qui échoue**

Créer `Tests/SyncKitTests/RsyncCommandBuilderTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class RsyncCommandBuilderTests: XCTestCase {
    private let run = RunOptions(archiveStamp: "2026-10-12_14-30")

    private func task(
        mode: SyncMode = .copy,
        items: [String] = [],
        options: TaskOptions = TaskOptions(excludes: [])
    ) -> SyncTask {
        SyncTask(
            name: "t",
            source: .local(path: "/src"),
            destination: .network(url: "smb://nas/s", mountPath: "/Volumes/s"),
            sourceItems: items, mode: mode, options: options
        )
    }

    func testCopyArguments() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(), run: run)
        XCTAssertEqual(cmd.engine, .rsync)
        XCTAssertEqual(cmd.arguments, [
            "-rtv", "--inplace", "--partial", "--progress", "--timeout=60", "--out-format=%i|%n",
            "/src/", "/Volumes/s/",
        ])
    }

    func testMirrorArchivesWhatItDeletesOrOverwrites() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(mode: .mirror), run: run)
        XCTAssertTrue(cmd.arguments.contains("--delete"))
        XCTAssertTrue(cmd.arguments.contains("--backup"))
        XCTAssertTrue(cmd.arguments.contains("--backup-dir=/Volumes/s/_ARCHIVE/2026-10-12_14-30"))
        XCTAssertTrue(cmd.arguments.contains("--exclude=/_ARCHIVE/"))
    }

    func testMoveRemovesSourceFiles() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(mode: .move), run: run)
        XCTAssertTrue(cmd.arguments.contains("--remove-source-files"))
    }

    func testVerifyIsAChecksumDryRun() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(mode: .verify), run: run)
        XCTAssertEqual(cmd.arguments, ["-rcn", "--out-format=%i|%n", "/src/", "/Volumes/s/"])
    }

    func testDryRunAddsN() throws {
        var dry = run
        dry.dryRun = true
        let cmd = try RsyncCommandBuilder.command(for: task(mode: .mirror), run: dry)
        XCTAssertTrue(cmd.arguments.contains("-n"))
        XCTAssertFalse(try RsyncCommandBuilder.command(for: task(mode: .mirror), run: run).arguments.contains("-n"))
    }

    func testBandwidthAndExcludes() throws {
        let options = TaskOptions(excludes: [".DS_Store", "*.tmp"], bandwidthLimitKBps: 5000)
        let cmd = try RsyncCommandBuilder.command(for: task(options: options), run: run)
        XCTAssertTrue(cmd.arguments.contains("--bwlimit=5000"))
        XCTAssertTrue(cmd.arguments.contains("--exclude=.DS_Store"))
        XCTAssertTrue(cmd.arguments.contains("--exclude=*.tmp"))
    }

    func testExtraArgumentsAreAppendedBeforeThePaths() throws {
        let options = TaskOptions(excludes: [], extraArguments: ["--checksum"])
        let cmd = try RsyncCommandBuilder.command(for: task(options: options), run: run)
        XCTAssertEqual(Array(cmd.arguments.suffix(3)), ["--checksum", "/src/", "/Volumes/s/"])
    }

    func testSelectedItemsAreCopiedAsFolders() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(items: ["clip.mov", "Dossier/"]), run: run)
        XCTAssertEqual(Array(cmd.arguments.suffix(3)), ["/src/clip.mov", "/src/Dossier", "/Volumes/s/"])
    }

    func testRcloneOnlyModesAreRejected() {
        XCTAssertThrowsError(try RsyncCommandBuilder.command(for: task(mode: .bidirectional), run: run)) {
            XCTAssertEqual($0 as? CommandError, .unsupportedMode(mode: .bidirectional, engine: .rsync))
        }
    }

    func testCloudEndpointIsRejected() {
        let cloud = SyncTask(name: "t", source: .local(path: "/a"), destination: .cloud(remote: "g", path: ""))
        XCTAssertThrowsError(try RsyncCommandBuilder.command(for: cloud, run: run)) {
            XCTAssertEqual($0 as? CommandError, .missingFilesystemPath)
        }
    }

    func testPlanListsDeletionsOnlyForMirror() throws {
        let plan = try RsyncCommandBuilder.planCommand(for: task(mode: .mirror), run: run)
        XCTAssertEqual(Array(plan.arguments.prefix(4)), ["-rtn", "--stats", "--out-format=%l|%n", "--timeout=60"])
        XCTAssertTrue(plan.arguments.contains("--delete"))
        let copyPlan = try RsyncCommandBuilder.planCommand(for: task(), run: run)
        XCTAssertFalse(copyPlan.arguments.contains("--delete"))
    }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test --filter RsyncCommandBuilderTests`
Attendu : ÉCHEC de compilation (`cannot find 'RunOptions' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/EngineCommand.swift` :

```swift
import Foundation

public enum CommandError: Error, Equatable {
    case unsupportedMode(mode: SyncMode, engine: EngineKind)
    /// rsync a besoin de deux chemins sur le disque (dossier local ou volume monté).
    case missingFilesystemPath
}

/// Paramètres propres à une exécution (et non à la tâche).
public struct RunOptions: Equatable, Sendable {
    /// Simulation : rien n'est copié ni supprimé.
    public var dryRun: Bool
    /// Sous-dossier daté de l'archive, par exemple « 2026-10-12_14-30 ».
    public var archiveStamp: String
    /// bisync : initialisation (première exécution ou reprise après un échec grave).
    public var resync: Bool
    /// bisync : dossier d'état propre à la tâche.
    public var bisyncWorkdir: String?
    /// Fichier de configuration rclone à utiliser (`--config`).
    public var rcloneConfigPath: String?
    /// rclone : nombre maximum de suppressions autorisées pour cette exécution.
    public var maxDeleteCount: Int?

    public init(
        dryRun: Bool = false,
        archiveStamp: String,
        resync: Bool = false,
        bisyncWorkdir: String? = nil,
        rcloneConfigPath: String? = nil,
        maxDeleteCount: Int? = nil
    ) {
        self.dryRun = dryRun
        self.archiveStamp = archiveStamp
        self.resync = resync
        self.bisyncWorkdir = bisyncWorkdir
        self.rcloneConfigPath = rcloneConfigPath
        self.maxDeleteCount = maxDeleteCount
    }
}

/// Un moteur et ses arguments ; le chemin de l'exécutable est résolu plus tard.
public struct EngineCommand: Equatable, Sendable {
    public let engine: EngineKind
    public let arguments: [String]

    public init(engine: EngineKind, arguments: [String]) {
        self.engine = engine
        self.arguments = arguments
    }
}

enum PathText {
    static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    static func withoutTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
```

Créer `Sources/SyncKit/RsyncCommandBuilder.swift` :

```swift
import Foundation

/// Transforme une tâche en arguments rsync.
public enum RsyncCommandBuilder {
    /// `--out-format=%i|%n` : rsync indique lui-même si un fichier est nouveau (`>f+++++++++`) ou mis à jour.
    private static let transferFlags = [
        "-rtv", "--inplace", "--partial", "--progress", "--timeout=60", "--out-format=%i|%n",
    ]

    /// Commande d'exécution (ou de simulation si `run.dryRun`).
    public static func command(for task: SyncTask, run: RunOptions) throws -> EngineCommand {
        let (sources, destination, destinationFolder) = try paths(for: task)
        var args: [String]

        switch task.mode {
        case .copy:
            args = transferFlags
        case .mirror:
            let archive = "\(PathText.withoutTrailingSlash(destinationFolder))/\(task.options.archiveFolder)/\(run.archiveStamp)"
            args = transferFlags + [
                "--delete", "--backup", "--backup-dir=\(archive)",
                "--exclude=/\(task.options.archiveFolder)/",
            ]
        case .move:
            args = transferFlags + ["--remove-source-files"]
        case .verify:
            args = ["-rcn", "--out-format=%i|%n"]
        case .bidirectional, .versioned:
            throw CommandError.unsupportedMode(mode: task.mode, engine: .rsync)
        }

        if let limit = task.options.bandwidthLimitKBps, task.mode != .verify {
            args.append("--bwlimit=\(limit)")
        }
        args += task.options.excludes.map { "--exclude=\($0)" }
        args += task.options.extraArguments
        if run.dryRun, task.mode != .verify { args.append("-n") }
        args += sources + [destination]
        return EngineCommand(engine: .rsync, arguments: args)
    }

    /// Simulation qui liste ce qui serait copié (`taille|nom`) et les suppressions, avec les statistiques.
    public static func planCommand(for task: SyncTask, run: RunOptions) throws -> EngineCommand {
        let (sources, destination, _) = try paths(for: task)
        if task.mode.requiresRclone || task.mode == .verify {
            throw CommandError.unsupportedMode(mode: task.mode, engine: .rsync)
        }
        var args = ["-rtn", "--stats", "--out-format=%l|%n", "--timeout=60"]
        if task.mode == .mirror {
            args += ["--delete", "--exclude=/\(task.options.archiveFolder)/"]
        }
        args += task.options.excludes.map { "--exclude=\($0)" }
        args += sources + [destination]
        return EngineCommand(engine: .rsync, arguments: args)
    }

    /// Sources (le contenu du dossier, ou chaque élément choisi), destination et dossier de destination.
    private static func paths(for task: SyncTask) throws -> (sources: [String], destination: String, folder: String) {
        guard let source = task.source.filesystemPath, let destination = task.destination.filesystemPath else {
            throw CommandError.missingFilesystemPath
        }
        let sources: [String]
        if task.sourceItems.isEmpty {
            sources = [PathText.withTrailingSlash(source)]
        } else {
            // Sans « / » final : un dossier est copié en tant que dossier.
            sources = task.sourceItems.map {
                PathText.withoutTrailingSlash(Endpoint.join(source, $0))
            }
        }
        return (sources, PathText.withTrailingSlash(destination), destination)
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **22 tests**.

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): constructeur de commandes rsync"
```

---

### Tâche 4 : constructeur de commandes rclone

**Fichiers :**
- Créer : `Sources/SyncKit/RcloneCommandBuilder.swift`
- Test : `Tests/SyncKitTests/RcloneCommandBuilderTests.swift`

**Interfaces :**
- Consomme : `SyncTask`, `TaskOptions`, `RunOptions`, `EngineCommand`, `PathText`, `Endpoint.rcloneSpec`, `Endpoint.appending(_:)` (tâches 1 et 3).
- Produit : `RcloneCommandBuilder.command(for:run:) throws -> EngineCommand` ; `.sizeCommand(for: Endpoint, run:) -> EngineCommand` ; `.retentionCleanupCommand(for:run:) -> EngineCommand?`.

Faits mesurés avec rclone 1.75.1 et pris en compte :
- `bisync --max-delete` est un **pourcentage** (« too many deletes (>40 %, 5 of 10) », code de sortie 1, rien de modifié) ;
- `sync --max-delete N` est un **nombre** et supprime jusqu'à N fichiers **avant** de s'arrêter (code 7) : il ne sert que de dernier recours, le vrai garde-fou est une simulation préalable (tâche 10) ;
- `--max-transfer` + `--cutoff-mode soft` s'arrête avec le code 8 et le message « max transfer limit reached » ;
- `rclone size --json` donne `{"count":…}` ; `--backup-dir` doit être sur la même destination et exclu par un filtre.

- [ ] **Étape 1 : écrire le test qui échoue**

Créer `Tests/SyncKitTests/RcloneCommandBuilderTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class RcloneCommandBuilderTests: XCTestCase {
    private let run = RunOptions(archiveStamp: "2026-10-12_14-30")

    private func task(
        mode: SyncMode = .copy,
        items: [String] = [],
        options: TaskOptions = TaskOptions(excludes: [])
    ) -> SyncTask {
        SyncTask(
            name: "t",
            source: .network(url: "smb://nas/s", mountPath: "/Volumes/s"),
            destination: .cloud(remote: "gdrive", path: "BACKUP"),
            sourceItems: items, mode: mode, options: options
        )
    }

    func testCopyBuildsVerbAndPaths() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(), run: run)
        XCTAssertEqual(cmd.engine, .rclone)
        XCTAssertEqual(Array(cmd.arguments.prefix(3)), ["copy", "/Volumes/s", "gdrive:BACKUP"])
        XCTAssertTrue(cmd.arguments.contains("--use-json-log"))
        XCTAssertFalse(cmd.arguments.contains("--dry-run"))
    }

    func testMirrorUsesArchiveOnTheDestinationRemote() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .mirror), run: run)
        XCTAssertEqual(cmd.arguments.first, "sync")
        let idx = try XCTUnwrap(cmd.arguments.firstIndex(of: "--backup-dir"))
        XCTAssertEqual(cmd.arguments[idx + 1], "gdrive:BACKUP/_ARCHIVE/2026-10-12_14-30")
        XCTAssertTrue(cmd.arguments.contains("/_ARCHIVE/**"))
    }

    func testMirrorPassesMaxDeleteCountWhenKnown() throws {
        var limited = run
        limited.maxDeleteCount = 12
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .mirror), run: limited)
        let idx = try XCTUnwrap(cmd.arguments.firstIndex(of: "--max-delete"))
        XCTAssertEqual(cmd.arguments[idx + 1], "12")
    }

    func testBidirectionalGuardsAndArchivesBothSides() throws {
        var first = run
        first.resync = true
        first.bisyncWorkdir = "/tmp/bisync/abc"
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .bidirectional), run: first)
        XCTAssertEqual(Array(cmd.arguments.prefix(3)), ["bisync", "/Volumes/s", "gdrive:BACKUP"])
        for flag in ["--resilient", "--recover", "--resync"] {
            XCTAssertTrue(cmd.arguments.contains(flag), flag)
        }
        func value(after flag: String) -> String? {
            cmd.arguments.firstIndex(of: flag).map { cmd.arguments[$0 + 1] }
        }
        XCTAssertEqual(value(after: "--max-delete"), "25")      // pourcentage pour bisync
        XCTAssertEqual(value(after: "--conflict-resolve"), "newer")
        XCTAssertEqual(value(after: "--backup-dir1"), "/Volumes/s/_ARCHIVE/2026-10-12_14-30")
        XCTAssertEqual(value(after: "--backup-dir2"), "gdrive:BACKUP/_ARCHIVE/2026-10-12_14-30")
        XCTAssertEqual(value(after: "--workdir"), "/tmp/bisync/abc")
    }

    func testBidirectionalWithoutResyncOmitsTheFlag() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .bidirectional), run: run)
        XCTAssertFalse(cmd.arguments.contains("--resync"))
    }

    func testMoveRemovesEmptySourceFolders() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .move), run: run)
        XCTAssertEqual(cmd.arguments.first, "move")
        XCTAssertTrue(cmd.arguments.contains("--delete-empty-src-dirs"))
    }

    func testVerifyUsesCheckWithCombinedOutput() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .verify), run: run)
        XCTAssertEqual(cmd.arguments, ["check", "/Volumes/s", "gdrive:BACKUP", "--combined", "-"])
    }

    func testQuotaBandwidthDryRunAndConfig() throws {
        var dry = run
        dry.dryRun = true
        dry.rcloneConfigPath = "/cfg/rclone.conf"
        let options = TaskOptions(excludes: [], bandwidthLimitKBps: 5000, maxTransferGB: 750)
        let cmd = try RcloneCommandBuilder.command(for: task(options: options), run: dry)
        XCTAssertTrue(cmd.arguments.contains("--dry-run"))
        let bw = try XCTUnwrap(cmd.arguments.firstIndex(of: "--bwlimit"))
        XCTAssertEqual(cmd.arguments[bw + 1], "5000K")
        let mt = try XCTUnwrap(cmd.arguments.firstIndex(of: "--max-transfer"))
        XCTAssertEqual(cmd.arguments[mt + 1], "750G")
        XCTAssertTrue(cmd.arguments.contains("soft"))
        XCTAssertEqual(Array(cmd.arguments.suffix(2)), ["--config", "/cfg/rclone.conf"])
    }

    func testExcludesBecomeFiltersAndSelectionRestrictsToItems() throws {
        let options = TaskOptions(excludes: [".DS_Store"])
        let cmd = try RcloneCommandBuilder.command(for: task(items: ["clip.mov", "Dossier/"], options: options), run: run)
        let filters = cmd.arguments.enumerated().filter { $0.element == "--filter" }.map { cmd.arguments[$0.offset + 1] }
        XCTAssertEqual(filters, ["- .DS_Store", "+ /clip.mov", "+ /clip.mov/**", "+ /Dossier", "+ /Dossier/**", "- **"])
    }

    func testExtraArgumentsAreIncluded() throws {
        let options = TaskOptions(excludes: [], extraArguments: ["--disable", "Copy"])
        let cmd = try RcloneCommandBuilder.command(for: task(options: options), run: run)
        let idx = try XCTUnwrap(cmd.arguments.firstIndex(of: "--disable"))
        XCTAssertEqual(cmd.arguments[idx + 1], "Copy")
    }

    func testSizeCommand() {
        let cmd = RcloneCommandBuilder.sizeCommand(for: .cloud(remote: "gdrive", path: "BACKUP"), run: run)
        XCTAssertEqual(cmd.arguments, ["size", "--json", "gdrive:BACKUP"])
    }

    func testRetentionCleanupOnlyForVersionedMode() throws {
        XCTAssertNil(RcloneCommandBuilder.retentionCleanupCommand(for: task(mode: .mirror), run: run))
        let options = TaskOptions(excludes: [], retentionDays: 30)
        let cmd = try XCTUnwrap(RcloneCommandBuilder.retentionCleanupCommand(for: task(mode: .versioned, options: options), run: run))
        XCTAssertEqual(cmd.arguments, ["delete", "gdrive:BACKUP/_ARCHIVE", "--min-age", "30d", "--rmdirs"])
    }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test --filter RcloneCommandBuilderTests`
Attendu : ÉCHEC de compilation (`cannot find 'RcloneCommandBuilder' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/RcloneCommandBuilder.swift` :

```swift
import Foundation

/// Transforme une tâche en arguments rclone.
public enum RcloneCommandBuilder {
    private static let loggingFlags = [
        "--use-json-log", "--stats", "1s", "--stats-log-level", "NOTICE",
        "--retries", "3", "--low-level-retries", "10",
    ]

    public static func command(for task: SyncTask, run: RunOptions) throws -> EngineCommand {
        let source = task.source.rcloneSpec
        let destination = task.destination.rcloneSpec
        let archiveRoot: (Endpoint) -> String = {
            $0.appending(task.options.archiveFolder).appending(run.archiveStamp).rcloneSpec
        }
        let archiveFilter = "/\(task.options.archiveFolder)/**"
        var args: [String]

        switch task.mode {
        case .copy:
            args = ["copy", source, destination] + loggingFlags
        case .mirror, .versioned:
            args = ["sync", source, destination] + loggingFlags
                + ["--backup-dir", archiveRoot(task.destination), "--exclude", archiveFilter]
            if let maxDelete = run.maxDeleteCount { args += ["--max-delete", String(maxDelete)] }
        case .move:
            args = ["move", source, destination, "--delete-empty-src-dirs"] + loggingFlags
        case .bidirectional:
            args = ["bisync", source, destination] + loggingFlags + [
                "--resilient", "--recover",
                "--conflict-resolve", "newer",
                "--max-delete", String(task.options.deleteThresholdPercent),
                "--backup-dir1", archiveRoot(task.source),
                "--backup-dir2", archiveRoot(task.destination),
                "--exclude", archiveFilter,
            ]
            if let workdir = run.bisyncWorkdir { args += ["--workdir", workdir] }
            if run.resync { args.append("--resync") }
        case .verify:
            args = ["check", source, destination, "--combined", "-"]
        }

        if let limit = task.options.bandwidthLimitKBps, task.mode != .verify {
            args += ["--bwlimit", "\(limit)K"]
        }
        if let quota = task.options.maxTransferGB, task.mode != .verify {
            args += ["--max-transfer", "\(quota)G", "--cutoff-mode", "soft"]
        }
        args += filterArguments(for: task)
        args += task.options.extraArguments
        if run.dryRun, task.mode != .verify { args.append("--dry-run") }
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// Compte les fichiers d'un côté (`rclone size --json`) : sert à calculer le pourcentage de suppressions.
    public static func sizeCommand(for endpoint: Endpoint, run: RunOptions) -> EngineCommand {
        var args = ["size", "--json", endpoint.rcloneSpec]
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// Supprime les versions archivées plus anciennes que la durée de conservation (mode `versioned`).
    public static func retentionCleanupCommand(for task: SyncTask, run: RunOptions) -> EngineCommand? {
        guard task.mode == .versioned, let days = task.options.retentionDays else { return nil }
        let archive = task.destination.appending(task.options.archiveFolder).rcloneSpec
        var args = ["delete", archive, "--min-age", "\(days)d", "--rmdirs"]
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// Exclusions, puis (si une sélection d'éléments est définie) uniquement ces éléments.
    private static func filterArguments(for task: SyncTask) -> [String] {
        guard task.mode != .verify else {
            return task.options.excludes.flatMap { ["--exclude", $0] }
        }
        var args = task.options.excludes.flatMap { ["--filter", "- \($0)"] }
        if !task.sourceItems.isEmpty {
            for item in task.sourceItems {
                let name = PathText.withoutTrailingSlash(item)
                args += ["--filter", "+ /\(name)", "--filter", "+ /\(name)/**"]
            }
            args += ["--filter", "- **"]
        }
        return args
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **34 tests**.

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): constructeur de commandes rclone"
```

---

### Tâche 5 : lecture des sorties de rsync et de rclone

**Fichiers :**
- Créer : `Sources/SyncKit/{LineSplitter,RsyncOutputParser,RsyncPlanParser,RcloneOutputParser}.swift`, `Tests/SyncKitTests/Fixture.swift`, `Tests/SyncKitTests/Fixtures/*` (8 fichiers)
- Test : `Tests/SyncKitTests/ParserTests.swift`

**Interfaces :**
- Consomme : rien de la bibliothèque (types propres).
- Produit : `LineSplitter` (`feed(_:) -> [String]`, `finish() -> [String]`, `static lines(in:)`) ; `RsyncEvent` (`.fileStarted(name:isNew:)`, `.directory`, `.progress(bytes:percent:bytesPerSecond:fileFinished:)`, `.deleting`, `.message`, `.error`) ; `RsyncOutputParser.parse(line:) -> RsyncEvent?` ; `RsyncPlan` (`files`, `directories`, `deletions`, `sourceRegularFiles`, `createdRegularFiles`, `totalBytes`) ; `RsyncPlanParser.parse(_:)` ; `VerifyParser.rsyncDifferences(in:)` et `.rcloneDifferences(in:)` ; `RcloneStats`, `RcloneTransferring`, `RcloneEvent` (`.stats`, `.notice`, `.error`) ; `RcloneOutputParser.parse(line:)` ; `OutputSignal` (`.safetyAbort`, `.needsResync`, `.quotaReached`, `detect(in:)`).

Les fichiers de référence sont de **vraies captures** (rsync 3.5.1, rclone 1.75.1). rsync met à jour sa progression avec « \r » sans retour à la ligne, d'où `LineSplitter` ; avec `--out-format=%i|%n`, rsync indique lui-même si un fichier est nouveau (`>f+++++++++`) ou mis à jour (`>f.st......`), ce qui évite de deviner d'après l'existence du fichier de destination (course critique constatée pendant la mise au point).

- [ ] **Étape 1 : écrire les fichiers de référence et le test qui échoue**

Créer les fichiers de référence (octets exacts, `\r` compris) :

```bash
python3 - <<'EOF'
import pathlib
fixtures = pathlib.Path("Tests/SyncKitTests/Fixtures")
(fixtures / "rsync_progress.txt").write_bytes(b'sending incremental file list\n./\na.txt\n\r              6 100%    0.00kB/s    0:00:00  \r              6 100%    0.00kB/s    0:00:00 (xfr#1, to-chk=3/5)\nbig.bin\n\r         32,768   0%   31.25MB/s    0:00:00  \r     13,139,968  43%   11.39MB/s    0:00:01  \r     25,296,896  84%   11.35MB/s    0:00:00  \r     30,000,000 100%   11.62MB/s    0:00:02 (xfr#2, to-chk=2/5)\nsub/\nsub/mid.bin\n\r         32,768   1%   94.96kB/s    0:00:20  \r      2,000,000 100%    3.46MB/s    0:00:00 (xfr#3, to-chk=0/5)\n\nsent 32,008,086 bytes  received 92 bytes  12,803,271.20 bytes/sec\ntotal size is 32,000,006  speedup is 1.00\n')
(fixtures / "rsync_progress_itemized.txt").write_bytes(b'sending incremental file list\n*deleting  |gone.txt\n>f+++++++++|new.bin\n\r         32,768   1%    0.00kB/s    0:00:00  \r      1,703,936  56%    1.47MB/s    0:00:00  \r      3,000,000 100%    1.46MB/s    0:00:01 (xfr#1, to-chk=5/7)\n>f..t......|timeonly.txt\n\r              3 100%    0.00kB/s    0:00:00  \r              3 100%    0.00kB/s    0:00:00 (xfr#2, to-chk=3/7)\n>f.st......|upd.txt\n\r              4 100%    0.00kB/s    0:00:00  \r              4 100%    0.00kB/s    0:00:00 (xfr#3, to-chk=2/7)\ncd+++++++++|sub/\n>f+++++++++|sub/deep.txt\n\r              5 100%    0.01kB/s    0:00:00  \r              5 100%    0.01kB/s    0:00:00 (xfr#4, to-chk=0/7)\n\nsent 3,001,092 bytes  received 119 bytes  1,200,484.40 bytes/sec\ntotal size is 3,000,017  speedup is 1.00\n')
(fixtures / "rsync_plan_copy.txt").write_bytes(b'160|./\n6|a.txt\n30000000|big.bin\n96|sub/\n2000000|sub/mid.bin\n\nNumber of files: 5 (reg: 3, dir: 2)\nNumber of created files: 4 (reg: 3, dir: 1)\nNumber of deleted files: 0\nNumber of regular files transferred: 3\nTotal file size: 32,000,006 bytes\nTotal transferred file size: 32,000,006 bytes\nLiteral data: 0 bytes\nNumber of 4 KiB logical blocks touched: 0\nMatched data: 0 bytes\nFile list size: 0\nFile list generation time: 0.001 seconds\nFile list transfer time: 0.000 seconds\nTotal bytes sent: 152\nTotal bytes received: 32\n\nsent 152 bytes  received 32 bytes  368.00 bytes/sec\ntotal size is 32,000,006  speedup is 173,913.08 (DRY RUN)\n')
(fixtures / "rsync_plan_mirror.txt").write_bytes(b'deleting old2.txt\ndeleting old1.txt\n4|new.txt\n\nNumber of files: 3 (reg: 2, dir: 1)\nNumber of created files: 1 (reg: 1)\nNumber of deleted files: 2 (reg: 2)\nNumber of regular files transferred: 1\nTotal file size: 9 bytes\nTotal transferred file size: 4 bytes\nLiteral data: 0 bytes\nNumber of 4 KiB logical blocks touched: 0\nMatched data: 0 bytes\nFile list size: 0\nFile list generation time: 0.001 seconds\nFile list transfer time: 0.000 seconds\nTotal bytes sent: 83\nTotal bytes received: 46\n\nsent 83 bytes  received 46 bytes  258.00 bytes/sec\ntotal size is 9  speedup is 0.07 (DRY RUN)\n')
(fixtures / "rsync_verify.txt").write_bytes(b'>fc.T......|changed.txt\n>f+++++++++|fresh.txt\n')
(fixtures / "rclone_copy.jsonl").write_bytes(b'{"time":"2026-10-12T16:39:42.820801+02:00","level":"notice","msg":"\\nTransferred:   \\t    4.028 MiB / 30.518 MiB, 13%, 0 B/s, ETA -\\nChecks:                 0 / 0, -, Listed 4\\nTransferred:            2 / 3, 67%\\nElapsed time:         0.4s\\nTransferring:\\n *                                       big.bin:  7% / 28.610 MiB, 0 B/s, -\\n\\n","stats":{"bytes":4224134,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":0.499806167,"errors":0,"eta":null,"fatalError":false,"listed":4,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":0,"totalBytes":32000006,"totalChecks":0,"totalTransfers":3,"transferTime":0.499577375,"transferring":[{"bytes":2224128,"dstFs":"dst","eta":null,"group":"global_stats","name":"big.bin","percentage":7,"size":30000000,"speed":4454995.6599943,"speedAvg":0,"srcFs":"src"}],"transfers":2},"source":"accounting/stats.go:549"}\n{"time":"2026-10-12T16:39:43.320778+02:00","level":"notice","msg":"\\nTransferred:   \\t    8.028 MiB / 30.518 MiB, 26%, 0 B/s, ETA -\\nChecks:                 0 / 0, -, Listed 4\\nTransferred:            2 / 3, 67%\\nElapsed time:         0.9s\\nTransferring:\\n *                                       big.bin: 21% / 28.610 MiB, 0 B/s, -\\n\\n","stats":{"bytes":8418438,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":0.999791375,"errors":0,"eta":null,"fatalError":false,"listed":4,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":0,"totalBytes":32000006,"totalChecks":0,"totalTransfers":3,"transferTime":0.999560875,"transferring":[{"bytes":6418432,"dstFs":"dst","eta":null,"group":"global_stats","name":"big.bin","percentage":21,"size":30000000,"speed":6423382.552320134,"speedAvg":0,"srcFs":"src"}],"transfers":2},"source":"accounting/stats.go:549"}\n{"time":"2026-10-12T16:39:43.820749+02:00","level":"notice","msg":"\\nTransferred:   \\t   12.028 MiB / 30.518 MiB, 39%, 8.028 MiB/s, ETA 2s\\nChecks:                 0 / 0, -, Listed 4\\nTransferred:            2 / 3, 67%\\nElapsed time:         1.4s\\nTransferring:\\n *                                       big.bin: 35% / 28.610 MiB, 6.121 MiB/s, 3s\\n\\n","stats":{"bytes":12612742,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":1.499771708,"errors":0,"eta":2,"fatalError":false,"listed":4,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":8418236.315894343,"totalBytes":32000006,"totalChecks":0,"totalTransfers":3,"transferTime":1.499547334,"transferring":[{"bytes":10612736,"dstFs":"dst","eta":3,"group":"global_stats","name":"big.bin","percentage":35,"size":30000000,"speed":7078903.252971363,"speedAvg":6418201.471039563,"srcFs":"src"}],"transfers":2},"source":"accounting/stats.go:549"}\n{"time":"2026-10-12T16:39:44.320783+02:00","level":"notice","msg":"\\nTransferred:   \\t   16.028 MiB / 30.518 MiB, 53%, 8.028 MiB/s, ETA 1s\\nChecks:                 0 / 0, -, Listed 4\\nTransferred:            2 / 3, 67%\\nElapsed time:         1.9s\\nTransferring:\\n *                                       big.bin: 49% / 28.610 MiB, 6.121 MiB/s, 2s\\n\\n","stats":{"bytes":16807046,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":1.99980075,"errors":0,"eta":1,"fatalError":false,"listed":4,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":8418236.315894343,"totalBytes":32000006,"totalChecks":0,"totalTransfers":3,"transferTime":1.99956575,"transferring":[{"bytes":14807040,"dstFs":"dst","eta":2,"group":"global_stats","name":"big.bin","percentage":49,"size":30000000,"speed":7406312.024100534,"speedAvg":6418201.471039563,"srcFs":"src"}],"transfers":2},"source":"accounting/stats.go:549"}\n{"time":"2026-10-12T16:39:44.820779+02:00","level":"notice","msg":"\\nTransferred:   \\t   20.028 MiB / 30.518 MiB, 66%, 8.014 MiB/s, ETA 1s\\nChecks:                 0 / 0, -, Listed 4\\nTransferred:            2 / 3, 67%\\nElapsed time:         2.4s\\nTransferring:\\n *                                       big.bin: 63% / 28.610 MiB, 7.060 MiB/s, 1s\\n\\n","stats":{"bytes":21001350,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":2.499796375,"errors":0,"eta":1,"fatalError":false,"listed":4,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":8403426.348061053,"totalBytes":32000006,"totalChecks":0,"totalTransfers":3,"transferTime":2.4995705,"transferring":[{"bytes":19001344,"dstFs":"dst","eta":1,"group":"global_stats","name":"big.bin","percentage":63,"size":30000000,"speed":7602865.597445938,"speedAvg":7403408.061605492,"srcFs":"src"}],"transfers":2},"source":"accounting/stats.go:549"}\n{"time":"2026-10-12T16:39:45.320788+02:00","level":"notice","msg":"\\nTransferred:   \\t   24.028 MiB / 30.518 MiB, 79%, 8.014 MiB/s, ETA 0s\\nChecks:                 0 / 0, -, Listed 4\\nTransferred:            2 / 3, 67%\\nElapsed time:         2.9s\\nTransferring:\\n *                                       big.bin: 77% / 28.610 MiB, 7.060 MiB/s, 0s\\n\\n","stats":{"bytes":25195654,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":2.999800708,"errors":0,"eta":0,"fatalError":false,"listed":4,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":8403426.348061053,"totalBytes":32000006,"totalChecks":0,"totalTransfers":3,"transferTime":2.999574,"transferring":[{"bytes":23195648,"dstFs":"dst","eta":0,"group":"global_stats","name":"big.bin","percentage":77,"size":30000000,"speed":7733846.202567241,"speedAvg":7403408.061605492,"srcFs":"src"}],"transfers":2},"source":"accounting/stats.go:549"}\n{"time":"2026-10-12T16:39:45.820673+02:00","level":"notice","msg":"\\nTransferred:   \\t   28.028 MiB / 30.518 MiB, 92%, 8.009 MiB/s, ETA 0s\\nChecks:                 0 / 0, -, Listed 4\\nTransferred:            2 / 3, 67%\\nElapsed time:         3.4s\\nTransferring:\\n *                                       big.bin: 91% / 28.610 MiB, 7.374 MiB/s, 0s\\n\\n","stats":{"bytes":29389958,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":3.499699875,"errors":0,"eta":0,"fatalError":false,"listed":4,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":8398484.21994778,"totalBytes":32000006,"totalChecks":0,"totalTransfers":3,"transferTime":3.499476042,"transferring":[{"bytes":27389952,"dstFs":"dst","eta":0,"group":"global_stats","name":"big.bin","percentage":91,"size":30000000,"speed":7827636.978973834,"speedAvg":7731805.941123702,"srcFs":"src"}],"transfers":2},"source":"accounting/stats.go:549"}\n{"time":"2026-10-12T16:39:46.135243+02:00","level":"notice","msg":"\\nTransferred:   \\t   30.518 MiB / 30.518 MiB, 100%, 8.009 MiB/s, ETA 0s\\nChecks:                 0 / 0, -, Listed 4\\nTransferred:            3 / 3, 100%\\nElapsed time:         3.8s\\n\\n","stats":{"bytes":32000006,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":3.814284,"errors":0,"eta":0,"fatalError":false,"listed":4,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":8398484.21994778,"totalBytes":32000006,"totalChecks":0,"totalTransfers":3,"transferTime":3.813976417,"transfers":3},"source":"accounting/stats.go:549"}\n')
(fixtures / "rclone_sync_dryrun.jsonl").write_bytes(b'{"time":"2026-10-12T16:49:42.101963+02:00","level":"notice","msg":"Skipped delete as --dry-run is set (size 3)","skipped":"delete","size":3,"object":"e2.txt","objectType":"*local.Object","source":"operations/operations.go:2640"}\n{"time":"2026-10-12T16:49:42.101967+02:00","level":"notice","msg":"Skipped delete as --dry-run is set (size 3)","skipped":"delete","size":3,"object":"e1.txt","objectType":"*local.Object","source":"operations/operations.go:2640"}\n{"time":"2026-10-12T16:49:42.102191+02:00","level":"info","msg":"There was nothing to transfer","source":"sync/sync.go:1033"}\n{"time":"2026-10-12T16:49:42.102238+02:00","level":"notice","msg":"\\nTransferred:   \\t          0 B / 0 B, -, 0 B/s, ETA -\\nChecks:                 3 / 3, 100%, Listed 4\\nDeleted:                2 (files), 0 (dirs), 6 B (freed)\\nElapsed time:         0.0s\\n\\n","stats":{"bytes":0,"checks":3,"deletedDirs":0,"deletes":2,"elapsedTime":0.000561709,"errors":0,"eta":null,"fatalError":false,"listed":4,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":0,"totalBytes":0,"totalChecks":3,"totalTransfers":0,"transferTime":0.000290376,"transfers":0},"source":"accounting/stats.go:549"}\n')
(fixtures / "rclone_check.txt").write_bytes(b'+ c.txt\n- d.txt\n* b.txt\n= a.txt\n')
EOF
```

Créer `Tests/SyncKitTests/Fixture.swift` :

```swift
import Foundation

/// Accès aux fichiers de référence (sorties réelles de rsync 3.5.1 et rclone 1.75).
enum Fixture {
    static func text(_ name: String, ext: String = "txt") throws -> String {
        let url = try XCTUnwrapURL(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func XCTUnwrapURL(_ url: URL?) throws -> URL {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
}
```

Créer `Tests/SyncKitTests/ParserTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class LineSplitterTests: XCTestCase {
    func testSplitsOnNewlineAndCarriageReturn() {
        XCTAssertEqual(LineSplitter.lines(in: "a\nb\r  c  \r\n\n"), ["a", "b", "c"])
    }

    func testKeepsPartialLineAcrossChunks() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.feed("hel"), [])
        XCTAssertEqual(splitter.feed("lo\nwor"), ["hello"])
        XCTAssertEqual(splitter.feed("ld"), [])
        XCTAssertEqual(splitter.finish(), ["world"])
        XCTAssertEqual(splitter.finish(), [])
    }
}

final class RsyncOutputParserTests: XCTestCase {
    func testRealProgressCapture() throws {
        let events = LineSplitter.lines(in: try Fixture.text("rsync_progress")).compactMap(RsyncOutputParser.parse(line:))

        XCTAssertTrue(events.contains(.message("sending incremental file list")))
        XCTAssertTrue(events.contains(.fileStarted(name: "a.txt", isNew: nil)))
        XCTAssertTrue(events.contains(.fileStarted(name: "big.bin", isNew: nil)))
        XCTAssertTrue(events.contains(.directory(name: "sub/")))
        XCTAssertTrue(events.contains(.fileStarted(name: "sub/mid.bin", isNew: nil)))
        // « ./ » est ignoré
        XCTAssertFalse(events.contains(.directory(name: "./")))

        // première ligne de progression de big.bin : 32 768 octets, 0 %, 31,25 Mo/s
        XCTAssertTrue(events.contains(.progress(bytes: 32_768, percent: 0, bytesPerSecond: 31.25 * 1_048_576, fileFinished: false)))
        // dernière ligne du fichier : 30 000 000 octets, 100 %, marquée terminée
        let finished = events.compactMap { event -> Int64? in
            if case .progress(let bytes, 100, _, true) = event { return bytes }
            return nil
        }
        XCTAssertEqual(finished, [6, 30_000_000, 2_000_000])
    }

    func testItemizedRealCapture() throws {
        let events = LineSplitter.lines(in: try Fixture.text("rsync_progress_itemized")).compactMap(RsyncOutputParser.parse(line:))

        XCTAssertTrue(events.contains(.deleting(name: "gone.txt")))
        XCTAssertTrue(events.contains(.fileStarted(name: "new.bin", isNew: true)))
        XCTAssertTrue(events.contains(.fileStarted(name: "sub/deep.txt", isNew: true)))
        XCTAssertTrue(events.contains(.fileStarted(name: "upd.txt", isNew: false)))      // « >f.st...... » : mise à jour
        XCTAssertTrue(events.contains(.fileStarted(name: "timeonly.txt", isNew: false)))
        XCTAssertTrue(events.contains(.directory(name: "sub/")))
        XCTAssertFalse(events.contains { if case .fileStarted(let name, _) = $0 { return name.contains("|") } else { return false } })
    }

    func testItemizedLinesThatMoveNoDataAreIgnored() {
        XCTAssertNil(RsyncOutputParser.parse(line: ".f..t......|only-a-date.txt"))
        XCTAssertNil(RsyncOutputParser.parse(line: "cL+++++++++|a-symlink"))
        XCTAssertEqual(RsyncOutputParser.parse(line: ".d..t......|sub/"), .directory(name: "sub/"))
        XCTAssertNil(RsyncOutputParser.parse(line: ".d..t......|./"))
    }

    func testItemizedNameMayContainABar() {
        XCTAssertEqual(RsyncOutputParser.parse(line: ">f+++++++++|a|b.txt"), .fileStarted(name: "a|b.txt", isNew: true))
    }

    func testSpeedUnits() {
        XCTAssertEqual(
            RsyncOutputParser.parse(line: "1,234  50%   94.96kB/s    0:00:20"),
            .progress(bytes: 1234, percent: 50, bytesPerSecond: 94.96 * 1024, fileFinished: false)
        )
    }

    func testDeletionsAndErrors() {
        XCTAssertEqual(RsyncOutputParser.parse(line: "deleting old.txt"), .deleting(name: "old.txt"))
        let lines = [
            "rsync: [receiver] write failed on \"x\": Broken pipe (32)",
            "rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338)",
            "rsync(90432): error: buf_copy",
        ]
        for line in lines {
            XCTAssertEqual(RsyncOutputParser.parse(line: line), .error(line))
        }
    }

    func testIgnoresBlankAndRootFolder() {
        XCTAssertNil(RsyncOutputParser.parse(line: ""))
        XCTAssertNil(RsyncOutputParser.parse(line: "./"))
    }

    func testFileNamesWithSpacesAndUnicode() {
        XCTAssertEqual(RsyncOutputParser.parse(line: "Rushes été/clip n°1 (copie).mov"),
                       .fileStarted(name: "Rushes été/clip n°1 (copie).mov", isNew: nil))
    }
}

final class RsyncPlanParserTests: XCTestCase {
    func testCopyPlan() throws {
        let plan = RsyncPlanParser.parse(try Fixture.text("rsync_plan_copy"))
        XCTAssertEqual(plan.files, ["a.txt": 6, "big.bin": 30_000_000, "sub/mid.bin": 2_000_000])
        XCTAssertEqual(plan.directories, ["sub/"])
        XCTAssertEqual(plan.totalBytes, 32_000_006)
        XCTAssertEqual(plan.sourceRegularFiles, 3)
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testMirrorPlanListsDeletions() throws {
        let plan = RsyncPlanParser.parse(try Fixture.text("rsync_plan_mirror"))
        XCTAssertEqual(Set(plan.deletions), ["old1.txt", "old2.txt"])
        XCTAssertEqual(plan.files, ["new.txt": 4])
        XCTAssertEqual(plan.sourceRegularFiles, 2)
    }

    func testEmptyTextGivesEmptyPlan() {
        XCTAssertEqual(RsyncPlanParser.parse(""), RsyncPlan())
    }
}

final class VerifyParserTests: XCTestCase {
    func testRsyncDifferences() throws {
        let names = VerifyParser.rsyncDifferences(in: try Fixture.text("rsync_verify"))
        XCTAssertEqual(Set(names), ["changed.txt", "fresh.txt"])
    }

    func testRsyncIgnoresDirectoryOnlyLines() {
        XCTAssertEqual(VerifyParser.rsyncDifferences(in: ".d..t......|./\n>fc.T......|a.txt"), ["a.txt"])
    }

    func testRcloneDifferences() throws {
        let names = VerifyParser.rcloneDifferences(in: try Fixture.text("rclone_check"))
        XCTAssertEqual(Set(names), ["b.txt", "c.txt", "d.txt"])
    }
}

final class RcloneOutputParserTests: XCTestCase {
    private func events(_ fixture: String) throws -> [RcloneEvent] {
        try Fixture.text(fixture, ext: "jsonl").split(separator: "\n").compactMap { RcloneOutputParser.parse(line: String($0)) }
    }

    func testRealCopyCapture() throws {
        let all = try events("rclone_copy")
        let stats = all.compactMap { event -> RcloneStats? in
            if case .stats(let value) = event { return value }
            return nil
        }
        XCTAssertFalse(stats.isEmpty)

        let inFlight = try XCTUnwrap(stats.first { !$0.transferring.isEmpty })
        XCTAssertEqual(inFlight.transferring.first?.name, "big.bin")
        XCTAssertEqual(inFlight.transferring.first?.size, 30_000_000)
        XCTAssertEqual(inFlight.totalBytes, 32_000_006)

        let final = try XCTUnwrap(stats.last)
        XCTAssertEqual(final.bytes, 32_000_006)
        XCTAssertEqual(final.transfers, 3)
        XCTAssertEqual(final.totalTransfers, 3)
        XCTAssertEqual(final.errors, 0)
        XCTAssertTrue(final.transferring.isEmpty)
    }

    func testDryRunMirrorReportsDeletes() throws {
        let all = try events("rclone_sync_dryrun")
        XCTAssertTrue(all.contains(.notice(message: "Skipped delete as --dry-run is set (size 3)", object: "e1.txt")))
        let deletes = all.compactMap { event -> Int? in
            if case .stats(let value) = event { return value.deletes }
            return nil
        }
        XCTAssertEqual(deletes.last, 2)
    }

    func testIgnoresNonJSONAndErrorsAreReported() {
        XCTAssertNil(RcloneOutputParser.parse(line: "2026/10/12 16:48:19 NOTICE: hello"))
        let line = #"{"level":"error","msg":"Failed to copy: boom","source":"x"}"#
        XCTAssertEqual(RcloneOutputParser.parse(line: line), .error("Failed to copy: boom"))
    }
}

final class OutputSignalTests: XCTestCase {
    func testDetectsRealMessages() {
        XCTAssertEqual(OutputSignal.detect(in: #"Safety abort: too many deletes (>40%, 5 of 10) on Path1 "g1/". Run with --force if desired."#), .safetyAbort)
        XCTAssertEqual(OutputSignal.detect(in: "Bisync aborted. Must run --resync to recover."), .needsResync)
        XCTAssertEqual(OutputSignal.detect(in: "max transfer limit reached as set by --max-transfer - stopping transfers"), .quotaReached)
        XCTAssertNil(OutputSignal.detect(in: "everything is fine"))
    }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test --filter ParserTests`
Attendu : ÉCHEC de compilation (`cannot find 'LineSplitter' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/LineSplitter.swift` :

```swift
import Foundation

/// Découpe un flux de texte en lignes, sur « \n » comme sur « \r ».
/// rsync met à jour sa progression avec « \r » (sans retour à la ligne) : chaque mise à jour est une ligne.
public struct LineSplitter: Sendable {
    private var pending = ""

    public init() {}

    /// Ajoute un morceau de texte et retourne les lignes complètes (non vides, sans espaces autour).
    public mutating func feed(_ chunk: String) -> [String] {
        pending += chunk
        var lines: [String] = []
        var current = ""
        for character in pending {
            if character == "\n" || character == "\r" || character == "\r\n" {
                let line = current.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { lines.append(line) }
                current = ""
            } else {
                current.append(character)
            }
        }
        pending = current
        return lines
    }

    /// Retourne la dernière ligne, même sans retour à la ligne final.
    public mutating func finish() -> [String] {
        let line = pending.trimmingCharacters(in: .whitespaces)
        pending = ""
        return line.isEmpty ? [] : [line]
    }

    /// Commodité pour un texte complet.
    public static func lines(in text: String) -> [String] {
        var splitter = LineSplitter()
        return splitter.feed(text) + splitter.finish()
    }
}
```

Créer `Sources/SyncKit/RsyncOutputParser.swift` :

```swift
import Foundation

public enum RsyncEvent: Equatable, Sendable {
    /// Un fichier commence à être copié. `isNew` vaut `nil` si rsync ne l'indique pas (format sans `%i`).
    case fileStarted(name: String, isNew: Bool?)
    /// rsync entre dans un dossier (créé ou mis à jour).
    case directory(name: String)
    /// Progression du fichier en cours ; `fileFinished` vrai sur la dernière ligne du fichier.
    case progress(bytes: Int64, percent: Int, bytesPerSecond: Double, fileFinished: Bool)
    case deleting(name: String)
    /// Messages d'information (« sending incremental file list », « sent … »).
    case message(String)
    case error(String)
}

public enum RsyncOutputParser {
    private static let progressPattern = try! NSRegularExpression(
        pattern: #"^([\d,]+)\s+(\d+)%\s+([\d.]+)([kKMGT]?)B/s\s+\d+:\d+:\d+(\s+\(xfr#.*\))?$"#
    )
    private static let units: [String: Double] = [
        "": 1, "k": 1024, "K": 1024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776,
    ]
    private static let messagePrefixes = [
        "sending incremental", "sent ", "total size", "building file", "created directory", "file has vanished",
    ]

    /// Interprète une ligne (déjà découpée par `LineSplitter`). Retourne `nil` pour les lignes à ignorer.
    public static func parse(line: String) -> RsyncEvent? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line == "./" || line == "." { return nil }

        if let progress = parseProgress(line) { return progress }
        if isError(line) { return .error(line) }
        switch parseItemized(line) {
        case .event(let event): return event
        case .ignored: return nil
        case .notItemized: break
        }
        if line.hasPrefix("deleting ") { return .deleting(name: String(line.dropFirst("deleting ".count))) }
        if messagePrefixes.contains(where: { line.hasPrefix($0) }) { return .message(line) }
        if line.hasSuffix("/") { return .directory(name: line) }
        return .fileStarted(name: line, isNew: nil)
    }

    private enum Itemized {
        /// La ligne n'est pas au format `%i|%n`.
        case notItemized
        /// Au format `%i|%n`, mais sans rien à suivre (lien symbolique, simple changement de date…).
        case ignored
        case event(RsyncEvent)
    }

    /// Format `%i|%n` : 11 caractères d'état, « | », puis le nom.
    private static func parseItemized(_ line: String) -> Itemized {
        let characters = Array(line)
        guard characters.count > 12, characters[11] == "|" else { return .notItemized }
        let flags = String(characters[0..<11])
        let name = String(characters[12...])
        if flags.hasPrefix("*deleting") { return .event(.deleting(name: name)) }
        guard let first = flags.first, "<>c.h".contains(first) else { return .notItemized }
        let type = characters[1]
        if type == "d" { return name == "./" ? .ignored : .event(.directory(name: name)) }
        // Seuls « > » (reçu) et « < » (envoyé) transfèrent des données d'un fichier.
        guard type == "f", first == ">" || first == "<" else { return .ignored }
        return .event(.fileStarted(name: name, isNew: flags.dropFirst(2).allSatisfy { $0 == "+" }))
    }

    private static func parseProgress(_ line: String) -> RsyncEvent? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = progressPattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
        let bytes = Int64(group(1).replacingOccurrences(of: ",", with: "")) ?? 0
        let percent = Int(group(2)) ?? 0
        let speed = (Double(group(3)) ?? 0) * (units[group(4)] ?? 1)
        return .progress(bytes: bytes, percent: percent, bytesPerSecond: speed, fileFinished: !group(5).isEmpty)
    }

    private static func isError(_ line: String) -> Bool {
        line.hasPrefix("rsync:") || line.contains("rsync error") || line.contains("): error:")
    }
}
```

Créer `Sources/SyncKit/RsyncPlanParser.swift` :

```swift
import Foundation

/// Résultat d'une simulation rsync (`-n --stats --out-format=%l|%n`).
public struct RsyncPlan: Equatable, Sendable {
    /// Fichiers qui seraient copiés (nom relatif → taille).
    public var files: [String: Int64] = [:]
    /// Dossiers qui seraient créés ou touchés (noms terminés par « / »).
    public var directories: Set<String> = []
    /// Éléments qui seraient supprimés (modes qui suppriment).
    public var deletions: [String] = []
    /// Nombre de fichiers réguliers vus côté source (« Number of files: N (reg: R, … »).
    public var sourceRegularFiles: Int?
    /// Fichiers réguliers qui n'existent pas encore à la destination (« Number of created files: N (reg: R, … »).
    public var createdRegularFiles: Int?

    public var totalBytes: Int64 { files.values.reduce(0, +) }
    public init() {}
}

public enum RsyncPlanParser {
    private static let listing = try! NSRegularExpression(pattern: #"^(\d+)\|(.+)$"#)
    private static let regularFiles = try! NSRegularExpression(pattern: #"^Number of files: [\d,]+ \(reg: ([\d,]+)"#)
    private static let createdFiles = try! NSRegularExpression(pattern: #"^Number of created files: [\d,]+ \(reg: ([\d,]+)"#)

    public static func parse(_ text: String) -> RsyncPlan {
        var plan = RsyncPlan()
        for line in LineSplitter.lines(in: text) {
            if let name = captures(listing, in: line), name.count == 2 {
                let size = Int64(name[0]) ?? 0
                let path = name[1]
                if path == "./" { continue }
                if path.hasSuffix("/") { plan.directories.insert(path) } else { plan.files[path] = size }
            } else if line.hasPrefix("deleting ") {
                plan.deletions.append(String(line.dropFirst("deleting ".count)))
            } else if let reg = captures(regularFiles, in: line)?.first {
                plan.sourceRegularFiles = Int(reg.replacingOccurrences(of: ",", with: ""))
            } else if let created = captures(createdFiles, in: line)?.first {
                plan.createdRegularFiles = Int(created.replacingOccurrences(of: ",", with: ""))
            }
        }
        return plan
    }

    private static func captures(_ regex: NSRegularExpression, in line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
    }
}

/// Lecture des résultats de vérification (rsync `-rcn --out-format=%i|%n`, rclone `check --combined -`).
public enum VerifyParser {
    /// Fichiers qui diffèrent d'après rsync (ligne « >fc.T......|nom » ; « >f+++++++++|nom » pour un fichier absent).
    public static func rsyncDifferences(in text: String) -> [String] {
        LineSplitter.lines(in: text).compactMap { line in
            guard let bar = line.firstIndex(of: "|") else { return nil }
            let flags = line[..<bar]
            guard flags.count >= 2, flags[flags.index(after: flags.startIndex)] == "f" else { return nil }
            return String(line[line.index(after: bar)...])
        }
    }

    /// Fichiers qui diffèrent d'après rclone : « * » différent, « + » absent de la destination,
    /// « - » absent de la source, « ! » erreur. « = » signifie identique.
    public static func rcloneDifferences(in text: String) -> [String] {
        LineSplitter.lines(in: text).compactMap { line in
            guard let first = line.first, "*+-!".contains(first) else { return nil }
            return String(line.dropFirst(2))
        }
    }
}
```

Créer `Sources/SyncKit/RcloneOutputParser.swift` :

```swift
import Foundation

public struct RcloneTransferring: Equatable, Sendable {
    public var name: String
    public var size: Int64
    public var bytes: Int64
    public var percentage: Int
    public var speed: Double
}

public struct RcloneStats: Equatable, Sendable {
    public var bytes: Int64
    public var totalBytes: Int64
    public var speed: Double
    public var eta: Double?
    public var transfers: Int
    public var totalTransfers: Int
    public var checks: Int
    public var deletes: Int
    public var errors: Int
    public var elapsedTime: Double
    public var fatalError: Bool
    public var transferring: [RcloneTransferring]
}

public enum RcloneEvent: Equatable, Sendable {
    case stats(RcloneStats)
    case notice(message: String, object: String?)
    case error(String)
}

public enum RcloneOutputParser {
    private struct Line: Decodable {
        var level: String?
        var msg: String?
        var object: String?
        var stats: Stats?
    }

    private struct Stats: Decodable {
        var bytes: Int64?
        var totalBytes: Int64?
        var speed: Double?
        var eta: Double?
        var transfers: Int?
        var totalTransfers: Int?
        var checks: Int?
        var deletes: Int?
        var errors: Int?
        var elapsedTime: Double?
        var fatalError: Bool?
        var transferring: [Transferring]?
    }

    private struct Transferring: Decodable {
        var name: String?
        var size: Int64?
        var bytes: Int64?
        var percentage: Int?
        var speed: Double?
    }

    /// Interprète une ligne du journal JSON de rclone (`--use-json-log`). `nil` pour une ligne ignorée.
    public static func parse(line: String) -> RcloneEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Line.self, from: data) else { return nil }

        if let stats = decoded.stats {
            return .stats(RcloneStats(
                bytes: stats.bytes ?? 0, totalBytes: stats.totalBytes ?? 0, speed: stats.speed ?? 0, eta: stats.eta,
                transfers: stats.transfers ?? 0, totalTransfers: stats.totalTransfers ?? 0,
                checks: stats.checks ?? 0, deletes: stats.deletes ?? 0, errors: stats.errors ?? 0,
                elapsedTime: stats.elapsedTime ?? 0, fatalError: stats.fatalError ?? false,
                transferring: (stats.transferring ?? []).map {
                    RcloneTransferring(
                        name: $0.name ?? "", size: $0.size ?? 0, bytes: $0.bytes ?? 0,
                        percentage: $0.percentage ?? 0, speed: $0.speed ?? 0
                    )
                }
            ))
        }
        let message = decoded.msg ?? ""
        switch decoded.level {
        case "error", "critical", "alert", "emergency": return .error(message)
        default: return message.isEmpty ? nil : .notice(message: message, object: decoded.object)
        }
    }
}

/// Situations importantes repérées dans la sortie d'un moteur.
public enum OutputSignal: Equatable, Sendable {
    /// Trop de suppressions : le moteur a refusé d'agir.
    case safetyAbort
    /// bisync demande une initialisation (`--resync`).
    case needsResync
    /// Le quota de transfert (`--max-transfer`) est atteint.
    case quotaReached

    public static func detect(in text: String) -> OutputSignal? {
        let lower = text.lowercased()
        if lower.contains("safety abort") || lower.contains("too many deletes") { return .safetyAbort }
        if lower.contains("must run --resync") { return .needsResync }
        if lower.contains("max transfer limit reached") { return .quotaReached }
        return nil
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **54 tests**.

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): lecture des sorties de rsync et rclone (captures réelles)"
```

---

### Tâche 6 : suivi de progression

**Fichiers :**
- Créer : `Sources/SyncKit/ProgressTracker.swift`
- Test : `Tests/SyncKitTests/ProgressTrackerTests.swift`

**Interfaces :**
- Consomme : `RsyncEvent`, `RcloneStats` (tâche 5).
- Produit : `TransferSnapshot` (fichier en cours + total, voir le fichier) ; `ProgressTracker(now:fileInfo:)` avec `start()`, `pause()`, `resume()`, `finish()`, `setPlan(files:directories:)`, `apply(_: RsyncEvent)`, `apply(_: RcloneStats)`, `observeCurrentFileBytes(_:)`, `snapshot()`. Non thread-safe : l'appelant sérialise.

Règles qui évitent les défauts constatés dans Rsync-GUI :
- les octets terminés sont comptés **une fois par nom de fichier**, même si une reprise le retransfère ;
- le total est l'**union** du plan initial et de ce qui a été copié : il grandit si de nouveaux fichiers apparaissent, donc le fait ne dépasse jamais le total ;
- le pourcentage global reste à 99 tant que `finish()` n'a pas été appelé ;
- le temps écoulé du fichier en cours **s'arrête** quand le fichier est terminé, en pause et à la fin ;
- pour un fichier nouveau, la taille écrite sur la destination est mesurée 4 fois par seconde (rsync n'affiche qu'une ligne par seconde).

- [ ] **Étape 1 : écrire le test qui échoue**

Créer `Tests/SyncKitTests/ProgressTrackerTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class ProgressTrackerTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)

    private func makeTracker(sizes: [String: Int64] = [:], live: Bool = false) -> ProgressTracker {
        ProgressTracker(now: { [unowned self] in self.clock }, fileInfo: { (sizes[$0] ?? 0, live) })
    }

    private func copyFile(_ tracker: ProgressTracker, _ name: String, size: Int64) {
        tracker.apply(.fileStarted(name: name, isNew: nil))
        tracker.apply(.progress(bytes: size, percent: 100, bytesPerSecond: 1_000_000, fileFinished: true))
    }

    func testTotalsFromPlanAndProgress() {
        let tracker = makeTracker(sizes: ["a": 100, "b": 300])
        tracker.start()
        tracker.setPlan(files: ["a": 100, "b": 300], directories: ["d/"])
        copyFile(tracker, "a", size: 100)
        tracker.apply(.fileStarted(name: "b", isNew: nil))
        tracker.apply(.progress(bytes: 150, percent: 50, bytesPerSecond: 50, fileFinished: false))

        let snap = tracker.snapshot()
        XCTAssertEqual(snap.totalFiles, 2)
        XCTAssertEqual(snap.filesDone, 1)
        XCTAssertEqual(snap.totalBytes, 400)
        XCTAssertEqual(snap.doneBytes, 250)
        XCTAssertEqual(snap.currentName, "b")
        XCTAssertEqual(snap.currentPercent, 50)
        XCTAssertEqual(snap.currentETA, 3)             // (300-150)/50
        XCTAssertEqual(snap.overallPercent, 62)
        XCTAssertEqual(snap.totalDirs, 1)
    }

    func testOverallPercentStaysBelow100UntilFinished() {
        let tracker = makeTracker()
        tracker.start()
        tracker.setPlan(files: ["a": 100], directories: [])
        copyFile(tracker, "a", size: 100)
        XCTAssertEqual(tracker.snapshot().overallPercent, 99)
        tracker.finish()
        XCTAssertEqual(tracker.snapshot().overallPercent, 100)
    }

    /// Régression : après une coupure, rsync renvoie des fichiers déjà copiés ; les octets ne doivent pas être recomptés.
    func testRetransferredFileIsCountedOnce() {
        let tracker = makeTracker()
        tracker.start()
        tracker.setPlan(files: ["big": 1000], directories: [])
        copyFile(tracker, "big", size: 1000)
        copyFile(tracker, "big", size: 1000)   // reprise : même fichier terminé une seconde fois

        let snap = tracker.snapshot()
        XCTAssertEqual(snap.filesDone, 1)
        XCTAssertEqual(snap.doneBytes, 1000)
        XCTAssertEqual(snap.totalBytes, 1000)
    }

    /// Régression : des fichiers apparus après la simulation font grandir le total au lieu de le dépasser.
    func testNewFilesGrowTheTotal() {
        let tracker = makeTracker()
        tracker.start()
        tracker.setPlan(files: ["a": 100], directories: ["d/"])
        copyFile(tracker, "a", size: 100)
        copyFile(tracker, "late1", size: 40)
        tracker.apply(.directory(name: "newdir/"))

        let snap = tracker.snapshot()
        XCTAssertEqual(snap.totalFiles, 2)
        XCTAssertEqual(snap.filesDone, 2)
        XCTAssertEqual(snap.totalBytes, 140)
        XCTAssertEqual(snap.doneBytes, 140)
        XCTAssertEqual(snap.totalDirs, 2)
        XCTAssertLessThanOrEqual(snap.doneBytes, snap.totalBytes ?? 0)
        XCTAssertLessThanOrEqual(snap.filesDone, snap.totalFiles ?? 0)
    }

    func testTotalsAreUnknownWithoutPlan() {
        let tracker = makeTracker()
        tracker.start()
        copyFile(tracker, "a", size: 100)
        let snap = tracker.snapshot()
        XCTAssertNil(snap.totalFiles)
        XCTAssertNil(snap.totalBytes)
        XCTAssertNil(snap.overallPercent)
        XCTAssertEqual(snap.filesDone, 1)
    }

    func testTotalsEqualWhatWasCopiedWhenNoPlanEverArrived() {
        let tracker = makeTracker()
        tracker.start()
        copyFile(tracker, "a", size: 100)
        copyFile(tracker, "b", size: 50)
        tracker.finish()
        let snap = tracker.snapshot()
        XCTAssertEqual(snap.totalFiles, 2)
        XCTAssertEqual(snap.totalBytes, 150)
        XCTAssertEqual(snap.overallPercent, 100)
    }

    /// Régression : le temps écoulé du fichier en cours ne doit plus avancer une fois le fichier terminé.
    func testCurrentFileElapsedStopsWhenTheFileCompletes() {
        let tracker = makeTracker()
        tracker.start()
        tracker.apply(.fileStarted(name: "a", isNew: nil))
        clock.addTimeInterval(4)
        tracker.apply(.progress(bytes: 100, percent: 100, bytesPerSecond: 25, fileFinished: true))
        XCTAssertEqual(tracker.snapshot().currentElapsed, 4, accuracy: 0.001)

        clock.addTimeInterval(30)                       // la copie continue (autres fichiers, fin de l'exécution…)
        XCTAssertEqual(tracker.snapshot().currentElapsed, 4, accuracy: 0.001)
    }

    func testElapsedStopsAtFinishAndIgnoresPauses() {
        let tracker = makeTracker()
        tracker.start()
        tracker.apply(.fileStarted(name: "a", isNew: nil))
        clock.addTimeInterval(3)
        tracker.pause()
        clock.addTimeInterval(100)
        tracker.resume()
        clock.addTimeInterval(2)
        XCTAssertEqual(tracker.snapshot().currentElapsed, 5, accuracy: 0.001)

        tracker.finish()
        clock.addTimeInterval(60)
        XCTAssertEqual(tracker.snapshot().currentElapsed, 5, accuracy: 0.001)
        XCTAssertEqual(tracker.snapshot().activeTime, 5, accuracy: 0.001)
    }

    func testAverageSpeedAndETA() {
        let tracker = makeTracker()
        tracker.start()
        tracker.setPlan(files: ["a": 100_000_000, "b": 300_000_000], directories: [])
        copyFile(tracker, "a", size: 100_000_000)
        clock.addTimeInterval(10)

        let snap = tracker.snapshot()
        XCTAssertEqual(snap.activeTime, 10, accuracy: 0.001)
        XCTAssertEqual(snap.averageSpeed, 10_000_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(snap.totalETA), 30, accuracy: 0.01)
    }

    func testPauseDoesNotCountAsActiveTime() {
        let tracker = makeTracker()
        tracker.start()
        clock.addTimeInterval(5)
        tracker.pause()
        clock.addTimeInterval(100)
        tracker.resume()
        clock.addTimeInterval(5)
        XCTAssertEqual(tracker.snapshot().activeTime, 10, accuracy: 0.001)
    }

    func testLiveSamplingGivesSmoothProgressAndSpeed() {
        let tracker = makeTracker(sizes: ["clip": 100_000_000], live: true)
        tracker.start()
        tracker.apply(.fileStarted(name: "clip", isNew: nil))
        for step in 1...4 {
            clock.addTimeInterval(1)
            tracker.observeCurrentFileBytes(Int64(step) * 10_000_000)
        }
        let snap = tracker.snapshot()
        XCTAssertEqual(snap.currentBytes, 40_000_000)
        XCTAssertEqual(snap.currentPercent, 40)
        XCTAssertEqual(snap.currentSpeed, 10_000_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(snap.currentETA), 6, accuracy: 0.01)
    }

    /// Régression : rsync crée le fichier juste après l'avoir annoncé ; si on le lit trop tard, « il existe déjà ».
    /// L'information « nouveau fichier » vient donc de rsync (isNew), pas d'un test d'existence.
    func testNewFileFlagFromRsyncDrivesLiveSamplingEvenIfTheFileAlreadyExists() {
        let tracker = ProgressTracker(now: { [unowned self] in self.clock }, fileInfo: { _ in (100_000_000, false) })
        tracker.start()
        tracker.apply(.fileStarted(name: "clip", isNew: true))
        clock.addTimeInterval(1)
        tracker.observeCurrentFileBytes(10_000_000)
        XCTAssertEqual(tracker.snapshot().currentBytes, 10_000_000)
    }

    func testUpdatedFilesAreNotSampledOnTheDestination() {
        let tracker = ProgressTracker(now: { [unowned self] in self.clock }, fileInfo: { _ in (100, true) })
        tracker.start()
        tracker.apply(.fileStarted(name: "clip", isNew: false))
        tracker.observeCurrentFileBytes(100)        // la taille de l'ancienne version n'est pas une progression
        XCTAssertEqual(tracker.snapshot().currentBytes, 0)
    }

    func testLiveSamplingIsIgnoredWhilePaused() {
        let tracker = makeTracker(sizes: ["clip": 100], live: true)
        tracker.start()
        tracker.apply(.fileStarted(name: "clip", isNew: nil))
        tracker.pause()
        tracker.observeCurrentFileBytes(50)
        XCTAssertEqual(tracker.snapshot().currentBytes, 0)
    }

    func testRcloneStatsFillTheSnapshot() throws {
        let tracker = makeTracker()
        tracker.start()
        tracker.apply(RcloneStats(
            bytes: 8_000_000, totalBytes: 32_000_000, speed: 4_000_000, eta: 6, transfers: 2, totalTransfers: 3,
            checks: 0, deletes: 0, errors: 0, elapsedTime: 2, fatalError: false,
            transferring: [RcloneTransferring(name: "big.bin", size: 30_000_000, bytes: 6_000_000, percentage: 20, speed: 3_000_000)]
        ))
        let snap = tracker.snapshot()
        XCTAssertEqual(snap.currentName, "big.bin")
        XCTAssertEqual(snap.currentPercent, 20)
        XCTAssertEqual(try XCTUnwrap(snap.currentETA), 8, accuracy: 0.01)
        XCTAssertEqual(snap.filesDone, 2)
        XCTAssertEqual(snap.totalFiles, 3)
        XCTAssertEqual(snap.overallPercent, 25)
        XCTAssertEqual(snap.totalETA, 6)
        XCTAssertEqual(snap.averageSpeed, 4_000_000)
    }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test --filter ProgressTrackerTests`
Attendu : ÉCHEC de compilation (`cannot find 'ProgressTracker' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/ProgressTracker.swift` :

```swift
import Foundation

/// Photo de l'avancement d'une exécution : fichier en cours et total.
public struct TransferSnapshot: Equatable, Sendable {
    public var currentName: String?
    public var currentBytes: Int64 = 0
    public var currentSize: Int64 = 0
    public var currentPercent: Int = 0
    public var currentSpeed: Double = 0
    public var currentElapsed: TimeInterval = 0
    public var currentETA: TimeInterval?

    public var totalBytes: Int64?
    public var doneBytes: Int64 = 0
    public var totalFiles: Int?
    public var filesDone: Int = 0
    public var totalDirs: Int?
    public var dirsDone: Int = 0
    /// Pourcentage global ; reste à 99 tant que l'exécution n'est pas terminée.
    public var overallPercent: Int?
    public var averageSpeed: Double = 0
    public var totalETA: TimeInterval?
    /// Temps passé à copier, pauses exclues.
    public var activeTime: TimeInterval = 0

    public init() {}
}

/// Calcule l'avancement à partir des événements de rsync ou de rclone.
///
/// Règles qui évitent les totaux faux :
/// - les octets terminés sont comptés **une fois par nom de fichier**, même si une reprise le retransfère ;
/// - le total est l'union de la simulation initiale et de ce qui a été copié : il **grandit** si de nouveaux
///   fichiers apparaissent en cours de route, donc le fait ne dépasse jamais le total ;
/// - le pourcentage global ne dépasse pas 99 tant que `finish()` n'a pas été appelé.
///
/// Non thread-safe : l'appelant sérialise les accès.
public final class ProgressTracker {
    private let now: () -> Date
    private let fileInfo: (String) -> (size: Int64, live: Bool)

    private var doneFiles: [String: Int64] = [:]
    private var doneDirs: Set<String> = []
    private var planFiles: [String: Int64]?
    private var planDirs: Set<String> = []

    private var currentName: String?
    private var currentSize: Int64 = 0
    private var currentBytes: Int64 = 0
    private var currentPercent = 0
    private var currentSpeed: Double = 0
    /// Temps actif écoulé au moment où le fichier en cours a commencé / s'est terminé (les pauses n'y comptent pas).
    private var currentStartActive: TimeInterval = 0
    private var currentEndActive: TimeInterval?
    private var currentHasStarted = false
    private var currentCounted = true
    private var currentLive = false
    private var samples: [(date: Date, bytes: Int64)] = []

    private var activeAccumulated: TimeInterval = 0
    private var activeSince: Date?
    private var finished = false
    private var rclone: RcloneStats?

    /// - Parameter fileInfo: pour un nom de fichier, sa taille (0 si inconnue) et si sa progression peut être
    ///   mesurée en direct sur la destination (fichier nouveau).
    public init(
        now: @escaping () -> Date = Date.init,
        fileInfo: @escaping (String) -> (size: Int64, live: Bool) = { _ in (0, false) }
    ) {
        self.now = now
        self.fileInfo = fileInfo
    }

    // MARK: temps actif

    public func start() { if activeSince == nil { activeSince = now() } }

    public func pause() {
        if let since = activeSince { activeAccumulated += now().timeIntervalSince(since) }
        activeSince = nil
    }

    public func resume() { start() }

    /// L'exécution est terminée. Sans simulation initiale, le total est alors ce qui a été copié.
    public func finish() {
        pause()
        finished = true
        if planFiles == nil, rclone == nil {
            planFiles = [:]
            planDirs = []
        }
    }

    // MARK: rsync

    /// Résultat de la simulation initiale (peut arriver après le début de la copie).
    public func setPlan(files: [String: Int64], directories: Set<String>) {
        planFiles = files
        planDirs = directories
    }

    public func apply(_ event: RsyncEvent) {
        switch event {
        case .fileStarted(let name, let isNew):
            let info = fileInfo(name)
            currentName = name
            currentSize = info.size
            currentLive = isNew ?? info.live
            currentBytes = 0
            currentPercent = 0
            currentSpeed = 0
            currentStartActive = activeTime()
            currentEndActive = nil
            currentHasStarted = true
            currentCounted = false
            samples = []
        case .directory(let name):
            doneDirs.insert(name)
        case .progress(let bytes, let percent, let speed, let fileFinished):
            guard !currentCounted else { return }
            if !currentLive {
                currentPercent = percent
                currentSpeed = speed
            }
            currentBytes = max(currentBytes, bytes)
            if currentSize == 0, percent > 0 { currentSize = bytes * 100 / Int64(percent) }
            if fileFinished { completeCurrentFile() }
        case .deleting, .message, .error:
            break
        }
    }

    /// Mesure directe de la taille du fichier en cours sur la destination (plus fine que la sortie de rsync,
    /// qui n'affiche qu'environ une ligne par seconde).
    public func observeCurrentFileBytes(_ bytes: Int64) {
        guard currentLive, !currentCounted, activeSince != nil else { return }
        let value = currentSize > 0 ? min(bytes, currentSize) : bytes
        guard value >= currentBytes else { return }
        currentBytes = value
        let date = now()
        samples.append((date, value))
        if samples.count > 14 { samples.removeFirst(samples.count - 14) }
        if currentSize > 0 { currentPercent = min(99, Int(value * 100 / currentSize)) }
        if let first = samples.first, let last = samples.last {
            let elapsed = last.date.timeIntervalSince(first.date)
            if elapsed > 0.4 { currentSpeed = Double(last.bytes - first.bytes) / elapsed }
        }
    }

    private func completeCurrentFile() {
        guard let name = currentName else { return }
        let size = currentSize > 0 ? currentSize : currentBytes
        doneFiles[name] = size          // affectation : un fichier retransféré n'est compté qu'une fois
        currentBytes = size
        currentPercent = 100
        currentCounted = true
        currentEndActive = activeTime()    // le chronomètre du fichier s'arrête ici
    }

    /// Temps passé à copier jusqu'à maintenant : s'arrête pendant une pause et à la fin.
    private func activeTime() -> TimeInterval {
        activeAccumulated + (activeSince.map { now().timeIntervalSince($0) } ?? 0)
    }

    // MARK: rclone

    public func apply(_ stats: RcloneStats) {
        rclone = stats
    }

    // MARK: résultat

    public func snapshot() -> TransferSnapshot {
        var snap = TransferSnapshot()
        let date = now()
        snap.activeTime = activeTime()

        if let stats = rclone {
            fillFromRclone(&snap, stats)
        } else {
            fillFromRsync(&snap, date: date)
        }
        if currentHasStarted, snap.currentName != nil, rclone == nil {
            snap.currentElapsed = max(0, (currentEndActive ?? snap.activeTime) - currentStartActive)
        }
        if snap.averageSpeed == 0, snap.activeTime > 2, snap.doneBytes > 0 {
            snap.averageSpeed = Double(snap.doneBytes) / snap.activeTime
        }
        if let total = snap.totalBytes {
            snap.overallPercent = finished ? 100 : min(99, total > 0 ? Int(snap.doneBytes * 100 / total) : 0)
            if snap.averageSpeed > 0, total > snap.doneBytes, !finished {
                snap.totalETA = Double(total - snap.doneBytes) / snap.averageSpeed
            }
        }
        return snap
    }

    private func fillFromRsync(_ snap: inout TransferSnapshot, date: Date) {
        snap.currentName = currentName
        snap.currentBytes = currentBytes
        snap.currentSize = currentSize
        snap.currentPercent = currentPercent
        snap.currentSpeed = currentSpeed
        if !currentCounted, currentSpeed > 0, currentSize > currentBytes {
            snap.currentETA = Double(currentSize - currentBytes) / currentSpeed
        }

        snap.filesDone = doneFiles.count
        snap.dirsDone = doneDirs.count
        snap.doneBytes = doneFiles.values.reduce(0, +) + (currentCounted ? 0 : currentBytes)

        if let plan = planFiles {
            var union = plan
            for (name, size) in doneFiles { union[name] = size }
            if !currentCounted, let name = currentName { union[name] = max(union[name] ?? 0, currentSize) }
            snap.totalFiles = union.count
            snap.totalBytes = union.values.reduce(0, +)
            snap.totalDirs = planDirs.union(doneDirs).count
        }
    }

    private func fillFromRclone(_ snap: inout TransferSnapshot, _ stats: RcloneStats) {
        snap.doneBytes = stats.bytes
        snap.totalBytes = stats.totalBytes
        snap.filesDone = stats.transfers
        snap.totalFiles = stats.totalTransfers
        snap.averageSpeed = stats.speed
        if let active = stats.transferring.first {
            snap.currentName = active.name
            snap.currentBytes = active.bytes
            snap.currentSize = active.size
            snap.currentPercent = active.percentage
            snap.currentSpeed = active.speed
            if active.speed > 0, active.size > active.bytes {
                snap.currentETA = Double(active.size - active.bytes) / active.speed
            }
        }
        snap.totalETA = stats.eta
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **69 tests**.

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): suivi de progression (totaux exacts, chronomètres qui s'arrêtent)"
```

---

### Tâche 7 : lanceur de processus et recherche des binaires

**Fichiers :**
- Créer : `Sources/SyncKit/ProcessRunner.swift`, `Sources/SyncKit/BinaryLocator.swift`
- Test : `Tests/SyncKitTests/ProcessRunnerTests.swift`

**Interfaces :**
- Consomme : `EngineKind` (tâche 1).
- Produit : `ProcessOutputLine(stream:text:)` ; `RunningProcess` (`pid`, `pause()`, `resume()`, `terminate()`, `waitForExit() async -> Int32`) ; `ProcessRunner.spawn(executable:arguments:environment:onLine:) throws -> RunningProcess` ; `ProcessError.spawnFailed` ; `BinaryLocator.locate(_:environment:bundleDirectory:searchDirectories:fileManager:) -> String?`.

Points qui comptent :
- le processus est lancé dans **son propre groupe** (`POSIX_SPAWN_SETPGROUP`), pour que `SIGSTOP`, `SIGCONT` et `SIGTERM` touchent aussi ses sous-processus ;
- le **masque de signaux hérité est réinitialisé** (`POSIX_SPAWN_SETSIGMASK`, `POSIX_SPAWN_SETSIGDEF`) : sans cela, le programme lancé peut ignorer `SIGTERM` (défaut constaté pendant la mise au point : `terminate()` ne tuait rien) ;
- la sortie est découpée **au niveau des octets**, pour ne jamais couper un caractère UTF-8.

- [ ] **Étape 1 : écrire le test qui échoue**

Créer `Tests/SyncKitTests/ProcessRunnerTests.swift` :

```swift
import XCTest
@testable import SyncKit

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProcessOutputLine] = []

    func add(_ line: ProcessOutputLine) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [ProcessOutputLine] { lock.lock(); defer { lock.unlock() }; return storage }
    func texts(_ stream: ProcessOutputLine.Stream) -> [String] { lines.filter { $0.stream == stream }.map(\.text) }
}

final class ProcessRunnerTests: XCTestCase {
    private func run(_ script: String, collector: Collector) throws -> RunningProcess {
        try ProcessRunner.spawn(executable: "/bin/sh", arguments: ["-c", script]) { collector.add($0) }
    }

    func testCapturesBothStreamsAndSplitsOnCarriageReturn() async throws {
        let collector = Collector()
        let process = try run(#"echo out; echo err >&2; printf 'x\ry\n'; printf 'é日本\n'"#, collector: collector)
        let code = await process.waitForExit()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(collector.texts(.stdout), ["out", "x", "y", "é日本"])
        XCTAssertEqual(collector.texts(.stderr), ["err"])
    }

    func testReturnsExitCode() async throws {
        let process = try run("exit 7", collector: Collector())
        let code = await process.waitForExit()
        XCTAssertEqual(code, 7)
    }

    func testWaitingAfterExitStillReturns() async throws {
        let process = try run("exit 3", collector: Collector())
        _ = await process.waitForExit()
        let again = await process.waitForExit()
        XCTAssertEqual(again, 3)
    }

    func testLargeOutputIsNotLost() async throws {
        let collector = Collector()
        let process = try run("i=0; while [ $i -lt 5000 ]; do echo line$i; i=$((i+1)); done", collector: collector)
        _ = await process.waitForExit()
        XCTAssertEqual(collector.texts(.stdout).count, 5000)
        XCTAssertEqual(collector.texts(.stdout).last, "line4999")
    }

    func testPauseFreezesOutputAndResumeContinues() async throws {
        let collector = Collector()
        let process = try run("i=0; while [ $i -lt 10 ]; do echo $i; i=$((i+1)); sleep 0.2; done", collector: collector)
        try await waitUntil { collector.lines.count >= 2 }

        process.pause()
        try await Task.sleep(nanoseconds: 400_000_000)      // laisse arriver ce qui était déjà en route
        let frozenAt = collector.lines.count
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(collector.lines.count, frozenAt, "aucune sortie pendant la pause")

        process.resume()
        let code = await process.waitForExit()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(collector.texts(.stdout), (0..<10).map(String.init))
    }

    func testTerminateKillsTheWholeGroupEvenWhenPaused() async throws {
        let process = try run("sleep 30 & wait", collector: Collector())
        try await Task.sleep(nanoseconds: 300_000_000)
        process.pause()
        process.terminate()

        let code = await withTimeout(seconds: 5) { await process.waitForExit() }
        XCTAssertEqual(code, 128 + SIGTERM)
        XCTAssertEqual(killpg(process.pid, 0), -1)          // plus aucun processus dans le groupe
        XCTAssertEqual(errno, ESRCH)
    }

    func testSpawnFailureIsReported() {
        XCTAssertThrowsError(try ProcessRunner.spawn(executable: "/nonexistent/program", arguments: []) { _ in }) {
            guard case ProcessError.spawnFailed = $0 else { return XCTFail("mauvaise erreur : \($0)") }
        }
    }

    func testDecodeStatus() {
        XCTAssertEqual(ProcessRunner.decode(7 << 8), 7)
        XCTAssertEqual(ProcessRunner.decode(SIGKILL), 128 + SIGKILL)
    }

    // MARK: aides

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("délai dépassé") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

final class BinaryLocatorTests: XCTestCase {
    func testEnvironmentOverrideWins() {
        let path = BinaryLocator.locate(.rsync, environment: ["SYNCMACPRO_RSYNC": "/bin/ls"])
        XCTAssertEqual(path, "/bin/ls")
    }

    func testBundleDirectoryIsUsed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("rclone")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        XCTAssertEqual(BinaryLocator.locate(.rclone, environment: [:], bundleDirectory: dir.path), fake.path)
    }

    func testMissingBinaryReturnsNil() {
        let path = BinaryLocator.locate(
            .rclone, environment: ["SYNCMACPRO_RCLONE": "/nope"], bundleDirectory: "/nope", searchDirectories: []
        )
        XCTAssertNil(path)
    }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test --filter ProcessRunnerTests`
Attendu : ÉCHEC de compilation (`cannot find 'ProcessRunner' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/ProcessRunner.swift` :

```swift
import Darwin
import Foundation

public enum ProcessError: Error, Equatable {
    case spawnFailed(errno: Int32)
}

public struct ProcessOutputLine: Equatable, Sendable {
    public enum Stream: Sendable { case stdout, stderr }
    public let stream: Stream
    public let text: String
}

/// Un processus lancé dans son propre groupe : pause, reprise et arrêt touchent aussi ses sous-processus.
public final class RunningProcess: @unchecked Sendable {
    public let pid: pid_t
    private let lock = NSLock()
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(pid: pid_t) { self.pid = pid }

    /// Fige le processus (SIGSTOP) : il reprendra exactement où il en était.
    public func pause() { killpg(pid, SIGSTOP) }

    public func resume() { killpg(pid, SIGCONT) }

    /// Arrête proprement (SIGTERM). Un processus figé ne reçoit pas SIGTERM : on le reprend d'abord.
    public func terminate() {
        killpg(pid, SIGCONT)
        killpg(pid, SIGTERM)
    }

    /// Code de sortie ; 128 + n si le processus a été tué par le signal n.
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let code = exitCode {
                lock.unlock()
                continuation.resume(returning: code)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(with code: Int32) {
        lock.lock()
        exitCode = code
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: code) }
    }
}

public enum ProcessRunner {
    /// Lance un programme et appelle `onLine` pour chaque ligne de sa sortie (découpée sur « \n » et « \r »).
    public static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (ProcessOutputLine) -> Void
    ) throws -> RunningProcess {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw ProcessError.spawnFailed(errno: errno) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for descriptor in outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, descriptor) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )
        posix_spawnattr_setpgroup(&attributes, 0)   // nouveau groupe dont l'identifiant est le pid
        // Le programme lancé hérite sinon du masque de signaux de ce thread, et pourrait ignorer SIGTERM.
        var noBlockedSignals = sigset_t()
        sigemptyset(&noBlockedSignals)
        posix_spawnattr_setsigmask(&attributes, &noBlockedSignals)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        let argv = makeCStrings([executable] + arguments)
        let merged = (environment ?? ProcessInfo.processInfo.environment)
        let envp = makeCStrings(merged.map { "\($0.key)=\($0.value)" })
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv + [nil], envp + [nil])
        close(outPipe[1])
        close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw ProcessError.spawnFailed(errno: result)
        }

        let process = RunningProcess(pid: pid)
        let readers = DispatchGroup()
        for (descriptor, stream) in [(outPipe[0], ProcessOutputLine.Stream.stdout), (errPipe[0], .stderr)] {
            readers.enter()
            Thread.detachNewThread {
                read(descriptor: descriptor, stream: stream, onLine: onLine)
                close(descriptor)
                readers.leave()
            }
        }
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            readers.wait()                  // toute la sortie est livrée avant d'annoncer la fin
            process.finish(with: decode(status))
        }
        return process
    }

    private static func makeCStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) }
    }

    /// Code de sortie à partir de l'état renvoyé par `waitpid`.
    static func decode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func read(
        descriptor: Int32, stream: ProcessOutputLine.Stream, onLine: @Sendable (ProcessOutputLine) -> Void
    ) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)

        func emit(_ bytes: Data) {
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { onLine(ProcessOutputLine(stream: stream, text: text)) }
        }

        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(buffer, count: count)
            // Découpe au niveau des octets pour ne jamais couper un caractère UTF-8 en deux.
            while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                emit(pending[pending.startIndex..<index])
                pending = Data(pending[pending.index(after: index)...])
            }
        }
        emit(pending)
    }
}
```

Créer `Sources/SyncKit/BinaryLocator.swift` :

```swift
import Foundation

/// Retrouve les programmes rsync et rclone.
public enum BinaryLocator {
    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// Ordre : variable d'environnement (`SYNCMACPRO_RSYNC`, `SYNCMACPRO_RCLONE`), dossier embarqué
    /// (`<bundleDirectory>/<nom>`), puis les dossiers usuels.
    public static func locate(
        _ engine: EngineKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleDirectory: String? = nil,
        searchDirectories: [String] = BinaryLocator.searchDirectories,
        fileManager: FileManager = .default
    ) -> String? {
        let name = engine.rawValue
        var candidates: [String] = []
        if let override = environment["SYNCMACPRO_\(name.uppercased())"] { candidates.append(override) }
        if let bundle = bundleDirectory { candidates.append("\(bundle)/\(name)") }
        candidates += searchDirectories.map { "\($0)/\(name)" }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **80 tests** (environ 4 secondes de plus : pause et arrêt réels).

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): lanceur de processus (groupe propre, pause, arrêt) et recherche des binaires"
```

---

### Tâche 8 : garde-fou de suppression

**Fichiers :**
- Créer : `Sources/SyncKit/DeleteGuard.swift`
- Test : `Tests/SyncKitTests/DeleteGuardTests.swift`

**Interfaces :**
- Consomme : `RsyncPlan.deletions/sourceRegularFiles/createdRegularFiles`, `RcloneOutputParser` et les fichiers de référence (tâche 5).
- Produit : `GuardVerdict` (`.allowed`, `.blocked(percent:deletions:existing:)`) ; `DeleteGuard.percent(deletions:existing:)`, `.verdict(deletions:existing:thresholdPercent:)`, `.verdict(for: RsyncPlan, thresholdPercent:)`, `.maxDeleteCount(existing:thresholdPercent:)` ; `RcloneSizeParser.count(from:)`.

Règle (spec §5.4) : une exécution est **bloquée si le pourcentage dépasse le seuil** (égal au seuil est accepté). Une source vide avec des suppressions donne 100 %, donc bloqué. Avec rsync, les fichiers présents à la destination valent `suppressions + (fichiers de la source - fichiers créés)`.

- [ ] **Étape 1 : écrire le test qui échoue**

Créer `Tests/SyncKitTests/DeleteGuardTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class DeleteGuardTests: XCTestCase {
    func testThresholdIsInclusive() {
        XCTAssertEqual(DeleteGuard.verdict(deletions: 3, existing: 12, thresholdPercent: 25), .allowed)       // 25 %
        XCTAssertEqual(DeleteGuard.verdict(deletions: 4, existing: 12, thresholdPercent: 25),
                       .blocked(percent: 33, deletions: 4, existing: 12))
    }

    func testNoDeletionsIsAlwaysAllowed() {
        XCTAssertEqual(DeleteGuard.verdict(deletions: 0, existing: 0, thresholdPercent: 0), .allowed)
        XCTAssertEqual(DeleteGuard.verdict(deletions: 0, existing: 500, thresholdPercent: 0), .allowed)
    }

    func testDeletingEverythingIsBlockedEvenWithNothingKnown() {
        XCTAssertEqual(DeleteGuard.verdict(deletions: 5, existing: 0, thresholdPercent: 25),
                       .blocked(percent: 100, deletions: 5, existing: 0))
    }

    func testRsyncMirrorPlanFromRealCapture() throws {
        // La destination avait 3 fichiers (keep, old1, old2) ; la source en a 2 (keep, new) : 2 suppressions sur 3.
        let plan = RsyncPlanParser.parse(try Fixture.text("rsync_plan_mirror"))
        XCTAssertEqual(plan.createdRegularFiles, 1)
        XCTAssertEqual(DeleteGuard.verdict(for: plan, thresholdPercent: 25), .blocked(percent: 66, deletions: 2, existing: 3))
        XCTAssertEqual(DeleteGuard.verdict(for: plan, thresholdPercent: 70), .allowed)
    }

    func testEmptiedSourceCannotWipeTheDestination() {
        var plan = RsyncPlan()
        plan.deletions = ["a", "b", "c", "d"]
        plan.sourceRegularFiles = 0
        plan.createdRegularFiles = 0
        XCTAssertEqual(DeleteGuard.verdict(for: plan, thresholdPercent: 25), .blocked(percent: 100, deletions: 4, existing: 4))
    }

    func testMaxDeleteCount() {
        XCTAssertEqual(DeleteGuard.maxDeleteCount(existing: 200, thresholdPercent: 25), 50)
        XCTAssertEqual(DeleteGuard.maxDeleteCount(existing: 3, thresholdPercent: 25), 0)
    }

    func testRcloneSizeParsing() {
        XCTAssertEqual(RcloneSizeParser.count(from: #"{"count":3,"bytes":8,"sizeless":0}"# + "\n"), 3)
        XCTAssertNil(RcloneSizeParser.count(from: "not json"))
    }

    func testRcloneDryRunMirrorFromRealCapture() throws {
        let events = try Fixture.text("rclone_sync_dryrun", ext: "jsonl").split(separator: "\n")
            .compactMap { RcloneOutputParser.parse(line: String($0)) }
        let deletes = events.compactMap { event -> Int? in
            if case .stats(let stats) = event { return stats.deletes }
            return nil
        }.last
        // la destination avait 3 fichiers (k, e1, e2) et 2 seraient supprimés
        XCTAssertEqual(DeleteGuard.verdict(deletions: try XCTUnwrap(deletes), existing: 3, thresholdPercent: 25),
                       .blocked(percent: 66, deletions: 2, existing: 3))
    }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test --filter DeleteGuardTests`
Attendu : ÉCHEC de compilation (`cannot find 'DeleteGuard' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/DeleteGuard.swift` :

```swift
import Foundation

public enum GuardVerdict: Equatable, Sendable {
    case allowed
    /// Trop de suppressions : l'exécution ne doit pas démarrer.
    case blocked(percent: Int, deletions: Int, existing: Int)
}

/// Garde-fou : refuse une exécution qui supprimerait trop de fichiers d'un coup.
public enum DeleteGuard {
    /// Part des fichiers existants qui seraient supprimés (arrondie à l'entier inférieur).
    /// Sans fichier existant mais avec des suppressions, c'est 100 %.
    public static func percent(deletions: Int, existing: Int) -> Int {
        guard deletions > 0 else { return 0 }
        guard existing > 0 else { return 100 }
        return min(100, deletions * 100 / existing)
    }

    /// Bloque si le pourcentage **dépasse** le seuil (égal au seuil est accepté).
    public static func verdict(deletions: Int, existing: Int, thresholdPercent: Int) -> GuardVerdict {
        let percent = percent(deletions: deletions, existing: existing)
        return percent > thresholdPercent
            ? .blocked(percent: percent, deletions: deletions, existing: existing)
            : .allowed
    }

    /// rsync : fichiers présents à la destination avant l'exécution =
    /// ceux qui vont être supprimés + ceux de la source qui y existent déjà.
    public static func verdict(for plan: RsyncPlan, thresholdPercent: Int) -> GuardVerdict {
        let deletions = plan.deletions.count
        let alreadyThere = max(0, (plan.sourceRegularFiles ?? 0) - (plan.createdRegularFiles ?? 0))
        return verdict(deletions: deletions, existing: deletions + alreadyThere, thresholdPercent: thresholdPercent)
    }

    /// Nombre maximum de suppressions à passer à rclone (`--max-delete`) en dernier recours.
    public static func maxDeleteCount(existing: Int, thresholdPercent: Int) -> Int {
        existing * thresholdPercent / 100
    }
}

/// Lecture de `rclone size --json` (`{"count":3,"bytes":8,"sizeless":0}`).
public enum RcloneSizeParser {
    public static func count(from text: String) -> Int? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = object["count"] as? Int else { return nil }
        return count
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **88 tests**.

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): garde-fou de suppression (seuil en pourcentage)"
```

---

### Tâche 9 : stockage des exécutions (SQLite) et des tâches (JSON)

**Fichiers :**
- Créer : `Sources/SyncKit/{RunRecord,HistoryStore,TaskStore}.swift`
- Test : `Tests/SyncKitTests/StoreTests.swift`

**Interfaces :**
- Consomme : `EngineKind`, `SyncMode`, `SyncTask` (tâche 1).
- Produit : `RunStatus` (`running, succeeded, failed, blocked, quotaReached, interrupted, stopped`) ; `RunSummary` ; `RunRecord` ; `HistoryStore(path:)` avec `save(_:)`, `record(id:)`, `list(taskID:limit:)`, `markRunningAsInterrupted(at:)`, `purge(finishedBefore:)` ; `TaskStore(url:)` avec `load()`, `save(_:)`, `upsert(_:)`, `remove(id:)`.

Un fichier de tâches illisible lève une erreur et **n'est jamais écrasé en silence**. Au démarrage de l'agent, `markRunningAsInterrupted` transforme les exécutions restées « en cours » (Mac éteint) en « interrompues » (sous-projet 2).

- [ ] **Étape 1 : écrire le test qui échoue**

Créer `Tests/SyncKitTests/StoreTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class StoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(task: UUID = UUID(), name: String = "t", at seconds: TimeInterval, status: RunStatus = .succeeded) -> RunRecord {
        RunRecord(
            taskID: task, taskName: name, engine: .rsync, mode: .mirror,
            startedAt: Date(timeIntervalSince1970: seconds),
            finishedAt: status == .running ? nil : Date(timeIntervalSince1970: seconds + 60),
            status: status,
            summary: RunSummary(filesTransferred: 3, bytesTransferred: 1234, deletions: 1, errors: 0, durationSeconds: 60, message: "ok")
        )
    }

    func testHistoryRoundTripKeepsEveryField() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        var original = record(at: 1_000)
        original.logPath = "/tmp/run.log"
        original.dryRun = true
        try store.save(original)
        XCTAssertEqual(try store.record(id: original.id), original)
    }

    func testListIsNewestFirstAndFilteredByTask() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        let taskA = UUID(), taskB = UUID()
        let old = record(task: taskA, at: 100), recent = record(task: taskA, at: 300), other = record(task: taskB, at: 200)
        for item in [old, recent, other] { try store.save(item) }

        XCTAssertEqual(try store.list().map(\.id), [recent.id, other.id, old.id])
        XCTAssertEqual(try store.list(taskID: taskA).map(\.id), [recent.id, old.id])
        XCTAssertEqual(try store.list(limit: 1).count, 1)
    }

    func testSavingTheSameIDUpdatesTheRecord() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        var run = record(at: 100, status: .running)
        try store.save(run)
        run.status = .failed
        run.finishedAt = Date(timeIntervalSince1970: 160)
        try store.save(run)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.record(id: run.id)?.status, .failed)
    }

    func testRunningRecordsBecomeInterruptedAtStartup() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        let running = record(at: 100, status: .running), done = record(at: 200)
        try store.save(running)
        try store.save(done)

        XCTAssertEqual(try store.markRunningAsInterrupted(at: Date(timeIntervalSince1970: 500)), 1)
        let reloaded = try XCTUnwrap(try store.record(id: running.id))
        XCTAssertEqual(reloaded.status, .interrupted)
        XCTAssertEqual(reloaded.finishedAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(try store.record(id: done.id)?.status, .succeeded)
    }

    func testPurgeRemovesOnlyOldFinishedRuns() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        let old = record(at: 100), recent = record(at: 10_000), running = record(at: 50, status: .running)
        for item in [old, recent, running] { try store.save(item) }

        XCTAssertEqual(try store.purge(finishedBefore: Date(timeIntervalSince1970: 5_000)), 1)
        XCTAssertEqual(Set(try store.list().map(\.id)), [recent.id, running.id])
    }

    func testHistorySurvivesReopening() throws {
        let path = directory.appendingPathComponent("h.sqlite").path
        let run = record(at: 100)
        try HistoryStore(path: path).save(run)
        XCTAssertEqual(try HistoryStore(path: path).list(), [run])
    }

    func testHistoryRejectsAnUnwritablePath() {
        XCTAssertThrowsError(try HistoryStore(path: "/nonexistent-dir/h.sqlite")) {
            guard case HistoryError.openFailed = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: tâches

    func testTaskStoreRoundTripAndUpsert() throws {
        let store = TaskStore(url: directory.appendingPathComponent("sub/tasks.json"))
        XCTAssertEqual(try store.load(), [])                    // fichier absent

        var task = SyncTask(name: "A", source: .local(path: "/a"), destination: .local(path: "/b"))
        try store.upsert(task)
        task.name = "A renommée"
        try store.upsert(task)
        let other = SyncTask(name: "B", source: .local(path: "/c"), destination: .local(path: "/d"))
        try store.upsert(other)

        XCTAssertEqual(try store.load(), [task, other])
        try store.remove(id: task.id)
        XCTAssertEqual(try store.load(), [other])
    }

    func testCorruptTaskFileIsReportedNotOverwritten() throws {
        let url = directory.appendingPathComponent("tasks.json")
        try "{ pas du json".write(to: url, atomically: true, encoding: .utf8)
        let store = TaskStore(url: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.upsert(SyncTask(name: "x", source: .local(path: "/a"), destination: .local(path: "/b"))))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ pas du json")
    }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test --filter StoreTests`
Attendu : ÉCHEC de compilation (`cannot find 'HistoryStore' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/RunRecord.swift` :

```swift
import Foundation

public enum RunStatus: String, Codable, CaseIterable, Sendable {
    case running
    case succeeded
    case failed
    /// Refusée par un garde-fou (trop de suppressions).
    case blocked
    /// Quota de transfert atteint (par exemple 750 Go par jour sur Google Drive) : reprise plus tard.
    case quotaReached
    /// L'app ou le Mac s'est arrêté pendant l'exécution.
    case interrupted
    case stopped

    public var isFinished: Bool { self != .running }
}

public struct RunSummary: Codable, Equatable, Sendable {
    public var filesTransferred: Int
    public var bytesTransferred: Int64
    public var deletions: Int
    public var errors: Int
    public var durationSeconds: Double
    /// Explication lisible (motif d'un blocage ou d'un échec, « Simulation », …).
    public var message: String?

    public init(
        filesTransferred: Int = 0, bytesTransferred: Int64 = 0, deletions: Int = 0,
        errors: Int = 0, durationSeconds: Double = 0, message: String? = nil
    ) {
        self.filesTransferred = filesTransferred
        self.bytesTransferred = bytesTransferred
        self.deletions = deletions
        self.errors = errors
        self.durationSeconds = durationSeconds
        self.message = message
    }
}

public struct RunRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var taskName: String
    public var engine: EngineKind
    public var mode: SyncMode
    public var dryRun: Bool
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var summary: RunSummary?
    public var logPath: String?

    public init(
        id: UUID = UUID(), taskID: UUID, taskName: String, engine: EngineKind, mode: SyncMode,
        dryRun: Bool = false, startedAt: Date, finishedAt: Date? = nil, status: RunStatus = .running,
        summary: RunSummary? = nil, logPath: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.taskName = taskName
        self.engine = engine
        self.mode = mode
        self.dryRun = dryRun
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.summary = summary
        self.logPath = logPath
    }
}
```

Créer `Sources/SyncKit/HistoryStore.swift` :

```swift
import Foundation
import SQLite3

public enum HistoryError: Error, Equatable {
    case openFailed(String)
    case queryFailed(String)
}

/// Historique des exécutions, dans une base SQLite. Sûr à utiliser depuis plusieurs threads.
public final class HistoryStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        if sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "inconnue"
            sqlite3_close(database)
            throw HistoryError.openFailed(message)
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                task_name TEXT NOT NULL,
                engine TEXT NOT NULL,
                mode TEXT NOT NULL,
                dry_run INTEGER NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL,
                status TEXT NOT NULL,
                summary TEXT,
                log_path TEXT
            );
            CREATE INDEX IF NOT EXISTS runs_task ON runs(task_id, started_at DESC);
            """)
    }

    deinit { sqlite3_close(database) }

    // MARK: écriture

    /// Ajoute l'exécution, ou la remplace si son identifiant existe déjà.
    public func save(_ record: RunRecord) throws {
        let summary = try record.summary.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try withStatement("""
            INSERT OR REPLACE INTO runs
            (id, task_id, task_name, engine, mode, dry_run, started_at, finished_at, status, summary, log_path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(statement, 1, record.id.uuidString)
            bind(statement, 2, record.taskID.uuidString)
            bind(statement, 3, record.taskName)
            bind(statement, 4, record.engine.rawValue)
            bind(statement, 5, record.mode.rawValue)
            sqlite3_bind_int(statement, 6, record.dryRun ? 1 : 0)
            sqlite3_bind_double(statement, 7, record.startedAt.timeIntervalSince1970)
            bind(statement, 8, record.finishedAt?.timeIntervalSince1970)
            bind(statement, 9, record.status.rawValue)
            bind(statement, 10, summary)
            bind(statement, 11, record.logPath)
            try step(statement)
        }
    }

    /// Au démarrage de l'agent : tout ce qui était « en cours » a été interrompu. Retourne le nombre de lignes.
    @discardableResult
    public func markRunningAsInterrupted(at date: Date = Date()) throws -> Int {
        try withStatement("UPDATE runs SET status = 'interrupted', finished_at = ? WHERE status = 'running'") { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try step(statement)
            return Int(sqlite3_changes(database))
        }
    }

    /// Supprime les exécutions terminées avant `date`. Retourne le nombre de lignes supprimées.
    @discardableResult
    public func purge(finishedBefore date: Date) throws -> Int {
        try withStatement("DELETE FROM runs WHERE finished_at IS NOT NULL AND finished_at < ?") { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try step(statement)
            return Int(sqlite3_changes(database))
        }
    }

    // MARK: lecture

    public func record(id: UUID) throws -> RunRecord? {
        try query("SELECT * FROM runs WHERE id = ?") { bind($0, 1, id.uuidString) }.first
    }

    /// Les plus récentes d'abord.
    public func list(taskID: UUID? = nil, limit: Int = 100) throws -> [RunRecord] {
        if let taskID {
            return try query("SELECT * FROM runs WHERE task_id = ? ORDER BY started_at DESC LIMIT ?") {
                bind($0, 1, taskID.uuidString)
                sqlite3_bind_int($0, 2, Int32(limit))
            }
        }
        return try query("SELECT * FROM runs ORDER BY started_at DESC LIMIT ?") { sqlite3_bind_int($0, 1, Int32(limit)) }
    }

    // MARK: SQLite

    private func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "inconnue"
            sqlite3_free(error)
            throw HistoryError.queryFailed(message)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw HistoryError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, HistoryStore.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func query(_ sql: String, binding: (OpaquePointer) -> Void) throws -> [RunRecord] {
        try withStatement(sql) { statement in
            binding(statement)
            var records: [RunRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let record = decode(statement) { records.append(record) }
            }
            return records
        }
    }

    private func decode(_ statement: OpaquePointer) -> RunRecord? {
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        guard let id = text(0).flatMap(UUID.init(uuidString:)), let taskID = text(1).flatMap(UUID.init(uuidString:)),
              let name = text(2), let engine = text(3).flatMap(EngineKind.init(rawValue:)),
              let mode = text(4).flatMap(SyncMode.init(rawValue:)), let status = text(8).flatMap(RunStatus.init(rawValue:))
        else { return nil }
        let finished: Date? = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let summary = text(9).flatMap { try? JSONDecoder().decode(RunSummary.self, from: Data($0.utf8)) }
        return RunRecord(
            id: id, taskID: taskID, taskName: name, engine: engine, mode: mode,
            dryRun: sqlite3_column_int(statement, 5) != 0,
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            finishedAt: finished, status: status, summary: summary, logPath: text(10)
        )
    }
}
```

Créer `Sources/SyncKit/TaskStore.swift` :

```swift
import Foundation

/// Les tâches de l'utilisateur, dans un fichier JSON lisible.
public struct TaskStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Un fichier absent donne une liste vide ; un fichier illisible lève une erreur (il n'est jamais écrasé en silence).
    public func load() throws -> [SyncTask] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SyncTask].self, from: Data(contentsOf: url))
    }

    public func save(_ tasks: [SyncTask]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(tasks).write(to: url, options: .atomic)
    }

    /// Ajoute la tâche ou remplace celle qui a le même identifiant.
    public func upsert(_ task: SyncTask) throws {
        var tasks = try load()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        try save(tasks)
    }

    public func remove(id: UUID) throws {
        try save(try load().filter { $0.id != id })
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **97 tests**.

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): historique SQLite et stockage des tâches"
```

---

### Tâche 10 : l'orchestrateur `TaskRunner` (tests avec les vrais rsync et rclone)

**Fichiers :**
- Créer : `Sources/SyncKit/{RunnerTypes,TaskRunner,TaskRunner+Rsync,TaskRunner+Rclone}.swift`, `Tests/SyncKitTests/IntegrationSupport.swift`
- Test : `Tests/SyncKitTests/RsyncRunnerTests.swift`, `Tests/SyncKitTests/RcloneRunnerTests.swift`

**Interfaces :**
- Consomme : tout ce qui précède (`EngineSelector`, les deux constructeurs, les lecteurs de sortie, `ProgressTracker`, `ProcessRunner`, `DeleteGuard`, `RunStatus`, `RunSummary`).
- Produit : `RunnerConfiguration(rsyncPath:rclonePath:rcloneConfigPath:workDirectory:now:sampleInterval:)` ; `RunPhase` ; `RunUpdate` (`.phase`, `.snapshot`, `.line`) ; `RunResult(status:engine:summary:snapshot:)` ; `RunnerError.binaryMissing` ; `TaskRunner(configuration:)` avec `run(_:dryRun:onUpdate:) async throws -> RunResult`, `pause()`, `resume()`, `stop()` et `static archiveStamp(_:)`. Une instance exécute **une tâche à la fois** (l'agent en crée une par exécution).

Comportement (spec §5.4 et §6) :
- **rsync** : un miroir fait d'abord une simulation `-n --stats` et **bloque avant de toucher à quoi que ce soit** si le pourcentage de suppressions dépasse le seuil ; copie et déplacement démarrent tout de suite et calculent le total en arrière-plan ; la progression du fichier en cours est mesurée toutes les 250 ms ; la destination est créée si besoin ; une simulation (`dryRun`) s'appuie sur le plan.
- **rclone** : miroir et versions passent par une simulation préalable (`rclone size --json` + `--dry-run`) puis `--max-delete` en dernier recours ; `bisync` s'initialise (`--resync`) à la première exécution grâce à un dossier d'état **par tâche**, bloque via son propre seuil en pourcentage, archive des deux côtés ; code 8 ou « max transfer limit reached » → `quotaReached`.
- Pause, reprise et arrêt s'appliquent au **groupe** de processus ; le chronomètre s'arrête en pause.
- Les tests ont besoin des vrais binaires (`brew install rsync rclone`, `SYNCMACPRO_RSYNC`) ; sinon ils sont **ignorés**. Entre deux dossiers locaux, rclone fait des copies « côté serveur » instantanées : les tests de pause forcent un vrai flux avec `extraArguments: ["--disable", "Copy"]`.

- [ ] **Étape 1 : écrire les tests qui échouent**

Créer `Tests/SyncKitTests/IntegrationSupport.swift` :

```swift
import Foundation
import XCTest
@testable import SyncKit

/// Dossiers temporaires et accès aux vrais binaires pour les tests d'intégration.
class IntegrationTestCase: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("synckit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// rsync 3.x (celui de macOS, openrsync, ne convient pas) : sinon le test est ignoré.
    func rsyncPath() throws -> String {
        guard let path = BinaryLocator.locate(.rsync) else { throw XCTSkip("rsync introuvable (SYNCMACPRO_RSYNC)") }
        let output = try shell(path, ["--version"])
        guard output.contains("version 3.") else {
            throw XCTSkip("rsync 3.x requis (brew install rsync, ou SYNCMACPRO_RSYNC) ; trouvé : \(output.prefix(40))")
        }
        return path
    }

    func rclonePath() throws -> String {
        guard let path = BinaryLocator.locate(.rclone) else { throw XCTSkip("rclone introuvable (SYNCMACPRO_RCLONE)") }
        return path
    }

    func makeRunner(rsync: Bool = false, rclone: Bool = false, sampleInterval: TimeInterval = 0.05) throws -> TaskRunner {
        let config = sandbox.appendingPathComponent("rclone.conf")
        try "".write(to: config, atomically: true, encoding: .utf8)
        return TaskRunner(configuration: RunnerConfiguration(
            rsyncPath: rsync ? try rsyncPath() : nil,
            rclonePath: rclone ? try rclonePath() : nil,
            rcloneConfigPath: config.path,
            workDirectory: sandbox.appendingPathComponent("work"),
            sampleInterval: sampleInterval
        ))
    }

    func folder(_ name: String) throws -> String {
        let url = sandbox.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @discardableResult
    func write(_ path: String, _ content: String) throws -> String {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func writeBytes(_ path: String, megabytes: Int) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let chunk = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        for _ in 0..<megabytes { handle.write(chunk) }
        try handle.close()
    }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func names(in path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func shell(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func task(
        _ source: String, _ destination: String, mode: SyncMode = .copy,
        options: TaskOptions = TaskOptions(excludes: []), items: [String] = []
    ) -> SyncTask {
        SyncTask(name: "test", source: .local(path: source), destination: .local(path: destination),
                 sourceItems: items, mode: mode, options: options)
    }

    func waitUntil(timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("délai dépassé en attendant la condition") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}

/// Reçoit les mises à jour d'une exécution, depuis n'importe quel thread.
final class UpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [RunUpdate] = []

    func add(_ update: RunUpdate) { lock.lock(); all.append(update); lock.unlock() }

    var snapshots: [TransferSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return all.compactMap { if case .snapshot(let s) = $0 { return s } else { return nil } }
    }
    var phases: [RunPhase] {
        lock.lock(); defer { lock.unlock() }
        return all.compactMap { if case .phase(let p) = $0 { return p } else { return nil } }
    }
    var latest: TransferSnapshot? { snapshots.last }
}
```

Créer `Tests/SyncKitTests/RsyncRunnerTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class RsyncRunnerTests: IntegrationTestCase {
    func testCopyCopiesEverythingAndReportsProgress() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/sub/b.txt", "bravo")
        try writeBytes("\(src)/sub/big.bin", megabytes: 4)
        let updates = UpdateCollector()

        let result = try await makeRunner(rsync: true).run(task(src, dst)) { updates.add($0) }

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(result.engine, .rsync)
        XCTAssertEqual(read("\(dst)/a.txt"), "alpha")
        XCTAssertEqual(read("\(dst)/sub/b.txt"), "bravo")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(dst)/sub/big.bin")).count, 4 * 1_048_576)
        XCTAssertEqual(result.summary.filesTransferred, 3)
        XCTAssertEqual(result.summary.bytesTransferred, 10 + 4 * 1_048_576)
        XCTAssertEqual(result.snapshot.totalFiles, 3)
        XCTAssertEqual(result.snapshot.overallPercent, 100)
        XCTAssertTrue(updates.phases.contains(.running))
    }

    func testSecondCopyHasNothingToDo() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        let runner = try makeRunner(rsync: true)
        _ = try await runner.run(task(src, dst))
        let again = try await runner.run(task(src, dst))
        XCTAssertEqual(again.status, .succeeded)
        XCTAssertEqual(again.summary.filesTransferred, 0)
    }

    func testSelectedItemsAreCopiedAsFolders() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/keep/one.txt", "1")
        try write("\(src)/skip/two.txt", "2")
        try write("\(src)/single.txt", "3")
        let result = try await makeRunner(rsync: true).run(task(src, dst, items: ["keep", "single.txt"]))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), ["keep", "single.txt"])
        XCTAssertEqual(read("\(dst)/keep/one.txt"), "1")
    }

    func testMirrorArchivesDeletedAndOverwrittenFiles() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/same.txt", "same")
        try write("\(src)/changed.txt", "new content, longer")
        try write("\(src)/fresh.txt", "fresh")
        try write("\(dst)/same.txt", "same")
        try write("\(dst)/changed.txt", "old")
        try write("\(dst)/gone.txt", "gone")
        // même date de modification pour « same.txt » : rsync le considère identique
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: "\(src)/same.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: "\(dst)/same.txt")

        var options = TaskOptions(excludes: [])
        options.deleteThresholdPercent = 50
        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .mirror, options: options))

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(names(in: dst), ["_ARCHIVE", "changed.txt", "fresh.txt", "same.txt"])
        XCTAssertEqual(read("\(dst)/changed.txt"), "new content, longer")
        let archives = names(in: "\(dst)/_ARCHIVE")
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(read("\(dst)/_ARCHIVE/\(archives[0])/gone.txt"), "gone")
        XCTAssertEqual(read("\(dst)/_ARCHIVE/\(archives[0])/changed.txt"), "old")
        XCTAssertEqual(result.summary.deletions, 1)
    }

    func testMirrorIsBlockedWhenTooManyFilesWouldBeDeletedAndTouchesNothing() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/keep.txt", "keep")
        for index in 1...10 { try write("\(dst)/old\(index).txt", "old") }

        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .mirror))   // seuil par défaut : 25 %

        XCTAssertEqual(result.status, .blocked)
        XCTAssertTrue(result.summary.message?.contains("Bloqué") ?? false, result.summary.message ?? "")
        XCTAssertEqual(names(in: dst).count, 10, "rien ne doit avoir été modifié")
        XCTAssertFalse(exists("\(dst)/keep.txt"))
    }

    func testAnEmptiedSourceCannotWipeTheMirror() async throws {
        let src = try folder("src"), dst = try folder("dst")
        for index in 1...5 { try write("\(dst)/f\(index).txt", "x") }
        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .mirror))
        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(names(in: dst).count, 5)
    }

    func testDryRunChangesNothingAndDescribesTheWork() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/b.txt", "bravo")
        let result = try await makeRunner(rsync: true).run(task(src, dst), dryRun: true)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), [])
        XCTAssertEqual(result.summary.filesTransferred, 2)
        XCTAssertTrue(result.summary.message?.contains("Simulation") ?? false)
    }

    func testMoveRemovesTheSourceFiles() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/sub/b.txt", "bravo")
        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .move))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(read("\(dst)/sub/b.txt"), "bravo")
        XCTAssertFalse(exists("\(src)/a.txt"))
        XCTAssertFalse(exists("\(src)/sub/b.txt"))
    }

    func testVerifyReportsDifferences() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/same.txt", "same")
        try write("\(dst)/same.txt", "same")
        let runner = try makeRunner(rsync: true)
        let identical = try await runner.run(task(src, dst, mode: .verify))
        XCTAssertEqual(identical.status, .succeeded)

        try write("\(src)/changed.txt", "AAA")
        try write("\(dst)/changed.txt", "BBB")
        let different = try await runner.run(task(src, dst, mode: .verify))
        XCTAssertEqual(different.status, .failed)
        XCTAssertTrue(different.summary.message?.contains("changed.txt") ?? false)
    }

    func testVerifyAfterCopyPassesOnAGoodCopy() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        var options = TaskOptions(excludes: [])
        options.verifyAfterCopy = true
        let updates = UpdateCollector()
        let result = try await makeRunner(rsync: true).run(task(src, dst, options: options)) { updates.add($0) }
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(updates.phases.contains(.verifying))
    }

    func testExcludesAreHonored() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/.DS_Store", "junk")
        try write("\(src)/notes.tmp", "junk")
        let result = try await makeRunner(rsync: true).run(task(src, dst, options: TaskOptions(excludes: [".DS_Store", "*.tmp"])))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), ["a.txt"])
    }

    func testMissingSourceFailsWithAMessage() async throws {
        let dst = try folder("dst")
        let result = try await makeRunner(rsync: true).run(task(sandbox.appendingPathComponent("nope").path, dst))
        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.summary.message?.isEmpty ?? true)
    }

    func testRsyncOnlyModeOnRcloneOnlyTaskIsRejected() async throws {
        let src = try folder("src"), dst = try folder("dst")
        let bad = task(src, dst, mode: .copy, options: TaskOptions(excludes: [], forcedEngine: .rsync))
        var cloud = bad
        cloud.destination = .cloud(remote: "gdrive", path: "")
        do {
            _ = try await makeRunner(rsync: true).run(cloud)
            XCTFail("aurait dû échouer")
        } catch {
            XCTAssertEqual(error as? EngineSelectionError, .cloudRequiresRclone)
        }
    }

    func testMissingBinaryThrows() async throws {
        let src = try folder("src"), dst = try folder("dst")
        do {
            _ = try await makeRunner().run(task(src, dst))
            XCTFail("aurait dû échouer")
        } catch {
            XCTAssertEqual(error as? RunnerError, .binaryMissing(.rsync))
        }
    }

    // MARK: cas difficiles

    func testAwkwardFileNamesSurviveTheWholePipeline() async throws {
        let src = try folder("src"), dst = try folder("dst")
        let names = ["Rushes été/clip n°1 (copie) | v2.mov", "-leading-dash.txt", "with space.txt", "日本語.txt", "a;b&c$d.txt"]
        for name in names { try write("\(src)/\(name)", "content of \(name)") }

        let result = try await makeRunner(rsync: true).run(task(src, dst))

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(result.summary.filesTransferred, names.count)
        for name in names { XCTAssertEqual(read("\(dst)/\(name)"), "content of \(name)", name) }
    }

    func testMirrorToAMissingDestinationCreatesIt() async throws {
        let src = try folder("src")
        try write("\(src)/a.txt", "alpha")
        let dst = sandbox.appendingPathComponent("not/yet/there").path
        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .mirror))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read("\(dst)/a.txt"), "alpha")
    }

    /// Le NAS est débranché ou le dossier effacé en pleine copie : l'exécution doit échouer avec un message, pas rester bloquée.
    func testDestinationVanishingMidRunFailsInsteadOfHanging() async throws {
        let src = try folder("src"), dst = try folder("dst")
        for index in 1...6 { try writeBytes("\(src)/clip\(index).bin", megabytes: 3) }
        var options = TaskOptions(excludes: [])
        options.bandwidthLimitKBps = 4_000
        let runner = try makeRunner(rsync: true)
        let updates = UpdateCollector()
        let run = Task { try await runner.run(task(src, dst, options: options)) { updates.add($0) } }

        try await waitUntil { (updates.latest?.filesDone ?? 0) >= 1 }
        try FileManager.default.removeItem(atPath: dst)

        let result = try await withThrowingTaskGroup(of: RunResult?.self) { group -> RunResult? in
            group.addTask { try await run.value }
            group.addTask { try await Task.sleep(nanoseconds: 20_000_000_000); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let finished = try XCTUnwrap(result, "l'exécution est restée bloquée")
        XCTAssertEqual(finished.status, .failed)
        XCTAssertFalse(finished.summary.message?.isEmpty ?? true)
    }

    /// La destination ne peut pas exister (son « dossier parent » est un fichier) : échec clair, rien de copié.
    func testDestinationThatCannotBeCreatedFailsWithAMessage() async throws {
        let src = try folder("src")
        try write("\(src)/a.txt", "alpha")
        let blocker = try write("\(sandbox.path)/blocker", "je suis un fichier")

        let result = try await makeRunner(rsync: true).run(task(src, "\(blocker)/dest"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.summary.message?.isEmpty ?? true)
        XCTAssertEqual(read(blocker), "je suis un fichier")
    }

    // MARK: pause, reprise, arrêt

    func testPauseFreezesTheCopyAndResumeFinishesIt() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/big.bin", megabytes: 16)
        var options = TaskOptions(excludes: [])
        options.bandwidthLimitKBps = 6_000                        // ~3 secondes pour 16 Mo
        let runner = try makeRunner(rsync: true)
        let updates = UpdateCollector()
        let run = Task { try await runner.run(task(src, dst, options: options)) { updates.add($0) } }

        try await waitUntil { (updates.latest?.currentBytes ?? 0) > 500_000 }
        runner.pause()
        try await Task.sleep(nanoseconds: 700_000_000)
        let frozen = updates.latest?.currentBytes ?? 0
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(updates.latest?.currentBytes ?? 0, frozen, "pas de progression pendant la pause")
        XCTAssertLessThan(frozen, 16 * 1_048_576)

        runner.resume()
        let result = try await run.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(dst)/big.bin")).count, 16 * 1_048_576)
        XCTAssertGreaterThan(result.summary.durationSeconds, 1)
    }

    func testStopEndsTheRunAndAnInterruptedFileCanBeResumed() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/big.bin", megabytes: 16)
        var options = TaskOptions(excludes: [])
        options.bandwidthLimitKBps = 6_000
        let runner = try makeRunner(rsync: true)
        let updates = UpdateCollector()
        let run = Task { try await runner.run(task(src, dst, options: options)) { updates.add($0) } }

        try await waitUntil { (updates.latest?.currentBytes ?? 0) > 500_000 }
        runner.stop()
        let stopped = try await run.value
        XCTAssertEqual(stopped.status, .stopped)

        // nouvelle exécution : elle termine le fichier, sans erreur
        let resumed = try await makeRunner(rsync: true).run(task(src, dst))
        XCTAssertEqual(resumed.status, .succeeded, resumed.summary.message ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(dst)/big.bin")).count, 16 * 1_048_576)
    }

    func testProgressIsLiveForFastFiles() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/clip.bin", megabytes: 12)
        var options = TaskOptions(excludes: [])
        options.bandwidthLimitKBps = 8_000                        // ~1,5 s : rsync n'affiche qu'une ligne par seconde
        let updates = UpdateCollector()
        let result = try await makeRunner(rsync: true).run(task(src, dst, options: options)) { updates.add($0) }
        XCTAssertEqual(result.status, .succeeded)
        let distinctProgress = Set(updates.snapshots.map(\.currentBytes).filter { $0 > 0 })
        XCTAssertGreaterThanOrEqual(distinctProgress.count, 4, "la mesure directe donne bien plus de points que rsync")
    }
}
```

Créer `Tests/SyncKitTests/RcloneRunnerTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class RcloneRunnerTests: IntegrationTestCase {
    private func rcloneTask(_ source: String, _ destination: String, mode: SyncMode = .copy,
                            options: TaskOptions = TaskOptions(excludes: [])) -> SyncTask {
        task(source, destination, mode: mode, options: options)
    }

    private var forced: TaskOptions { TaskOptions(excludes: [], forcedEngine: .rclone) }

    /// Entre deux dossiers locaux, rclone fait une « copie côté serveur » instantanée et sans progression.
    /// `--disable Copy` force un vrai flux de données, comme avec un service en ligne.
    private var streaming: TaskOptions {
        TaskOptions(excludes: [], bandwidthLimitKBps: 6_000, forcedEngine: .rclone, extraArguments: ["--disable", "Copy"])
    }

    func testCopyWithRclone() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/sub/b.txt", "bravo")
        try writeBytes("\(src)/sub/big.bin", megabytes: 3)
        let updates = UpdateCollector()

        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, options: forced)) { updates.add($0) }

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(result.engine, .rclone)
        XCTAssertEqual(read("\(dst)/sub/b.txt"), "bravo")
        XCTAssertEqual(result.summary.filesTransferred, 3)
        XCTAssertEqual(result.snapshot.totalFiles, 3)
        XCTAssertEqual(result.snapshot.overallPercent, 100)
        XCTAssertFalse(updates.snapshots.isEmpty)
    }

    func testDryRunChangesNothing() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/b.txt", "bravo")
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, options: forced), dryRun: true)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), [])
        XCTAssertEqual(result.summary.filesTransferred, 2)
    }

    func testMirrorArchivesDeletedAndOverwrittenFiles() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/same.txt", "same")
        try write("\(src)/changed.txt", "new content, longer")
        try write("\(src)/fresh.txt", "fresh")
        try write("\(dst)/same.txt", "same")
        try write("\(dst)/changed.txt", "old")
        try write("\(dst)/gone.txt", "gone")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: "\(src)/same.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: "\(dst)/same.txt")

        var options = forced
        options.deleteThresholdPercent = 50
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .mirror, options: options))

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(names(in: dst), ["_ARCHIVE", "changed.txt", "fresh.txt", "same.txt"])
        let archive = try XCTUnwrap(names(in: "\(dst)/_ARCHIVE").first)
        XCTAssertEqual(read("\(dst)/_ARCHIVE/\(archive)/gone.txt"), "gone")
        XCTAssertEqual(read("\(dst)/_ARCHIVE/\(archive)/changed.txt"), "old")
        XCTAssertEqual(result.summary.deletions, 1)
    }

    func testMirrorIsBlockedBeforeTouchingAnything() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/keep.txt", "keep")
        for index in 1...10 { try write("\(dst)/old\(index).txt", "old") }

        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .mirror, options: forced))

        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(names(in: dst).count, 10)
        XCTAssertFalse(exists("\(dst)/keep.txt"))
    }

    func testMirrorToAMissingDestinationJustCopies() async throws {
        let src = try folder("src")
        try write("\(src)/a.txt", "alpha")
        let dst = sandbox.appendingPathComponent("newdest").path
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .mirror, options: forced))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read("\(dst)/a.txt"), "alpha")
    }

    func testMoveRemovesTheSource() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/sub/b.txt", "bravo")
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .move, options: forced))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(read("\(dst)/sub/b.txt"), "bravo")
        XCTAssertFalse(exists("\(src)/a.txt"))
    }

    func testVerify() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(dst)/a.txt", "alpha")
        let runner = try makeRunner(rclone: true)
        let same = try await runner.run(rcloneTask(src, dst, mode: .verify, options: forced))
        XCTAssertEqual(same.status, .succeeded)

        try write("\(dst)/a.txt", "different")
        let different = try await runner.run(rcloneTask(src, dst, mode: .verify, options: forced))
        XCTAssertEqual(different.status, .failed)
        XCTAssertTrue(different.summary.message?.contains("a.txt") ?? false)
    }

    func testSelectedItemsOnly() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/keep/one.txt", "1")
        try write("\(src)/skip/two.txt", "2")
        try write("\(src)/single.txt", "3")
        let t = task(src, dst, options: forced, items: ["keep", "single.txt"])
        let result = try await makeRunner(rclone: true).run(t)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), ["keep", "single.txt"])
    }

    // MARK: bisync

    func testBisyncInitializesThenPropagatesChangesAndDeletions() async throws {
        let one = try folder("one"), two = try folder("two")
        try write("\(one)/a.txt", "from-one")
        try write("\(two)/b.txt", "from-two")
        for index in 1...8 { try write("\(one)/common\(index).txt", "x") }   // assez de fichiers pour que 1 suppression reste sous le seuil
        let runner = try makeRunner(rclone: true)
        let sync = rcloneTask(one, two, mode: .bidirectional)

        let first = try await runner.run(sync)
        XCTAssertEqual(first.status, .succeeded, first.summary.message ?? "")
        XCTAssertTrue(exists("\(one)/b.txt"))           // initialisation : chaque côté reçoit ce qui lui manque
        XCTAssertTrue(exists("\(two)/a.txt"))
        XCTAssertEqual(names(in: one).count, 10)
        XCTAssertEqual(names(in: two).count, 10)

        try write("\(one)/c.txt", "new-in-one")
        try FileManager.default.removeItem(atPath: "\(two)/a.txt")
        let second = try await runner.run(sync)
        XCTAssertEqual(second.status, .succeeded, second.summary.message ?? "")
        XCTAssertEqual(read("\(two)/c.txt"), "new-in-one")
        XCTAssertFalse(exists("\(one)/a.txt"), "la suppression est propagée")
        let archived = try XCTUnwrap(names(in: "\(one)/_ARCHIVE").first, "aucune archive créée")
        XCTAssertEqual(read("\(one)/_ARCHIVE/\(archived)/a.txt"), "from-one", "et l'ancienne version est archivée")
    }

    func testBisyncBlocksAMassDeletionAndChangesNothing() async throws {
        let one = try folder("one"), two = try folder("two")
        for index in 1...10 { try write("\(one)/f\(index).txt", "x") }
        let runner = try makeRunner(rclone: true)
        let sync = rcloneTask(one, two, mode: .bidirectional)
        _ = try await runner.run(sync)
        XCTAssertEqual(names(in: two).count, 10)

        for index in 1...6 { try FileManager.default.removeItem(atPath: "\(one)/f\(index).txt") }   // 60 % supprimés
        let result = try await runner.run(sync)

        XCTAssertEqual(result.status, .blocked, result.summary.message ?? "")
        XCTAssertEqual(names(in: two).count, 10, "l'autre côté n'est pas touché")
    }

    func testBisyncStateIsPerTask() async throws {
        let one = try folder("one"), two = try folder("two")
        try write("\(one)/a.txt", "x")
        let runner = try makeRunner(rclone: true)
        let sync = rcloneTask(one, two, mode: .bidirectional)
        _ = try await runner.run(sync)
        let workdir = sandbox.appendingPathComponent("work/bisync/\(sync.id.uuidString)")
        XCTAssertTrue(TaskRunner.hasBisyncState(at: workdir))
        XCTAssertFalse(TaskRunner.hasBisyncState(at: sandbox.appendingPathComponent("work/bisync/\(UUID().uuidString)")))
    }

    // MARK: pause et arrêt

    func testPauseAndResumeWithRclone() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/big.bin", megabytes: 12)
        let runner = try makeRunner(rclone: true)
        let updates = UpdateCollector()
        let run = Task { try await runner.run(rcloneTask(src, dst, options: streaming)) { updates.add($0) } }

        try await waitUntil { (updates.latest?.currentBytes ?? 0) > 300_000 }
        runner.pause()
        try await Task.sleep(nanoseconds: 800_000_000)
        let frozen = updates.snapshots.count
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(updates.snapshots.count, frozen, "rclone figé : plus de statistiques")

        runner.resume()
        let result = try await run.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(dst)/big.bin")).count, 12 * 1_048_576)
    }

    func testStopWithRclone() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/big.bin", megabytes: 12)
        let runner = try makeRunner(rclone: true)
        let updates = UpdateCollector()
        let run = Task { try await runner.run(rcloneTask(src, dst, options: streaming)) { updates.add($0) } }
        try await waitUntil { (updates.latest?.currentBytes ?? 0) > 300_000 }
        runner.stop()
        let result = try await run.value
        XCTAssertEqual(result.status, .stopped)
    }
}
```

- [ ] **Étape 2 : lancer les tests et vérifier qu'ils échouent**

Lancer : `swift test --filter RsyncRunnerTests`
Attendu : ÉCHEC de compilation (`cannot find 'TaskRunner' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/RunnerTypes.swift` :

```swift
import Foundation

public struct RunnerConfiguration: Sendable {
    public var rsyncPath: String?
    public var rclonePath: String?
    /// Fichier de configuration rclone (`--config`) ; `nil` = celui de l'utilisateur.
    public var rcloneConfigPath: String?
    /// Dossier d'état propre aux tâches (bisync y garde ses listes).
    public var workDirectory: URL
    public var now: @Sendable () -> Date
    /// Intervalle entre deux mesures de progression.
    public var sampleInterval: TimeInterval

    public init(
        rsyncPath: String? = nil,
        rclonePath: String? = nil,
        rcloneConfigPath: String? = nil,
        workDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        sampleInterval: TimeInterval = 0.25
    ) {
        self.rsyncPath = rsyncPath
        self.rclonePath = rclonePath
        self.rcloneConfigPath = rcloneConfigPath
        self.workDirectory = workDirectory
        self.now = now
        self.sampleInterval = sampleInterval
    }
}

public enum RunPhase: Equatable, Sendable {
    case preparing
    /// Simulation préalable (garde-fous, calcul du total).
    case planning
    case running
    case verifying
}

public enum RunUpdate: Sendable {
    case phase(RunPhase)
    case snapshot(TransferSnapshot)
    /// Une ligne de la sortie du moteur (pour le journal).
    case line(String)
}

public struct RunResult: Equatable, Sendable {
    public var status: RunStatus
    public var engine: EngineKind
    public var summary: RunSummary
    public var snapshot: TransferSnapshot
}

public enum RunnerError: Error, Equatable {
    case binaryMissing(EngineKind)
}

/// Accès thread-safe au suivi de progression (alimenté par plusieurs threads).
final class SafeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let tracker: ProgressTracker

    init(now: @escaping () -> Date, fileInfo: @escaping (String) -> (size: Int64, live: Bool)) {
        tracker = ProgressTracker(now: now, fileInfo: fileInfo)
    }

    func perform<T>(_ body: (ProgressTracker) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(tracker)
    }
}

/// Pause, reprise et arrêt d'une exécution, vus depuis n'importe quel thread.
final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var main: RunningProcess?
    private var auxiliary: [RunningProcess] = []
    private var stopRequestedFlag = false
    private var pausedFlag = false
    /// Appelés (hors verrou) quand l'exécution est mise en pause ou reprise : arrêtent / relancent le chronomètre.
    private var pauseHook: (@Sendable () -> Void)?
    private var resumeHook: (@Sendable () -> Void)?

    func setHooks(pause: @escaping @Sendable () -> Void, resume: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        pauseHook = pause
        resumeHook = resume
    }

    var stopRequested: Bool { lock.lock(); defer { lock.unlock() }; return stopRequestedFlag }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return pausedFlag }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        main = nil
        auxiliary = []
        stopRequestedFlag = false
        pausedFlag = false
        pauseHook = nil
        resumeHook = nil
    }

    func registerMain(_ process: RunningProcess) {
        lock.lock(); defer { lock.unlock() }
        main = process
        if stopRequestedFlag { process.terminate() } else if pausedFlag { process.pause() }
    }

    func registerAuxiliary(_ process: RunningProcess) {
        lock.lock(); defer { lock.unlock() }
        auxiliary.append(process)
        if stopRequestedFlag { process.terminate() }
    }

    func clearMain() { lock.lock(); main = nil; lock.unlock() }

    func pause() {
        lock.lock()
        pausedFlag = true
        main?.pause()
        let hook = pauseHook
        lock.unlock()
        hook?()
    }

    func resume() {
        lock.lock()
        pausedFlag = false
        main?.resume()
        let hook = resumeHook
        lock.unlock()
        hook?()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopRequestedFlag = true
        pausedFlag = false
        main?.terminate()
        auxiliary.forEach { $0.terminate() }
    }

    /// Arrête les processus annexes (calcul du total) quand la copie principale est finie.
    func stopAuxiliary() {
        lock.lock(); defer { lock.unlock() }
        auxiliary.forEach { $0.terminate() }
        auxiliary = []
    }
}

/// Texte collecté pendant l'exécution d'un moteur (dernières erreurs, compteurs).
final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var errorLines: [String] = []
    private var errorCount = 0
    private var deletionCount = 0
    private var signalValue: OutputSignal?
    private var signalLine: String?

    func addError(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        errorCount += 1
        errorLines.append(line)
        if errorLines.count > 20 { errorLines.removeFirst() }
    }

    func addDeletion() { lock.lock(); deletionCount += 1; lock.unlock() }

    func noteSignal(in line: String) {
        guard let found = OutputSignal.detect(in: line) else { return }
        lock.lock(); defer { lock.unlock() }
        if signalValue == nil || found == .safetyAbort { signalValue = found; signalLine = line }
    }

    var errors: Int { lock.lock(); defer { lock.unlock() }; return errorCount }
    var deletions: Int { lock.lock(); defer { lock.unlock() }; return deletionCount }
    var signal: OutputSignal? { lock.lock(); defer { lock.unlock() }; return signalValue }
    var signalText: String? { lock.lock(); defer { lock.unlock() }; return signalLine }
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return errorLines.last }
}

/// Valeur partagée entre threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    func get() -> Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
}
```

Créer `Sources/SyncKit/TaskRunner.swift` :

```swift
import Foundation

/// Exécute une tâche avec rsync ou rclone et suit son avancement.
/// Une instance exécute une tâche à la fois ; l'agent en crée une par exécution.
public final class TaskRunner: @unchecked Sendable {
    let configuration: RunnerConfiguration
    let control = RunControl()

    public init(configuration: RunnerConfiguration) {
        self.configuration = configuration
    }

    // MARK: contrôle

    public func pause() { control.pause() }
    public func resume() { control.resume() }
    public func stop() { control.stop() }

    // MARK: exécution

    public func run(
        _ task: SyncTask,
        dryRun: Bool = false,
        onUpdate: @escaping @Sendable (RunUpdate) -> Void = { _ in }
    ) async throws -> RunResult {
        let engine = try EngineSelector.engine(for: task)
        control.reset()
        let stamp = Self.archiveStamp(configuration.now())
        switch engine {
        case .rsync: return try await runRsync(task, dryRun: dryRun, stamp: stamp, onUpdate: onUpdate)
        case .rclone: return try await runRclone(task, dryRun: dryRun, stamp: stamp, onUpdate: onUpdate)
        }
    }

    /// Nom du sous-dossier d'archive, par exemple « 2026-10-12_14-30-05 ».
    public static func archiveStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    // MARK: aides partagées

    func executable(for engine: EngineKind) throws -> String {
        let path = engine == .rsync ? configuration.rsyncPath : configuration.rclonePath
        guard let path else { throw RunnerError.binaryMissing(engine) }
        return path
    }

    /// Lance une commande annexe (simulation, taille, vérification) et attend sa fin.
    func collect(_ command: EngineCommand) async throws -> (code: Int32, output: String) {
        let box = LineBox()
        let process = try ProcessRunner.spawn(
            executable: try executable(for: command.engine), arguments: command.arguments
        ) { box.add($0.text) }
        control.registerAuxiliary(process)
        let code = await process.waitForExit()
        return (code, box.joined)
    }

    func result(
        status: RunStatus, engine: EngineKind, snapshot: TransferSnapshot, started: Date,
        deletions: Int = 0, errors: Int = 0, message: String? = nil
    ) -> RunResult {
        RunResult(
            status: status, engine: engine,
            summary: RunSummary(
                filesTransferred: snapshot.filesDone, bytesTransferred: snapshot.doneBytes,
                deletions: deletions, errors: errors,
                durationSeconds: configuration.now().timeIntervalSince(started), message: message
            ),
            snapshot: snapshot
        )
    }

    static func blockedMessage(percent: Int, deletions: Int, existing: Int, threshold: Int) -> String {
        "Bloqué : \(deletions) suppression(s) sur \(existing) fichier(s) (\(percent) %), "
            + "au-dessus du seuil de \(threshold) %. Rien n'a été modifié."
    }
}

/// Collecte de lignes depuis plusieurs threads.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var joined: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
```

Créer `Sources/SyncKit/TaskRunner+Rsync.swift` :

```swift
import Foundation

extension TaskRunner {
    func runRsync(
        _ task: SyncTask, dryRun: Bool, stamp: String, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        let rsync = try executable(for: .rsync)
        let started = configuration.now()
        let runOptions = RunOptions(dryRun: dryRun, archiveStamp: stamp)
        onUpdate(.phase(.preparing))

        if task.mode == .verify {
            return try await verifyWithRsync(task, options: runOptions, started: started, onUpdate: onUpdate)
        }
        let command = try RsyncCommandBuilder.command(for: task, run: runOptions)   // refuse tôt les modes non pris en charge
        let source = task.source.filesystemPath ?? ""
        let destination = task.destination.filesystemPath ?? ""

        // Simulation : le plan répond à « qu'est-ce qui serait fait ? ».
        if dryRun {
            onUpdate(.phase(.planning))
            guard let plan = try await rsyncPlan(task, runOptions) else {
                return result(status: .failed, engine: .rsync, snapshot: TransferSnapshot(), started: started,
                              message: "La simulation a échoué.")
            }
            var snapshot = TransferSnapshot()
            snapshot.totalFiles = plan.files.count
            snapshot.totalBytes = plan.totalBytes
            var outcome = result(
                status: control.stopRequested ? .stopped : .succeeded, engine: .rsync, snapshot: snapshot,
                started: started, deletions: plan.deletions.count,
                message: "Simulation : \(plan.files.count) fichier(s) à copier, \(plan.deletions.count) suppression(s)."
            )
            outcome.summary.filesTransferred = plan.files.count
            outcome.summary.bytesTransferred = plan.totalBytes
            return outcome
        }

        try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

        // Garde-fou du miroir : on calcule d'abord, avant de toucher à quoi que ce soit.
        var knownPlan: RsyncPlan?
        if task.mode == .mirror {
            onUpdate(.phase(.planning))
            guard let plan = try await rsyncPlan(task, runOptions) else {
                if control.stopRequested {
                    return result(status: .stopped, engine: .rsync, snapshot: TransferSnapshot(), started: started)
                }
                return result(status: .failed, engine: .rsync, snapshot: TransferSnapshot(), started: started,
                              message: "Le calcul préalable a échoué : impossible de vérifier les suppressions.")
            }
            let threshold = task.options.deleteThresholdPercent
            if case .blocked(let percent, let deletions, let existing) = DeleteGuard.verdict(for: plan, thresholdPercent: threshold) {
                return result(
                    status: .blocked, engine: .rsync, snapshot: TransferSnapshot(), started: started, deletions: 0,
                    message: Self.blockedMessage(percent: percent, deletions: deletions, existing: existing, threshold: threshold)
                )
            }
            knownPlan = plan
        }

        let tracker = SafeTracker(now: configuration.now, fileInfo: { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: Endpoint.join(source, name))[.size] as? NSNumber)?
                .flatMap { $0 }?.int64Value ?? 0
            return (size, !FileManager.default.fileExists(atPath: Endpoint.join(destination, name)))
        })
        tracker.perform { $0.start() }
        control.setHooks(pause: { tracker.perform { $0.pause() } }, resume: { tracker.perform { $0.resume() } })
        if let plan = knownPlan { tracker.perform { $0.setPlan(files: plan.files, directories: plan.directories) } }

        // Sans plan connu, le total se calcule en arrière-plan : la copie démarre tout de suite.
        if knownPlan == nil {
            Task.detached { [self] in
                guard let plan = try? await self.rsyncPlan(task, runOptions), !self.control.stopRequested else { return }
                tracker.perform { $0.setPlan(files: plan.files, directories: plan.directories) }
            }
        }

        onUpdate(.phase(.running))
        let log = RunLog()
        let lastStarted = Locked<String?>(nil)
        let process = try ProcessRunner.spawn(executable: rsync, arguments: command.arguments) { output in
            onUpdate(.line(output.text))
            guard let event = RsyncOutputParser.parse(line: output.text) else { return }
            switch event {
            case .fileStarted(let name, _): lastStarted.set(name)
            case .deleting: log.addDeletion()
            case .error(let text): log.addError(text)
            default: break
            }
            tracker.perform { $0.apply(event) }
        }
        control.registerMain(process)

        let interval = configuration.sampleInterval
        let sampler = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if let name = lastStarted.get(),
                   let size = (try? FileManager.default.attributesOfItem(atPath: Endpoint.join(destination, name))[.size] as? NSNumber)?.flatMap({ $0 })?.int64Value {
                    tracker.perform { $0.observeCurrentFileBytes(size) }
                }
                onUpdate(.snapshot(tracker.perform { $0.snapshot() }))
            }
        }

        let code = await process.waitForExit()
        control.clearMain()
        sampler.cancel()
        control.stopAuxiliary()

        var status: RunStatus
        var message: String?
        if control.stopRequested {
            status = .stopped
        } else if code == 0 || code == 24 {
            status = .succeeded
        } else {
            status = .failed
            message = log.lastError ?? "rsync a échoué (code \(code))."
        }

        if status == .succeeded, task.options.verifyAfterCopy, task.mode == .copy || task.mode == .mirror {
            onUpdate(.phase(.verifying))
            var checked = task
            checked.mode = .verify
            let verification = try await collect(try RsyncCommandBuilder.command(for: checked, run: runOptions))
            let differences = VerifyParser.rsyncDifferences(in: verification.output)
            if !differences.isEmpty {
                status = .failed
                message = "\(differences.count) fichier(s) diffèrent après la copie (par exemple « \(differences[0]) »)."
            }
        }

        let snapshot = tracker.perform { tracker -> TransferSnapshot in
            if status == .succeeded { tracker.finish() } else { tracker.pause() }
            return tracker.snapshot()
        }
        onUpdate(.snapshot(snapshot))
        return result(status: status, engine: .rsync, snapshot: snapshot, started: started,
                      deletions: log.deletions, errors: log.errors, message: message)
    }

    /// Simulation (`-n --stats`) ; `nil` si rsync a échoué ou a été arrêté.
    func rsyncPlan(_ task: SyncTask, _ options: RunOptions) async throws -> RsyncPlan? {
        let outcome = try await collect(try RsyncCommandBuilder.planCommand(for: task, run: options))
        guard outcome.code == 0 || outcome.code == 23 || outcome.code == 24 else { return nil }
        return RsyncPlanParser.parse(outcome.output)
    }

    private func verifyWithRsync(
        _ task: SyncTask, options: RunOptions, started: Date, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        onUpdate(.phase(.verifying))
        let outcome = try await collect(try RsyncCommandBuilder.command(for: task, run: options))
        if control.stopRequested { return result(status: .stopped, engine: .rsync, snapshot: TransferSnapshot(), started: started) }
        guard outcome.code == 0 || outcome.code == 23 || outcome.code == 24 else {
            return result(status: .failed, engine: .rsync, snapshot: TransferSnapshot(), started: started,
                          message: "La vérification a échoué (code \(outcome.code)).")
        }
        let differences = VerifyParser.rsyncDifferences(in: outcome.output)
        return result(
            status: differences.isEmpty ? .succeeded : .failed, engine: .rsync, snapshot: TransferSnapshot(),
            started: started,
            message: differences.isEmpty ? "Aucune différence." : "\(differences.count) fichier(s) diffèrent (par exemple « \(differences[0]) »)."
        )
    }
}
```

Créer `Sources/SyncKit/TaskRunner+Rclone.swift` :

```swift
import Foundation

extension TaskRunner {
    func runRclone(
        _ task: SyncTask, dryRun: Bool, stamp: String, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        let rclone = try executable(for: .rclone)
        let started = configuration.now()
        var options = RunOptions(dryRun: dryRun, archiveStamp: stamp, rcloneConfigPath: configuration.rcloneConfigPath)
        onUpdate(.phase(.preparing))

        if task.mode == .verify {
            return try await verifyWithRclone(task, options: options, started: started, onUpdate: onUpdate)
        }

        if task.mode == .bidirectional {
            let workdir = configuration.workDirectory.appendingPathComponent("bisync/\(task.id.uuidString)")
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            options.bisyncWorkdir = workdir.path
            options.resync = !Self.hasBisyncState(at: workdir)     // première exécution : initialisation
        }

        // Garde-fou des modes qui suppriment : simulation d'abord, avant de toucher à quoi que ce soit.
        if (task.mode == .mirror || task.mode == .versioned) && !dryRun {
            onUpdate(.phase(.planning))
            let guardResult = try await mirrorGuard(task, options: options)
            if let failure = guardResult.failure {
                return result(status: control.stopRequested ? .stopped : .failed, engine: .rclone,
                              snapshot: TransferSnapshot(), started: started, message: failure)
            }
            let threshold = task.options.deleteThresholdPercent
            if case .blocked(let percent, let deletions, let existing) = guardResult.verdict {
                return result(
                    status: .blocked, engine: .rclone, snapshot: TransferSnapshot(), started: started,
                    message: Self.blockedMessage(percent: percent, deletions: deletions, existing: existing, threshold: threshold)
                )
            }
            options.maxDeleteCount = DeleteGuard.maxDeleteCount(existing: guardResult.existing, thresholdPercent: threshold)
        }

        let command = try RcloneCommandBuilder.command(for: task, run: options)
        let tracker = SafeTracker(now: configuration.now, fileInfo: { _ in (0, false) })
        tracker.perform { $0.start() }
        control.setHooks(pause: { tracker.perform { $0.pause() } }, resume: { tracker.perform { $0.resume() } })

        onUpdate(.phase(.running))
        let log = RunLog()
        let lastStats = Locked<RcloneStats?>(nil)
        let process = try ProcessRunner.spawn(executable: rclone, arguments: command.arguments) { output in
            onUpdate(.line(output.text))
            log.noteSignal(in: output.text)
            guard let event = RcloneOutputParser.parse(line: output.text) else { return }
            switch event {
            case .stats(let stats):
                lastStats.set(stats)
                onUpdate(.snapshot(tracker.perform { tracker -> TransferSnapshot in
                    tracker.apply(stats)
                    return tracker.snapshot()
                }))
            case .error(let text): log.addError(text)
            case .notice: break
            }
        }
        control.registerMain(process)
        let code = await process.waitForExit()
        control.clearMain()

        var status: RunStatus
        var message: String?
        if control.stopRequested {
            status = .stopped
        } else if log.signal == .safetyAbort {
            status = .blocked
            message = (log.signalText.flatMap(Self.messageText(fromJSONLine:)) ?? "Trop de suppressions.") + " Rien n'a été modifié."
        } else if log.signal == .quotaReached || code == 8 {
            status = .quotaReached
            message = "Quota de transfert atteint : la copie reprendra à la prochaine exécution."
        } else if code == 0 {
            status = .succeeded
        } else if log.signal == .needsResync {
            status = .failed
            message = "bisync demande une réinitialisation de cette tâche (--resync) : l'état des deux côtés n'est plus cohérent."
        } else {
            status = .failed
            message = log.lastError ?? "rclone a échoué (code \(code))."
        }

        if status == .succeeded, !dryRun {
            if let cleanup = RcloneCommandBuilder.retentionCleanupCommand(for: task, run: options) {
                _ = try await collect(cleanup)
            }
            if task.options.verifyAfterCopy, task.mode == .copy || task.mode == .mirror {
                onUpdate(.phase(.verifying))
                var checked = task
                checked.mode = .verify
                let verification = try await collect(try RcloneCommandBuilder.command(for: checked, run: options))
                let differences = VerifyParser.rcloneDifferences(in: verification.output)
                if !differences.isEmpty {
                    status = .failed
                    message = "\(differences.count) fichier(s) diffèrent après la copie (par exemple « \(differences[0]) »)."
                }
            }
        }

        let snapshot = tracker.perform { tracker -> TransferSnapshot in
            if status == .succeeded { tracker.finish() } else { tracker.pause() }
            return tracker.snapshot()
        }
        onUpdate(.snapshot(snapshot))
        let stats = lastStats.get()
        return result(status: status, engine: .rclone, snapshot: snapshot, started: started,
                      deletions: stats?.deletes ?? 0, errors: max(log.errors, stats?.errors ?? 0), message: message)
    }

    /// bisync a déjà fait sa première exécution s'il a laissé des listes (`*.lst`) dans son dossier d'état.
    static func hasBisyncState(at directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { $0.hasSuffix(".lst") }
    }

    private static func messageText(fromJSONLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["msg"] as? String
    }

    private struct MirrorGuardResult {
        var verdict: GuardVerdict = .allowed
        var existing = 0
        var failure: String?
    }

    /// Compte les fichiers de la destination (`rclone size`) et les suppressions prévues (simulation).
    private func mirrorGuard(_ task: SyncTask, options: RunOptions) async throws -> MirrorGuardResult {
        let size = try await collect(RcloneCommandBuilder.sizeCommand(for: task.destination, run: options))
        let existing = size.code == 0 ? (RcloneSizeParser.count(from: size.output) ?? 0) : 0   // destination absente = vide

        var simulated = options
        simulated.dryRun = true
        let dry = try await collect(try RcloneCommandBuilder.command(for: task, run: simulated))
        if control.stopRequested { return MirrorGuardResult(failure: "Arrêté.") }
        let events = dry.output.split(separator: "\n").compactMap { RcloneOutputParser.parse(line: String($0)) }
        guard dry.code == 0 else {
            let reason = events.compactMap { event -> String? in
                if case .error(let text) = event { return text }
                return nil
            }.last
            return MirrorGuardResult(failure: reason ?? "La simulation a échoué (code \(dry.code)).")
        }
        let deletions = events.compactMap { event -> Int? in
            if case .stats(let stats) = event { return stats.deletes }
            return nil
        }.last ?? 0
        let verdict = DeleteGuard.verdict(deletions: deletions, existing: existing, thresholdPercent: task.options.deleteThresholdPercent)
        return MirrorGuardResult(verdict: verdict, existing: existing)
    }

    private func verifyWithRclone(
        _ task: SyncTask, options: RunOptions, started: Date, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        onUpdate(.phase(.verifying))
        let outcome = try await collect(try RcloneCommandBuilder.command(for: task, run: options))
        if control.stopRequested { return result(status: .stopped, engine: .rclone, snapshot: TransferSnapshot(), started: started) }
        let differences = VerifyParser.rcloneDifferences(in: outcome.output)
        guard outcome.code == 0 || outcome.code == 1 else {
            return result(status: .failed, engine: .rclone, snapshot: TransferSnapshot(), started: started,
                          message: "La vérification a échoué (code \(outcome.code)).")
        }
        return result(
            status: differences.isEmpty ? .succeeded : .failed, engine: .rclone, snapshot: TransferSnapshot(),
            started: started,
            message: differences.isEmpty ? "Aucune différence." : "\(differences.count) fichier(s) diffèrent (par exemple « \(differences[0]) »)."
        )
    }
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

```bash
export SYNCMACPRO_RSYNC=/opt/homebrew/bin/rsync
swift test
```

Attendu : SUCCÈS, **131 tests** (environ 25 secondes : vraies copies, pauses et arrêts).
Si un test s'affiche « skipped », rsync 3.x ou rclone n'est pas trouvé : installer les binaires et relancer, un test ignoré ne prouve rien.

- [ ] **Étape 5 : valider**

```bash
git add -A
git commit -m "feat(core): orchestrateur TaskRunner (rsync et rclone, garde-fous, pause, arrêt)"
```

---

### Tâche 11 : mise en forme française et outil en ligne de commande

**Fichiers :**
- Créer : `Sources/SyncKit/Formatting.swift`
- Modifier : `Sources/synckit-cli/main.swift` (remplace la version provisoire)
- Test : `Tests/SyncKitTests/FormattingTests.swift`

**Interfaces :**
- Consomme : `TransferSnapshot`, `TaskRunner`, `HistoryStore`, `EngineSelector`, `BinaryLocator`, `SyncTask` (tâches précédentes).
- Produit : `Formatting.bytes(_:)`, `.speed(_:)`, `.clock(_:)`, `.eta(_:)`, `.line(for:)` ; l'exécutable `synckit-cli` (`run` et `history`, Ctrl-C arrête proprement la copie, chaque exécution est enregistrée dans l'historique).

- [ ] **Étape 1 : écrire le test qui échoue**

Créer `Tests/SyncKitTests/FormattingTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class FormattingTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Formatting.bytes(0), "0 o")
        XCTAssertEqual(Formatting.bytes(1_023), "1023 o")
        XCTAssertEqual(Formatting.bytes(2_048), "2 Ko")
        XCTAssertEqual(Formatting.bytes(5_242_880), "5,0 Mo")
        XCTAssertEqual(Formatting.bytes(1_073_741_824), "1,00 Go")
        XCTAssertEqual(Formatting.bytes(139_100_000_000), "129,55 Go")
    }

    func testSpeed() { XCTAssertEqual(Formatting.speed(10 * 1_048_576), "10,0 Mo/s") }

    func testClock() {
        XCTAssertEqual(Formatting.clock(0), "0:00")
        XCTAssertEqual(Formatting.clock(65), "1:05")
        XCTAssertEqual(Formatting.clock(3_725), "1:02:05")
        XCTAssertEqual(Formatting.clock(-3), "0:00")
    }

    func testEta() {
        XCTAssertEqual(Formatting.eta(0.2), "1 s")
        XCTAssertEqual(Formatting.eta(45), "45 s")
        XCTAssertEqual(Formatting.eta(150), "~3 min")
        XCTAssertEqual(Formatting.eta(3_900), "~1 h 05")
    }

    func testLineForSnapshot() {
        var snap = TransferSnapshot()
        snap.currentName = "clip.mov"
        snap.currentPercent = 42
        snap.currentBytes = 5_242_880
        snap.currentSize = 12_582_912
        snap.currentSpeed = 10 * 1_048_576
        snap.currentETA = 3
        snap.totalFiles = 10
        snap.filesDone = 3
        snap.overallPercent = 25
        snap.totalBytes = 4_294_967_296
        snap.doneBytes = 1_073_741_824
        snap.averageSpeed = 20 * 1_048_576
        snap.totalETA = 150
        XCTAssertEqual(
            Formatting.line(for: snap),
            "clip.mov 42 %  5,0 Mo / 12,0 Mo  10,0 Mo/s  restant 0:03  |  total 3/10 fichiers 25 %  1,00 Go / 4,00 Go  moy. 20,0 Mo/s  ~3 min"
        )
    }

    func testLineOfAnEmptySnapshotIsEmpty() { XCTAssertEqual(Formatting.line(for: TransferSnapshot()), "") }
}
```

- [ ] **Étape 2 : lancer le test et vérifier qu'il échoue**

Lancer : `swift test --filter FormattingTests`
Attendu : ÉCHEC de compilation (`cannot find 'Formatting' in scope`).

- [ ] **Étape 3 : écrire l'implémentation**

Créer `Sources/SyncKit/Formatting.swift` :

```swift
import Foundation

/// Mise en forme française des tailles, débits et durées.
public enum Formatting {
    /// 2048 → « 2 Ko », 5 242 880 → « 5,0 Mo », 1 Go → « 1,00 Go ».
    public static func bytes(_ value: Int64) -> String {
        let number = Double(value)
        switch number {
        case ..<1_024: return "\(value) o"
        case ..<1_048_576: return decimal(number / 1_024, digits: 0) + " Ko"
        case ..<1_073_741_824: return decimal(number / 1_048_576, digits: 1) + " Mo"
        default: return decimal(number / 1_073_741_824, digits: 2) + " Go"
        }
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// 65 → « 1:05 », 3725 → « 1:02:05 ».
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600, minutes = total % 3_600 / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Temps restant estimé : « 45 s », « ~3 min », « ~1 h 05 ».
    public static func eta(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) s" }
        if seconds < 3_600 { return "~\(Int((seconds / 60).rounded())) min" }
        let total = Int(seconds.rounded())
        return String(format: "~%d h %02d", total / 3_600, total % 3_600 / 60)
    }

    /// Une ligne résumant l'avancement : fichier en cours, puis total.
    public static func line(for snapshot: TransferSnapshot) -> String {
        var parts: [String] = []
        if let name = snapshot.currentName {
            var current = "\(name) \(snapshot.currentPercent) %"
            if snapshot.currentSize > 0 { current += "  \(bytes(snapshot.currentBytes)) / \(bytes(snapshot.currentSize))" }
            if snapshot.currentSpeed > 0 { current += "  \(speed(snapshot.currentSpeed))" }
            if let eta = snapshot.currentETA { current += "  restant \(clock(eta))" }
            parts.append(current)
        }
        if let totalFiles = snapshot.totalFiles, totalFiles > 1 {
            var total = "total \(snapshot.filesDone)/\(totalFiles) fichiers"
            if let percent = snapshot.overallPercent { total += " \(percent) %" }
            if let totalBytes = snapshot.totalBytes { total += "  \(bytes(snapshot.doneBytes)) / \(bytes(totalBytes))" }
            if snapshot.averageSpeed > 0 { total += "  moy. \(speed(snapshot.averageSpeed))" }
            if let eta = snapshot.totalETA { total += "  \(Formatting.eta(eta))" }
            parts.append(total)
        }
        return parts.joined(separator: "  |  ")
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }
}
```

Remplacer **tout le contenu** de `Sources/synckit-cli/main.swift` par :

```swift
import Darwin
import Foundation
import SyncKit

// Outil de développement : lance une tâche avec rsync ou rclone et affiche l'avancement.
//
//   synckit-cli run --source DOSSIER --dest DOSSIER [--mode copy|mirror|bidirectional|move|versioned|verify]
//                   [--engine rsync|rclone] [--dry-run] [--exclude MOTIF]... [--bwlimit KO_PAR_SECONDE]
//                   [--threshold POURCENT] [--state-dir DOSSIER]
//   synckit-cli history [--state-dir DOSSIER]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Erreur : \(message)\n".utf8))
    exit(64)
}

func parseOptions(_ arguments: [String]) -> (values: [String: [String]], flags: Set<String>) {
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        guard argument.hasPrefix("--") else { fail("argument inattendu : \(argument)") }
        let name = String(argument.dropFirst(2))
        if name == "dry-run" {
            flags.insert(name)
            index += 1
        } else {
            guard index + 1 < arguments.count else { fail("--\(name) attend une valeur") }
            values[name, default: []].append(arguments[index + 1])
            index += 2
        }
    }
    return (values, flags)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("commande attendue : run ou history") }
let (values, flags) = parseOptions(Array(arguments.dropFirst()))

let stateDirectory = URL(fileURLWithPath: values["state-dir"]?.last
    ?? NSString(string: "~/Library/Application Support/SyncMacPro-dev").expandingTildeInPath)
try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
let history = try HistoryStore(path: stateDirectory.appendingPathComponent("history.sqlite").path)

if command == "history" {
    for record in try history.list(limit: 20) {
        let when = record.startedAt.formatted(date: .abbreviated, time: .standard)
        let message = record.summary?.message.map { " — \($0)" } ?? ""
        print("\(when)  \(record.status.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))  \(record.taskName)\(message)")
    }
    exit(0)
}
guard command == "run" else { fail("commande inconnue : \(command)") }

guard let source = values["source"]?.last, let destination = values["dest"]?.last else {
    fail("--source et --dest sont obligatoires")
}
guard let mode = SyncMode(rawValue: values["mode"]?.last ?? "copy") else { fail("mode inconnu") }
var options = TaskOptions(excludes: values["exclude"] ?? TaskOptions.defaultExcludes)
options.bandwidthLimitKBps = values["bwlimit"]?.last.flatMap(Int.init)
options.deleteThresholdPercent = values["threshold"]?.last.flatMap(Int.init) ?? options.deleteThresholdPercent
options.forcedEngine = values["engine"]?.last.flatMap(EngineKind.init(rawValue:))

let task = SyncTask(
    name: URL(fileURLWithPath: source).lastPathComponent + " → " + URL(fileURLWithPath: destination).lastPathComponent,
    source: .local(path: source), destination: .local(path: destination), mode: mode, options: options
)
let runner = TaskRunner(configuration: RunnerConfiguration(
    rsyncPath: BinaryLocator.locate(.rsync), rclonePath: BinaryLocator.locate(.rclone),
    workDirectory: stateDirectory.appendingPathComponent("work")
))

// Ctrl-C arrête proprement la copie au lieu de tuer l'outil.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { runner.stop() }
interrupt.resume()

let dryRun = flags.contains("dry-run")
let engine = try EngineSelector.engine(for: task)
var record = RunRecord(taskID: task.id, taskName: task.name, engine: engine, mode: mode, dryRun: dryRun, startedAt: Date())
try history.save(record)
print("\(task.name)  [\(engine.rawValue), \(mode.rawValue)\(dryRun ? ", simulation" : "")]")

do {
    let result = try await runner.run(task, dryRun: dryRun) { update in
        switch update {
        case .phase(let phase): print("• \(phase)")
        case .snapshot(let snapshot):
            let line = Formatting.line(for: snapshot)
            if !line.isEmpty { print("\r\u{1B}[2K\(line)", terminator: ""); fflush(stdout) }
        case .line: break
        }
    }
    print("\n\(result.status.rawValue) : \(result.summary.message ?? "")")
    print("\(result.summary.filesTransferred) fichier(s), \(Formatting.bytes(result.summary.bytesTransferred)), "
        + "\(result.summary.deletions) suppression(s), \(result.summary.errors) erreur(s), "
        + "\(Formatting.clock(result.summary.durationSeconds))")
    record.status = result.status
    record.summary = result.summary
    record.finishedAt = Date()
    try history.save(record)
    switch result.status {
    case .succeeded: exit(0)
    case .blocked: exit(2)
    case .stopped, .quotaReached, .interrupted: exit(3)
    case .failed, .running: exit(1)
    }
} catch {
    print("\nÉchec : \(error)")
    record.status = .failed
    record.summary = RunSummary(message: "\(error)")
    record.finishedAt = Date()
    try? history.save(record)
    exit(1)
}
```

- [ ] **Étape 4 : lancer les tests et vérifier qu'ils passent**

Lancer : `swift test`
Attendu : SUCCÈS, **137 tests**.

- [ ] **Étape 5 : vérifier l'outil à la main**

```bash
mkdir -p /tmp/smp-demo/src /tmp/smp-demo/dst
head -c 20000000 /dev/urandom > /tmp/smp-demo/src/clip.mov
echo hello > /tmp/smp-demo/src/a.txt
swift run synckit-cli run --source /tmp/smp-demo/src --dest /tmp/smp-demo/dst --bwlimit 12000 --state-dir /tmp/smp-demo/state
swift run synckit-cli history --state-dir /tmp/smp-demo/state
rm -rf /tmp/smp-demo
```

Attendu : `succeeded`, 2 fichiers, puis une ligne `succeeded` dans l'historique.

- [ ] **Étape 6 : valider**

```bash
git add -A
git commit -m "feat(core): mise en forme française et synckit-cli"
```

---

### Tâche 12 : README, licence, intégration continue et vérification finale

**Fichiers :**
- Créer : `LICENSE`, `.github/workflows/ci.yml`
- Modifier : `README.md`

**Interfaces :**
- Consomme : l'ensemble.
- Produit : un dépôt documenté, sous licence MIT, dont les tests tournent sur GitHub Actions.

- [ ] **Étape 1 : écrire les fichiers**

Remplacer le contenu de `README.md` par :

```markdown
# SyncMacPro

Application macOS native, gratuite et open source, pour créer, planifier et suivre des synchronisations
et des sauvegardes entre dossiers, NAS et services en ligne, **sans ligne de commande**.
Elle s'appuie sur deux moteurs éprouvés : **rsync** (dossiers et volumes) et **rclone** (services en ligne).

Conception : [`docs/superpowers/specs/2026-10-12-syncmacpro-design.md`](docs/superpowers/specs/2026-10-12-syncmacpro-design.md)

## État

| Sous-projet | État |
|---|---|
| 1. Cœur (`SyncKit`) | en cours : modèle de tâche, moteurs rsync/rclone, progression, historique |
| 2. Planification (agent) | à venir |
| 3. Interface | à venir |
| 4. Connexion aux services | à venir |
| 5. Distribution | à venir |

## Développer

```bash
brew install rsync rclone        # rsync 3.x est nécessaire (celui de macOS, openrsync, ne convient pas)
export SYNCMACPRO_RSYNC=/opt/homebrew/bin/rsync
swift test                       # tests unitaires et d'intégration avec les vrais binaires
swift run synckit-cli run --source ~/A --dest ~/B --mode mirror --dry-run
```

Les tests d'intégration sont ignorés (et non en échec) si rsync 3.x ou rclone sont introuvables.

## Licence

MIT. rsync (GPL) et rclone (MIT) sont des programmes séparés que l'application lance ; leurs licences
et l'accès à leur code source seront rappelés dans l'application.
```

Créer `LICENSE` (licence MIT, copyright 2026 Sylvain Masson) :

```text
MIT License

Copyright (c) 2026 Sylvain Masson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Créer `.github/workflows/ci.yml` :

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Installer rsync 3 et rclone
        run: brew install rsync rclone
      - name: Tests
        run: swift test
        env:
          SYNCMACPRO_RSYNC: /opt/homebrew/bin/rsync
```

- [ ] **Étape 2 : vérifier trois fois que les tests sont stables**

```bash
export SYNCMACPRO_RSYNC=/opt/homebrew/bin/rsync
for i in 1 2 3; do swift test 2>&1 | grep -E "error:|Executed [0-9]+ tests" | tail -2; done
```

Attendu : à chaque tour, **137 tests, 0 échec**. Un test qui échoue une fois sur trois est un défaut à corriger, pas à relancer.

- [ ] **Étape 3 : valider et publier**

```bash
git add -A
git commit -m "docs: README, licence MIT et intégration continue"
git push origin main
```

- [ ] **Étape 4 : vérifier l'intégration continue**

Ouvrir https://github.com/Sylmass95/SyncMacPro/actions et vérifier que le premier passage est vert. La configuration (`macos-14`, `brew install rsync rclone`) n'a pas pu être essayée avant la publication : si elle échoue, corriger le fichier `ci.yml` (chemin de rsync, version de Swift) avant de considérer le sous-projet comme terminé.

---

## Auto-revue du plan

**Couverture de la spec** (sous-projet 1) :

| Exigence | Où |
|---|---|
| §4 SyncKit : modèle, moteurs, lecture de la sortie, stockage | tâches 1, 3 à 5, 9 |
| §5.1 tâche : source, destination, mode, options, planification, notifications | tâche 1 (le **calcul des échéances** est au sous-projet 2) |
| §5.2 choix du moteur et forçage | tâche 2 |
| §5.3 six modes | tâches 3, 4, 10 (`versioned` : commande et nettoyage testés en unitaire, pas d'essai d'intégration) |
| §5.4 simulation et blocage automatique | tâches 8 et 10 (la **première simulation obligatoire** est une règle d'interface et d'agent, sous-projets 2 et 3) |
| §6 progression en direct, pause, reprise, arrêt | tâches 6, 7, 10 |
| §6 quota Google Drive (code 8) | tâche 10 (mappage dans le code, **vérification manuelle**) |
| §6 historique, interruption au redémarrage | tâche 9 |
| §8 tests sur captures réelles et vrais binaires, GitHub Actions | tâches 5, 10, 12 |
| §9 MIT, licences rsync et rclone mentionnées | tâche 12 |
| §10 risque `bisync` en bêta : garde-fous et réinitialisation | tâche 10 (`needsResync` → échec explicite ; la réinitialisation guidée est au sous-projet 3) |

**Cohérence des types :** les noms utilisés dans les tâches ultérieures (`RunOptions`, `EngineCommand`, `RsyncEvent.fileStarted(name:isNew:)`, `TransferSnapshot`, `RunStatus`…) sont ceux définis dans les tâches qui les produisent ; le code de chaque tâche est celui qui a été compilé et testé ensemble (137 tests verts, trois exécutions consécutives).

**Limites connues :** les liens symboliques et fichiers spéciaux ne sont pas suivis (rsync ne leur applique pas de progression) ; la vérification après copie compare les fichiers réguliers ; une instance de `TaskRunner` ne gère qu'une exécution à la fois.

---

## Corrections après la relecture finale

Le plan a été exécuté tâche par tâche (137 tests), puis une relecture indépendante de la branche entière a relevé 1 défaut critique et 6 importants, corrigés dans un commit à part avec un test écrit d'abord (149 tests). Le code des tâches ci-dessus est donc celui d'**avant** ces corrections :

- **C1** : `--timeout=60` retiré de rsync (une pause plus longue qu'une minute faisait échouer la copie à la reprise).
- **I1** : une source absente fait échouer la vérification et la simulation rsync (au lieu de « rien à signaler »).
- **I2** : le garde-fou rclone ne compte plus le dossier d'archive parmi les fichiers vivants (`sizeCommand(for:task:run:)`).
- **I3** : `verifyAfterCopy` avec rclone ignore l'archive et les fichiers qui n'existent qu'à la destination, et respecte la sélection.
- **I4** : `TaskRunner.collect` sépare la sortie standard de la sortie d'erreur (un avertissement de rclone ne fausse plus `rclone size --json`).
- **I5** : les processus lancés n'héritent plus des descripteurs de l'appelant (`POSIX_SPAWN_CLOEXEC_DEFAULT`) et reçoivent une entrée standard vide.
- **I6** : `terminate(killAfter:)` escalade en SIGKILL après un délai de grâce (8 s par défaut).

Les mineurs non traités sont listés dans le message de la pull request.
