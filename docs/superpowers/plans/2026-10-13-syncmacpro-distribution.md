# SyncMacPro — sous-projet 5 (distribution) : plan d'implémentation

> **Pour les agents :** SOUS-COMPÉTENCE REQUISE : superpowers:executing-plans (exécution native, en autonomie). Les étapes utilisent la syntaxe à cases (`- [ ]`).

**Objectif :** un DMG de SyncMacPro avec rsync et rclone embarqués (universels, empreintes vérifiées), signé ad hoc, avec licences, vérification des mises à jour, diagnostic et workflow de publication.

**Architecture :** le code apprend à trouver les binaires dans le bundle et à comparer des versions ; des scripts shell fabriquent les binaires vérifiés, l'icône, l'app universelle et le DMG ; un workflow GitHub publie sur étiquette.

**Stack :** Swift 5.9 (mode 5), SwiftUI, XCTest, bash, `hdiutil`, `lipo`, `codesign`, `iconutil`.

**Spec :** `docs/superpowers/specs/2026-10-13-syncmacpro-distribution-design.md`

## Contraintes globales

- macOS 14, swift-tools 5.9, mode Swift 5, aucune dépendance externe.
- CI Swift 5.10 / SDK macOS 14 : vues `@MainActor` ; pas de `var` capturé dans une closure `@Sendable`. PR brouillon #8 poussée après chaque tâche.
- Téléchargements autorisés par l'auteur : rsync 3.5.1 (download.samba.org) et rclone 1.75.1 (downloads.rclone.org), **toujours vérifiés** par empreinte épinglée.
- Empreintes : rsync-3.5.1.tar.gz `c55f9c9dc10fb8bec397b399a0fdded53cc9a2d8e30891bb0d63724d25c37bef` ; rclone-v1.75.1-osx-arm64.zip `c61d7a371c62bcbbe882c3423aa4b8bf63485c248dd0f692997b8f0c3f6d0c6f` ; rclone-v1.75.1-osx-amd64.zip `29253d0288b8fbbac46baad6e5f6add6cb01d462c79f10805bbd4631c4cdf82c` (identiques au `SHA256SUMS` officiel de rclone).
- Textes : `Localizer`, fr et en ; préfixe nouveau `update` ajouté au test de complétude.
- Jamais d'étiquette ni de publication GitHub sans l'auteur.
- Commits terminés par `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Décisions prises en rédigeant le plan

- **Ruling : `ctl doctor`** n'interroge pas l'agent pour les binaires (il cherche comme l'agent, depuis son propre emplacement dans le même bundle) ; il affiche en plus l'état de l'agent s'il répond.
- **Ruling : fixture GitHub écrite à la main** d'après le format documenté (`tag_name`, `html_url`, `draft`, `prerelease`) : le dépôt n'a encore aucune publication à capturer.
- **Ruling : version 1.0.0** pour la première publication.

## Points de revue

1. Empreinte fausse ou fichier tronqué (site de rsync instable) : la construction échoue, rien n'est embarqué. → tâche 4.
2. App lancée depuis le DMG ou translocalisée : message clair au lieu d'un agent qui disparaît. → tâche 3.
3. Réponse GitHub inattendue (publication brouillon, pré-version, limite de débit 403, pas de publication 404) : pas de bandeau trompeur. → tâche 2.
4. Binaire embarqué présent mais inutilisable (mauvaise architecture, abîmé) : retour aux binaires du système. → tâche 1.
5. Deux vérifications de mise à jour simultanées (lancement + bouton) : un seul résultat cohérent. → tâche 3.

---

### Tâche 1 : binaires du bundle, version, `ctl version` et `ctl doctor`

**Fichiers :** modifier `Sources/SyncKit/BinaryLocator.swift`, `Sources/syncmacpro-agent/main.swift`, `Sources/SyncKit/Agent/CtlParser.swift`, `Sources/syncmacpro-ctl/main.swift`, `Tests/SyncKitTests/ProcessRunnerTests.swift` (`BinaryLocatorTests`), `Tests/SyncKitTests/CtlTests.swift` ; créer `Sources/SyncKit/AppInfo.swift`, `VERSION`.

**Interfaces (produit) :** `BinaryLocator.embeddedDirectory(executable: String, fileManager:) -> String?` ; `BinaryLocator.locateForProcess(_ engine:) -> String?` (= `locate(engine, bundleDirectory: embeddedDirectory(executable: CommandLine.arguments[0] résolu))`) ; `enum AppInfo { static func version(executable:) -> String }` (lit `Contents/Info.plist` du bundle, `"dev"` sinon) ; `CtlCommand.version`, `.doctor`.

- [ ] **Étape 1 : tests qui échouent**

Dans `BinaryLocatorTests` :

```swift
    func testEmbeddedDirectoryIsFoundFromAnyExecutableOfTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("SyncMacPro.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources/bin"), withIntermediateDirectories: true)
        let agent = app.appendingPathComponent("MacOS/syncmacpro-agent").path
        XCTAssertEqual(BinaryLocator.embeddedDirectory(executable: agent), app.appendingPathComponent("Resources/bin").path)
        XCTAssertNil(BinaryLocator.embeddedDirectory(executable: "/usr/local/bin/syncmacpro-agent"))
        XCTAssertNil(BinaryLocator.embeddedDirectory(executable: root.appendingPathComponent("x/MacOS/y").path),
                     "pas de Resources/bin : rien")
    }

    func testEmbeddedBinaryWinsOverTheSystemButNotOverTheEnvironment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = folder.appendingPathComponent("bundle"), system = folder.appendingPathComponent("system")
        for dir in [bundle, system] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try fakeRsync(at: dir.appendingPathComponent("rsync"), firstLine: "rsync  version 3.5.1  protocol version 33")
        }
        let found = BinaryLocator.locate(.rsync, environment: [:], bundleDirectory: bundle.path, searchDirectories: [system.path])
        XCTAssertEqual(found, bundle.appendingPathComponent("rsync").path)
        let forced = BinaryLocator.locate(.rsync, environment: ["SYNCMACPRO_RSYNC": system.appendingPathComponent("rsync").path],
                                          bundleDirectory: bundle.path, searchDirectories: [])
        XCTAssertEqual(forced, system.appendingPathComponent("rsync").path)
    }

    func testBrokenEmbeddedBinaryFallsBackToTheSystem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = folder.appendingPathComponent("bundle"), system = folder.appendingPathComponent("system")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try Data("pas un programme".utf8).write(to: bundle.appendingPathComponent("rsync"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appendingPathComponent("rsync").path)
        try fakeRsync(at: system.appendingPathComponent("rsync"), firstLine: "rsync  version 3.4.1  protocol version 32")
        let found = BinaryLocator.locate(.rsync, environment: [:], bundleDirectory: bundle.path, searchDirectories: [system.path])
        XCTAssertEqual(found, system.appendingPathComponent("rsync").path)
    }

    func testAppVersionComesFromTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("SyncMacPro.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "321"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(AppInfo.version(executable: contents.appendingPathComponent("MacOS/syncmacpro-ctl").path), "1.0.0 (321)")
        XCTAssertEqual(AppInfo.version(executable: "/usr/local/bin/syncmacpro-ctl"), "dev")
    }
```

(`fakeRsync(at:firstLine:)` existe déjà dans ces tests ; s'il a une autre signature, l'adapter.)

Dans `CtlParserTests` :

```swift
    func testVersionAndDoctor() throws {
        XCTAssertEqual(try parse("version").command, .version)
        XCTAssertEqual(try parse("--version").command, .version)
        XCTAssertEqual(try parse("doctor").command, .doctor)
        XCTAssertEqual(try parse("diagnostic").command, .doctor)
    }
```

- [ ] **Étape 2 : implémenter**

`BinaryLocator.swift` :

```swift
    /// `…/X.app/Contents/MacOS/programme` → `…/X.app/Contents/Resources/bin`, s'il existe.
    public static func embeddedDirectory(executable: String, fileManager: FileManager = .default) -> String? {
        let url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let macOS = url.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS" else { return nil }
        let bin = macOS.deletingLastPathComponent().appendingPathComponent("Resources/bin")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bin.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return bin.path
    }

    /// Le chemin de l'exécutable en cours (agent, ctl, app).
    public static var currentExecutable: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Recherche pour le programme en cours : binaires de son bundle d'abord.
    public static func locateForProcess(_ engine: EngineKind) -> String? {
        locate(engine, bundleDirectory: embeddedDirectory(executable: currentExecutable))
    }
```

`isSupported` : un binaire qui ne se lance pas (abîmé, mauvaise architecture) doit être écarté **aussi pour rclone** : pour rclone, lancer `rclone version` et exiger un code 0 et une première ligne commençant par `rclone v` (même mécanique que rsync). Le test `testBrokenEmbeddedBinaryFallsBackToTheSystem` porte sur rsync ; ajouter un test jumeau pour rclone avec un faux rclone (script `#!/bin/sh\necho "rclone v1.75.1"`).

`AppInfo.swift` :

```swift
import Foundation

/// Version de l'app à partir du bundle qui contient l'exécutable (« dev » hors bundle).
public enum AppInfo {
    public static func version(executable: String = BinaryLocator.currentExecutable) -> String {
        let contents = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let short = plist["CFBundleShortVersionString"] as? String
        else { return "dev" }
        if let build = plist["CFBundleVersion"] as? String { return "\(short) (\(build))" }
        return short
    }
}
```

`syncmacpro-agent/main.swift` : `BinaryLocator.locate(.rsync)` → `BinaryLocator.locateForProcess(.rsync)` (idem rclone) ; le journal de démarrage cite aussi rclone et la version (`AppInfo.version()`).

`CtlParser` : `case version, doctor` ; alias `"diagnostic": "doctor"` ; `"--version"` reconnu comme commande (avant le traitement des options : si `arguments == ["--version"]`, renvoyer `.version`) ; `switch` : `case "version": return invocation(.version)`, `case "doctor": return invocation(.doctor)` ; usage : `version`, `doctor                         binaires rsync et rclone retenus, état de l'agent`.

`syncmacpro-ctl/main.swift` :

```swift
    case .version:
        print("SyncMacPro \(AppInfo.version())")

    case .doctor:
        print("SyncMacPro \(AppInfo.version())")
        for engine in [EngineKind.rsync, .rclone] {
            if let path = BinaryLocator.locateForProcess(engine) {
                print("\(engine.rawValue) : \(path) — \(CtlFormatter.firstLine(of: path, arguments: engine == .rsync ? ["--version"] : ["version"]))")
            } else {
                print("\(engine.rawValue) : introuvable")
            }
        }
        do {
            let status = try await client.status()
            print("Agent : répond (\(status.tasks.count) tâche(s), pause globale : \(status.globalPause ? "oui" : "non"))")
        } catch {
            print("Agent : ne répond pas (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))")
        }
```

`CtlFormatter.firstLine(of:arguments:)` (dans `CtlSupport.swift`) : lance le programme, renvoie la première ligne de sa sortie (`Process`, sortie standard, entrée vide).

`VERSION` : `1.0.0`.

- [ ] **Étape 3 : vérifier** — `swift test --filter "BinaryLocatorTests|CtlParserTests"` → passent ; suite complète verte.

- [ ] **Étape 4 : commit et push** — `git commit -m "Binaires du bundle d'abord ; version de l'app ; ctl version et doctor"`.

---

### Tâche 2 : versions, vérification des mises à jour, emplacement de l'app (logique)

**Fichiers :** créer `Sources/SyncMacProUI/Updates/SemanticVersion.swift`, `Sources/SyncMacProUI/Updates/UpdateChecker.swift`, `Sources/SyncMacProUI/Updates/InstallLocation.swift`, `Tests/SyncMacProUITests/UpdatesTests.swift`, `Tests/SyncMacProUITests/Fixtures/github_release_latest.json` (et `resources: [.copy("Fixtures")]` pour `SyncMacProUITests` dans `Package.swift`).

**Interfaces :**
- `struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible` : `init?(_ text: String)` (accepte `v1.2.3`, `1.2`, `1.2.3-beta` → pré-version) ;
- `struct ReleaseInfo: Equatable, Sendable` (`version`, `url`) ;
- `enum UpdateCheckResult: Equatable` : `upToDate`, `available(ReleaseInfo)`, `failed(String)` ;
- `struct UpdateChecker` : `init(current: String, fetch: @escaping @Sendable (URL) async throws -> (Data, Int))` ; `func check() async -> UpdateCheckResult` ; `static let latestURL` ; `static func parse(_ data: Data, status: Int, current: SemanticVersion?) -> UpdateCheckResult` ; `static func isDue(lastCheck: Date?, now: Date) -> Bool` (24 h) ;
- `enum InstallLocationProblem: Equatable { translocated, diskImage }` ; `enum InstallLocation { static func problem(bundlePath:) -> InstallLocationProblem? }`.

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncMacProUITests/Fixtures/github_release_latest.json` :

```json
{
  "url": "https://api.github.com/repos/Sylmass95/SyncMacPro/releases/1",
  "html_url": "https://github.com/Sylmass95/SyncMacPro/releases/tag/v1.2.0",
  "tag_name": "v1.2.0",
  "name": "SyncMacPro 1.2.0",
  "draft": false,
  "prerelease": false,
  "published_at": "2026-11-02T09:00:00Z",
  "assets": [{ "name": "SyncMacPro-1.2.0.dmg", "browser_download_url": "https://github.com/Sylmass95/SyncMacPro/releases/download/v1.2.0/SyncMacPro-1.2.0.dmg" }]
}
```

`Tests/SyncMacProUITests/UpdatesTests.swift` :

```swift
import XCTest
@testable import SyncMacProUI

final class UpdatesTests: XCTestCase {
    func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "github_release_latest", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testVersions() throws {
        let v = try XCTUnwrap(SemanticVersion("v1.2.3"))
        XCTAssertEqual(v.description, "1.2.3")
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.2.9")), try XCTUnwrap(SemanticVersion("1.10.0")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("2.0.0-beta")), try XCTUnwrap(SemanticVersion("2.0.0")))
        XCTAssertNil(SemanticVersion("dev"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertEqual(SemanticVersion("1.0.0 (321)"), SemanticVersion("1.0.0"), "le numéro de construction est ignoré")
    }

    func testNewerReleaseIsOffered() throws {
        let result = UpdateChecker.parse(try fixture(), status: 200, current: SemanticVersion("1.0.0"))
        XCTAssertEqual(result, .available(ReleaseInfo(
            version: try XCTUnwrap(SemanticVersion("1.2.0")),
            url: try XCTUnwrap(URL(string: "https://github.com/Sylmass95/SyncMacPro/releases/tag/v1.2.0"))
        )))
        XCTAssertEqual(UpdateChecker.parse(try fixture(), status: 200, current: SemanticVersion("1.2.0")), .upToDate)
        XCTAssertEqual(UpdateChecker.parse(try fixture(), status: 200, current: SemanticVersion("1.3.0")), .upToDate)
    }

    func testDevBuildsAreNeverNagged() throws {
        XCTAssertEqual(UpdateChecker.parse(try fixture(), status: 200, current: nil), .upToDate)
    }

    func testUnusableAnswers() throws {
        XCTAssertEqual(UpdateChecker.parse(Data(), status: 404, current: SemanticVersion("1.0.0")), .upToDate, "aucune publication")
        guard case .failed = UpdateChecker.parse(Data(#"{"message":"API rate limit exceeded"}"#.utf8), status: 403, current: SemanticVersion("1.0.0")) else {
            return XCTFail()
        }
        guard case .failed = UpdateChecker.parse(Data("<html>".utf8), status: 200, current: SemanticVersion("1.0.0")) else { return XCTFail() }
        let draft = Data(#"{"tag_name":"v9.0.0","html_url":"https://x","draft":true,"prerelease":false}"#.utf8)
        XCTAssertEqual(UpdateChecker.parse(draft, status: 200, current: SemanticVersion("1.0.0")), .upToDate)
        let beta = Data(#"{"tag_name":"v9.0.0-beta","html_url":"https://x","draft":false,"prerelease":true}"#.utf8)
        XCTAssertEqual(UpdateChecker.parse(beta, status: 200, current: SemanticVersion("1.0.0")), .upToDate)
    }

    func testCheckUsesTheFetcher() async throws {
        let data = try fixture()
        let checker = UpdateChecker(current: "1.0.0 (12)") { url in
            XCTAssertEqual(url, UpdateChecker.latestURL)
            return (data, 200)
        }
        let result = await checker.check()
        guard case .available(let release) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(release.version.description, "1.2.0")
        let offline = UpdateChecker(current: "1.0.0") { _ in throw URLError(.notConnectedToInternet) }
        guard case .failed = await offline.check() else { return XCTFail() }
    }

    func testOncePerDay() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-90_000), now: now))
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(3_600), now: now), "horloge reculée : on vérifie")
    }

    func testInstallLocation() {
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Applications/SyncMacPro.app"))
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Users/moi/Applications/SyncMacPro.app"))
        XCTAssertEqual(InstallLocation.problem(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/SyncMacPro.app"), .translocated)
        XCTAssertEqual(InstallLocation.problem(bundlePath: "/Volumes/SyncMacPro 1.0.0/SyncMacPro.app"), .diskImage)
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Users/moi/Desktop/PROJET/.build/debug/SyncMacPro"), "développement : pas un bundle")
    }
}
```

- [ ] **Étape 2 : implémenter**

`SemanticVersion.swift` :

```swift
import Foundation

/// « 1.2.3 », « v1.2 », « 2.0.0-beta » (pré-version, plus ancienne que 2.0.0) ; « 1.0.0 (321) » ignore la construction.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if let space = value.firstIndex(of: " ") { value = String(value[..<space]) }
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let pieces = value.split(separator: "-", maxSplits: 1).map(String.init)
        guard let numbers = pieces.first, !numbers.isEmpty else { return nil }
        let parsed = numbers.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parsed.isEmpty, parsed.count <= 3, parsed.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        var all = parsed.compactMap { $0 }
        while all.count < 3 { all.append(0) }
        parts = all
        prerelease = pieces.count > 1 ? pieces[1] : nil
    }

    public var description: String {
        parts.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.parts != rhs.parts { return lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let a?, let b?): return a < b
        }
    }
}
```

`UpdateChecker.swift` :

```swift
import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: SemanticVersion
    public let url: URL
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(ReleaseInfo)
    case failed(String)
}

/// Lit la dernière publication GitHub ; n'installe rien.
public struct UpdateChecker: Sendable {
    public static let latestURL = URL(string: "https://api.github.com/repos/Sylmass95/SyncMacPro/releases/latest")!
    public static let interval: TimeInterval = 86_400

    let current: SemanticVersion?
    let fetch: @Sendable (URL) async throws -> (Data, Int)

    public init(current: String, fetch: @escaping @Sendable (URL) async throws -> (Data, Int) = UpdateChecker.network) {
        self.current = SemanticVersion(current)
        self.fetch = fetch
    }

    public static let network: @Sendable (URL) async throws -> (Data, Int) = { url in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func check() async -> UpdateCheckResult {
        do {
            let (data, status) = try await fetch(Self.latestURL)
            return Self.parse(data, status: status, current: current)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public static func parse(_ data: Data, status: Int, current: SemanticVersion?) -> UpdateCheckResult {
        if status == 404 { return .upToDate }   // aucune publication encore
        struct Release: Decodable {
            var tag_name: String
            var html_url: String
            var draft: Bool?
            var prerelease: Bool?
        }
        guard status == 200 else {
            struct Message: Decodable { var message: String }
            let message = (try? JSONDecoder().decode(Message.self, from: data))?.message ?? "HTTP \(status)"
            return .failed(message)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let version = SemanticVersion(release.tag_name), let url = URL(string: release.html_url)
        else { return .failed("réponse illisible") }
        guard release.draft != true, release.prerelease != true, let current, current < version else { return .upToDate }
        return .available(ReleaseInfo(version: version, url: url))
    }

    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }
}
```

`InstallLocation.swift` :

```swift
import Foundation

public enum InstallLocationProblem: Equatable, Sendable {
    /// Gatekeeper a lancé une copie temporaire : l'agent installé disparaîtrait avec elle.
    case translocated
    /// Lancée depuis le DMG : le volume sera éjecté.
    case diskImage
}

public enum InstallLocation {
    public static func problem(bundlePath: String) -> InstallLocationProblem? {
        guard bundlePath.hasSuffix(".app") else { return nil }
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") { return .diskImage }
        return nil
    }
}
```

`Package.swift` : `.testTarget(name: "SyncMacProUITests", dependencies: ["SyncMacProUI"], resources: [.copy("Fixtures")])` (garder le reste).

- [ ] **Étape 3 : vérifier** — `swift test --filter UpdatesTests` → 7 tests passent.

- [ ] **Étape 4 : commit et push** — `git commit -m "Versions, vérification des mises à jour (GitHub) et emplacement de l'app"`.

---

### Tâche 3 : mises à jour et emplacement dans l'interface

**Fichiers :** créer `Sources/SyncMacProUI/Updates/UpdateModel.swift`, `Tests/SyncMacProUITests/UpdateModelTests.swift` ; modifier `SettingsView.swift`, `DashboardView.swift`, `OnboardingView.swift`, `RootView.swift`, `SyncMacProApp.swift`, chaînes `update.*`, `settings.*`, `onboarding.location.*`, test de complétude (`update`), rendus.

**Interfaces :**
- `@MainActor @Observable final class UpdateModel` : `init(checker: UpdateChecker, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init)` ; `state: UpdateState` (`idle`, `checking`, `upToDate`, `available(ReleaseInfo)`, `failed(String)`) ; `automatic: Bool` (UserDefaults `checkUpdates`, vrai par défaut) ; `available: ReleaseInfo?` ; `checkIfDue() async` ; `checkNow() async` (une vérification à la fois : une seconde demande attend la première et rend son résultat).
- `SettingsView(installer:loginItem:localizer:updates:)` (`updates: UpdateModel? = nil`) ; section À propos : version, licences, code source, mises à jour.
- `DashboardContent` : paramètre `update: ReleaseInfo? = nil` → bandeau `update.banner` avec « Télécharger » (ouvre l'URL) ; `DashboardView(…, updates: UpdateModel? = nil)`.
- `OnboardingView(…, location: InstallLocationProblem? = nil)` : message et bouton « Afficher dans le Finder », bouton Installer désactivé.

- [ ] **Étape 1 : tests qui échouent**

`UpdateModelTests.swift` :

```swift
import XCTest
@testable import SyncMacProUI

@MainActor
final class UpdateModelTests: XCTestCase {
    func defaults() -> UserDefaults {
        let name = "maj-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    let release = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/Sylmass95/SyncMacPro/releases/tag/v1.2.0","draft":false,"prerelease":false}"#.utf8)

    func testAutomaticCheckOncePerDay() async {
        let calls = Counter()
        let data = release
        let store = defaults()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let model = UpdateModel(checker: UpdateChecker(current: "1.0.0") { _ in calls.increment(); return (data, 200) },
                                defaults: store, now: { now })
        XCTAssertTrue(model.automatic)
        await model.checkIfDue()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(model.available?.version.description, "1.2.0")
        await model.checkIfDue()
        XCTAssertEqual(calls.value, 1, "déjà vérifié aujourd'hui")
        now = now.addingTimeInterval(90_000)
        await model.checkIfDue()
        XCTAssertEqual(calls.value, 2)
        model.automatic = false
        now = now.addingTimeInterval(90_000)
        await model.checkIfDue()
        XCTAssertEqual(calls.value, 2, "désactivé")
        await model.checkNow()
        XCTAssertEqual(calls.value, 3, "vérifier maintenant passe outre")
    }

    func testFailureIsSilentAutomaticallyButShownOnDemand() async {
        let model = UpdateModel(checker: UpdateChecker(current: "1.0.0") { _ in throw URLError(.timedOut) }, defaults: defaults())
        await model.checkIfDue()
        XCTAssertNil(model.available)
        guard case .failed = model.state else { return XCTFail() }
    }

    func testConcurrentChecksGiveOneAnswer() async {
        let calls = Counter()
        let gate = TestGate()
        let data = release
        let model = UpdateModel(checker: UpdateChecker(current: "1.0.0") { _ in
            calls.increment()
            await gate.wait()
            return (data, 200)
        }, defaults: defaults())
        async let first: Void = model.checkNow()
        async let second: Void = model.checkNow()
        try? await Task.sleep(nanoseconds: 100_000_000)
        gate.release()
        _ = await (first, second)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(model.available?.version.description, "1.2.0")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
```

Rendus (dans `DashboardRenderTests` ou un nouveau `DistributionRenderTests.swift`) : bandeau de mise à jour au tableau de bord (`DashboardContent(…, update: ReleaseInfo(...))`), accueil avec `location: .diskImage` et `.translocated`.

- [ ] **Étape 2 : implémenter**

`UpdateModel.swift` :

```swift
import Foundation
import Observation

public enum UpdateState: Equatable, Sendable {
    case idle, checking, upToDate
    case available(ReleaseInfo)
    case failed(String)
}

@MainActor
@Observable
public final class UpdateModel {
    public private(set) var state: UpdateState = .idle
    public var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Self.automaticKey) }
    }
    @ObservationIgnored let checker: UpdateChecker
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var running: Task<UpdateCheckResult, Never>?
    static let automaticKey = "checkUpdates"
    static let lastCheckKey = "lastUpdateCheck"

    public init(checker: UpdateChecker, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.checker = checker
        self.defaults = defaults
        self.now = now
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    public var available: ReleaseInfo? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// Au lancement : au plus une fois par jour, si l'utilisateur le veut.
    public func checkIfDue() async {
        guard automatic, UpdateChecker.isDue(lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date, now: now()) else { return }
        await checkNow()
    }

    /// Une seule vérification à la fois : une seconde demande attend la première.
    public func checkNow() async {
        if let running {
            _ = await running.value
            return
        }
        state = .checking
        let checker = self.checker
        let task = Task { await checker.check() }
        running = task
        let result = await task.value
        running = nil
        defaults.set(now(), forKey: Self.lastCheckKey)
        switch result {
        case .upToDate: state = .upToDate
        case .available(let release): state = .available(release)
        case .failed(let message): state = .failed(message)
        }
    }
}
```

`SyncMacProApp.swift` : `@State private var updates = UpdateModel(checker: UpdateChecker(current: AppInfo.version()))` ; transmis à `RootView` (paramètre `updates: UpdateModel? = nil`) ; `.task { await updates.checkIfDue() }` sur la fenêtre.

`RootView` : transmet `updates` à `DashboardView` et `SettingsView` ; calcule `InstallLocation.problem(bundlePath: Bundle.main.bundlePath)` pour `OnboardingView(location:)`.

`DashboardContent` (paramètre `update: ReleaseInfo? = nil`, dernier) :

```swift
            if let update {
                Banner(systemImage: "arrow.down.circle", tint: .blue, title: l.format("update.banner", update.version.description)) {
                    Button(l.text("update.download")) { NSWorkspace.shared.open(update.url) }
                }
            }
```

`SettingsView`, section À propos :

```swift
            Section(localizer.text("settings.about")) {
                Text(localizer.format("settings.version", version))
                if let updates {
                    Toggle(localizer.text("update.automatic"), isOn: Binding(get: { updates.automatic }, set: { updates.automatic = $0 }))
                    HStack {
                        Button(localizer.text("update.checkNow")) { Task { await updates.checkNow() } }
                            .disabled(updates.state == .checking)
                        Text(updateText(updates.state)).font(.callout).foregroundStyle(.secondary)
                        if let release = updates.available {
                            Button(localizer.text("update.download")) { NSWorkspace.shared.open(release.url) }
                        }
                    }
                }
                HStack {
                    Button(localizer.text("settings.licenses")) { openLicenses() }
                    Button(localizer.text("settings.source")) { NSWorkspace.shared.open(URL(string: "https://github.com/Sylmass95/SyncMacPro")!) }
                }
            }
```

avec `updateText` (`idle` → `""`, `checking` → `update.checking`, `upToDate` → `update.upToDate`, `available` → `update.available` + version, `failed` → `update.failed` + message) et `openLicenses()` qui ouvre `Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md", subdirectory: "Licenses")` (ou la page GitHub du fichier si absent : développement). `version` utilise `AppInfo.version(executable: Bundle.main.executablePath ?? "")`.

`OnboardingView` (paramètre `location: InstallLocationProblem? = nil`) : si présent, `Banner` orange `onboarding.location.diskImage` / `onboarding.location.translocated` avec bouton `onboarding.location.reveal` (`NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])`), et Installer désactivé.

Chaînes fr :

```
"update.banner" = "SyncMacPro %@ est disponible.";
"update.download" = "Télécharger";
"update.automatic" = "Vérifier les mises à jour chaque jour";
"update.checkNow" = "Vérifier maintenant";
"update.checking" = "Vérification…";
"update.upToDate" = "SyncMacPro est à jour.";
"update.available" = "Version %@ disponible.";
"update.failed" = "Vérification impossible : %@";
"settings.licenses" = "Licences";
"settings.source" = "Code source";
"onboarding.location.diskImage" = "SyncMacPro est ouverte depuis l’image disque : glissez-la dans le dossier Applications, puis rouvrez-la depuis là.";
"onboarding.location.translocated" = "macOS a lancé une copie temporaire de SyncMacPro : déplacez l’app dans le dossier Applications (avec le Finder), puis rouvrez-la.";
"onboarding.location.reveal" = "Afficher dans le Finder";
```

en :

```
"update.banner" = "SyncMacPro %@ is available.";
"update.download" = "Download";
"update.automatic" = "Check for updates daily";
"update.checkNow" = "Check now";
"update.checking" = "Checking…";
"update.upToDate" = "SyncMacPro is up to date.";
"update.available" = "Version %@ available.";
"update.failed" = "Couldn’t check: %@";
"settings.licenses" = "Licenses";
"settings.source" = "Source code";
"onboarding.location.diskImage" = "SyncMacPro is running from the disk image: drag it to the Applications folder, then reopen it from there.";
"onboarding.location.translocated" = "macOS launched a temporary copy of SyncMacPro: move the app to the Applications folder (with the Finder), then reopen it.";
"onboarding.location.reveal" = "Show in Finder";
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "UpdateModelTests|DistributionRenderTests|StringsCompletenessTests"` → passent ; suite complète verte.

- [ ] **Étape 4 : commit et push** — `git commit -m "Interface : mises à jour (bandeau, Réglages › À propos), licences, app hors d'Applications signalée"`.

---

### Tâche 4 : binaires vérifiés, icône, assemblage, DMG

**Fichiers :** créer `scripts/vendor.lock`, `scripts/fetch-vendor.sh`, `scripts/make-icon.swift`, `scripts/assemble-app.sh`, `scripts/make-release.sh`, `scripts/dmg-readme.txt`, `THIRD_PARTY_NOTICES.md` ; modifier `scripts/make-dev-bundle.sh`, `.github/workflows/ci.yml` (`bash -n scripts/*.sh`).

**Interfaces :** `scripts/fetch-vendor.sh [DOSSIER]` (défaut `.build/vendor`) → `bin/rsync`, `bin/rclone`, `licenses/rsync-COPYING`, `licenses/rclone-COPYING`, `src/rsync-3.5.1.tar.gz` ; `scripts/assemble-app.sh BIN_DIR APP VERSION BUILD [VENDOR_DIR]` ; `scripts/make-release.sh` → `build/SyncMacPro-<VERSION>.dmg`.

- [ ] **Étape 1 : `scripts/vendor.lock`**

```bash
# Versions et empreintes des programmes embarqués. Une empreinte différente arrête la construction.
RSYNC_VERSION=3.5.1
RSYNC_URL=https://download.samba.org/pub/rsync/src/rsync-3.5.1.tar.gz
RSYNC_SHA256=c55f9c9dc10fb8bec397b399a0fdded53cc9a2d8e30891bb0d63724d25c37bef
RCLONE_VERSION=1.75.1
RCLONE_ARM64_URL=https://downloads.rclone.org/v1.75.1/rclone-v1.75.1-osx-arm64.zip
RCLONE_ARM64_SHA256=c61d7a371c62bcbbe882c3423aa4b8bf63485c248dd0f692997b8f0c3f6d0c6f
RCLONE_AMD64_URL=https://downloads.rclone.org/v1.75.1/rclone-v1.75.1-osx-amd64.zip
RCLONE_AMD64_SHA256=29253d0288b8fbbac46baad6e5f6add6cb01d462c79f10805bbd4631c4cdf82c
```

- [ ] **Étape 2 : `scripts/fetch-vendor.sh`**

```bash
#!/bin/bash
# Télécharge, vérifie et prépare rsync (compilé, universel) et rclone (officiel, universel).
#
#   scripts/fetch-vendor.sh [DOSSIER]     (défaut : .build/vendor ; rien n'est refait si déjà prêt)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/vendor.lock
OUT="${1:-.build/vendor}"
mkdir -p "$OUT/bin" "$OUT/licenses" "$OUT/src" "$OUT/work"
OUT="$(cd "$OUT" && pwd)"

download() {   # URL FICHIER EMPREINTE
  local url="$1" file="$2" sum="$3" try=0
  if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sum" ]; then return 0; fi
  rm -f "$file"
  until curl -fsSL -m 600 -o "$file.part" "$url"; do
    try=$((try + 1)); rm -f "$file.part"
    [ "$try" -ge 6 ] && { echo "Téléchargement impossible : $url" >&2; exit 1; }
    echo "  nouvel essai ($try) : $url" >&2; sleep $((try * 10))
  done
  local actual; actual="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
  if [ "$actual" != "$sum" ]; then
    rm -f "$file.part"
    echo "Empreinte inattendue pour $url : $actual (attendu $sum)" >&2; exit 1
  fi
  mv "$file.part" "$file"
}

echo "==> rsync $RSYNC_VERSION"
TGZ="$OUT/src/rsync-$RSYNC_VERSION.tar.gz"
download "$RSYNC_URL" "$TGZ" "$RSYNC_SHA256"
if ! "$OUT/bin/rsync" --version 2>/dev/null | head -1 | grep -q "version $RSYNC_VERSION"; then
  rm -rf "$OUT/work/rsync"; mkdir -p "$OUT/work/rsync"
  tar -xzf "$TGZ" -C "$OUT/work/rsync" --strip-components 1
  (
    cd "$OUT/work/rsync"
    export MACOSX_DEPLOYMENT_TARGET=14.0
    CFLAGS="-O2 -arch arm64 -arch x86_64" LDFLAGS="-arch arm64 -arch x86_64" ./configure \
      --disable-xxhash --disable-zstd --disable-lz4 --disable-openssl --disable-md2man --disable-idn \
      --with-included-popt --with-included-zlib > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -20 make.log; exit 1; }
  )
  cp "$OUT/work/rsync/rsync" "$OUT/bin/rsync"
  cp "$OUT/work/rsync/COPYING" "$OUT/licenses/rsync-COPYING"
fi

echo "==> rclone $RCLONE_VERSION"
download "$RCLONE_ARM64_URL" "$OUT/src/rclone-arm64.zip" "$RCLONE_ARM64_SHA256"
download "$RCLONE_AMD64_URL" "$OUT/src/rclone-amd64.zip" "$RCLONE_AMD64_SHA256"
if ! "$OUT/bin/rclone" version 2>/dev/null | head -1 | grep -q "v$RCLONE_VERSION"; then
  rm -rf "$OUT/work/rclone"; mkdir -p "$OUT/work/rclone"
  unzip -q "$OUT/src/rclone-arm64.zip" -d "$OUT/work/rclone/arm64"
  unzip -q "$OUT/src/rclone-amd64.zip" -d "$OUT/work/rclone/amd64"
  lipo -create "$OUT"/work/rclone/arm64/*/rclone "$OUT"/work/rclone/amd64/*/rclone -output "$OUT/bin/rclone"
fi
# Le texte de la licence MIT de rclone (README.txt de l'archive la contient ; COPYING est dans le dépôt rclone).
cp "$OUT"/work/rclone/arm64/*/README.txt "$OUT/licenses/rclone-README.txt" 2>/dev/null || true

for tool in rsync rclone; do
  lipo -verify_arch arm64 x86_64 "$OUT/bin/$tool" || { echo "$tool n'est pas universel" >&2; exit 1; }
done
echo "    $("$OUT/bin/rsync" --version | head -1)"
echo "    $("$OUT/bin/rclone" version | head -1)"
```

(Le texte MIT de rclone : vérifier ce que contient l'archive ; s'il n'y a pas de fichier de licence, `THIRD_PARTY_NOTICES.md` reproduit le texte MIT de rclone en entier.)

- [ ] **Étape 3 : `scripts/make-icon.swift`** — dessine (CoreGraphics) un carré arrondi en dégradé bleu avec deux flèches circulaires blanches (symbole de synchronisation), écrit les tailles 16…1024 dans `AppIcon.iconset`, puis le script appelant lance `iconutil -c icns`. Usage : `swift scripts/make-icon.swift DOSSIER.iconset`.

- [ ] **Étape 4 : `scripts/assemble-app.sh`** — reprend le contenu de `make-dev-bundle.sh` (Info.plist avec `VERSION`/`BUILD`, `CFBundleIconFile`, `NSHumanReadableCopyright`, `LSApplicationCategoryType = public.app-category.utilities` ; plist de l'agent ; ressources `.bundle` ; `Contents/Resources/bin` et `Contents/Resources/Licenses` si `VENDOR_DIR` ; `THIRD_PARTY_NOTICES.md` ; icône) et signe **de l'intérieur vers l'extérieur** : `bin/*`, les trois exécutables, puis l'app. `make-dev-bundle.sh` devient : `swift build -c release`, désenregistrer l'ancien agent, `assemble-app.sh "$BIN" "$APP" "$(cat VERSION)" "$(git rev-list --count HEAD)" [.build/vendor si présent]`.

- [ ] **Étape 5 : `scripts/make-release.sh`**

```bash
#!/bin/bash
# Construit build/SyncMacPro-<VERSION>.dmg : app universelle, rsync et rclone embarqués, signature ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT=build
APP="$OUT/stage/SyncMacPro.app"
DMG="$OUT/SyncMacPro-$VERSION.dmg"

scripts/fetch-vendor.sh .build/vendor
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
rm -rf "$OUT/stage" "$DMG"; mkdir -p "$OUT/stage"
scripts/assemble-app.sh "$BIN" "$APP" "$VERSION" "$BUILD_NUMBER" .build/vendor
for exe in "$APP"/Contents/MacOS/* "$APP"/Contents/Resources/bin/*; do
  lipo -verify_arch arm64 x86_64 "$exe" || { echo "$exe n'est pas universel" >&2; exit 1; }
done
codesign --verify --deep --strict "$APP"
ln -s /Applications "$OUT/stage/Applications"
cp scripts/dmg-readme.txt "$OUT/stage/Lisez-moi - Read me.txt"
hdiutil create -volname "SyncMacPro $VERSION" -srcfolder "$OUT/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/stage"
shasum -a 256 "$DMG"
echo "DMG prêt : $DMG"
```

`scripts/dmg-readme.txt` : installation (glisser dans Applications), premier lancement d'une app signée ad hoc (macOS 15+ : ouvrir, refuser, puis Réglages Système › Confidentialité et sécurité › « Ouvrir quand même » ; macOS 14 : clic droit › Ouvrir ; ou `xattr -dr com.apple.quarantine /Applications/SyncMacPro.app`), puis l'accueil installe l'agent ; en français puis en anglais.

`THIRD_PARTY_NOTICES.md` : rsync 3.5.1 — GPL v3 ou ultérieure, © Andrew Tridgell, Wayne Davison et autres, source : l'archive jointe à chaque publication et https://download.samba.org/pub/rsync/src/, options de compilation (celles de `fetch-vendor.sh`), non modifié ; rclone 1.75.1 — MIT, © Nick Craig-Wood, binaires officiels non modifiés, https://github.com/rclone/rclone ; texte MIT complet de rclone.

`.github/workflows/ci.yml` : étape `bash -n scripts/*.sh` avant les tests.

- [ ] **Étape 6 : vérifier** — `bash -n scripts/*.sh` ; `scripts/fetch-vendor.sh` (utilise le cache) ; `scripts/make-release.sh` → DMG ; `hdiutil attach -nobrowse -readonly` puis : `lipo -archs` des exécutables et des binaires, `codesign --verify --deep --strict`, `Contents/MacOS/syncmacpro-ctl doctor` (rsync et rclone **du bundle**, PATH réduit à `/usr/bin:/bin`), `hdiutil detach`.

- [ ] **Étape 7 : commit et push** — `git commit -m "Distribution : binaires vérifiés et universels, icône, assemblage commun, DMG"`.

---

### Tâche 5 : workflow de publication, documentation, essai réel

**Fichiers :** créer `.github/workflows/release.yml` ; modifier `README.md`, `docs/manual-checks-ui.md`.

- [ ] **Étape 1 : `.github/workflows/release.yml`**

```yaml
name: Publication

on:
  push:
    tags: ['v*']
  workflow_dispatch:

permissions:
  contents: write

jobs:
  dmg:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Cache des binaires embarqués
        uses: actions/cache@v4
        with:
          path: .build/vendor
          key: vendor-${{ hashFiles('scripts/vendor.lock', 'scripts/fetch-vendor.sh') }}
      - name: Construire le DMG
        run: scripts/make-release.sh
      - name: Garder le DMG
        uses: actions/upload-artifact@v4
        with:
          name: SyncMacPro-dmg
          path: build/*.dmg
      - name: Publier
        if: startsWith(github.ref, 'refs/tags/v')
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          VERSION="$(tr -d '[:space:]' < VERSION)"
          [ "v$VERSION" = "$GITHUB_REF_NAME" ] || { echo "VERSION ($VERSION) ≠ étiquette ($GITHUB_REF_NAME)"; exit 1; }
          gh release create "$GITHUB_REF_NAME" build/SyncMacPro-$VERSION.dmg .build/vendor/src/rsync-*.tar.gz \
            --title "SyncMacPro $VERSION" --notes-file docs/release-notes.md
```

`docs/release-notes.md` : texte de la première publication (fonctions, installation ad hoc, licences).

- [ ] **Étape 2 : documentation** — README : section « Installer » en tête (DMG depuis les publications GitHub, premier lancement ad hoc, Intel et Apple Silicon, macOS 14+), tableau « État » mis à jour (tous les sous-projets livrés), section « Publier une version » (VERSION, étiquette, workflow, cache), « Licences ». `docs/manual-checks-ui.md` : section « Distribution (5) » (DMG sur un Mac sans Homebrew, Gatekeeper, agent installé depuis Applications, mise à jour signalée, licences).

- [ ] **Étape 3 : essai réel** — DMG construit localement : montage, vérifications de la tâche 4 ; copie de l'app dans un dossier du bloc-notes ; `ctl doctor` (binaires du bundle) ; copie d'un dossier avec le rsync embarqué via `rsync -a` du bundle ; démontage ; suppression du DMG de `build/` après l'essai (le dossier `build/` est ignoré par git).

- [ ] **Étape 4 : commit et push** — `git commit -m "Publication sur étiquette (DMG + source de rsync), docs d'installation"`.
