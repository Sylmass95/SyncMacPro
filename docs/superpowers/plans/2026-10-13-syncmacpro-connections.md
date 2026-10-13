# SyncMacPro — sous-projet 4 (connexion aux services) : plan d'implémentation

> **Pour les agents :** SOUS-COMPÉTENCE REQUISE : superpowers:executing-plans (exécution native, en autonomie). Les étapes utilisent la syntaxe à cases (`- [ ]`).

**Objectif :** un assistant sans terminal crée, teste, reconnecte et supprime des connexions rclone (Google Drive, Dropbox, OneDrive, S3) ; l'éditeur de tâches les propose avec un sélecteur de dossier distant.

**Architecture :** SyncKit gagne les types et commandes de configuration rclone, et `RcloneConfigurator` qui dialogue avec rclone par son protocole non interactif (`--non-interactive`, questions JSON). L'agent l'expose par XPC (contrat v4) et garde la main sur l'écriture (toujours par rclone). L'app ajoute un catalogue de services, un modèle d'assistant testable, l'écran Connexions et le sélecteur de dossier distant.

**Stack :** Swift 5.9 (mode 5), SwiftUI, Observation, XCTest ; rclone 1.75 (installé en CI par Homebrew).

**Spec :** `docs/superpowers/specs/2026-10-13-syncmacpro-connections-design.md`

## Contraintes globales

- macOS 14, swift-tools 5.9, mode Swift 5, aucune dépendance externe.
- CI Swift 5.10 / SDK macOS 14 : toute vue `@MainActor` ; pas de `var` ni de `weak self` capturés dans une closure `@Sendable` / `Task` imbriquée ; expressions de test longues découpées. PR brouillon #7 poussée après **chaque** tâche.
- Contrat XPC : `agentProtocolVersion = 4`.
- **Jamais** d'écriture directe de `rclone.conf`, jamais de lecture de son contenu (secrets) ; les tests utilisent un fichier temporaire (`--config`).
- Textes : `Localizer`, fr et en ; préfixes nouveaux `connections`, `wizard`, `service`, `remote` ajoutés au test de complétude.
- Suite verte : `SYNCMACPRO_RSYNC="$HOME/Applications/Rsync GUI.app/Contents/Resources/bin/rsync" swift test`.
- Commits terminés par `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Décisions prises en rédigeant le plan

- **Ruling : réponses automatiques par nom d'option rclone** : `config_shared_client_id = true` (l'assistant a déjà prévenu), `config_is_local = true` (l'utilisateur a cliqué « Se connecter » ; l'attente du navigateur commence), `config_change_team_drive = false`, `config_drive_ok = true`. Toute autre question est montrée.
- **Ruling : rollback** : si une création échoue ou est annulée, l'agent supprime la connexion à moitié créée (rclone l'écrit dès la première question).
- **Ruling : test échoué** : l'assistant propose « Corriger » (la connexion est supprimée, retour à la préparation) ou « Garder quand même ».
- **Ruling : ordre de la barre latérale** : tableau de bord, tâches, copie, historique, connexions, réglages.
- **Ruling : `ctl remotes`, `ctl remote test|delete NOM`** pour l'essai réel et les scripts ; pas d'assistant en ligne de commande (rclone config existe déjà).

## Points de revue

1. Navigateur fermé ou refus d'accès : rclone attend jusqu'au délai ; Annuler doit arrêter rclone et ne rien laisser dans la configuration. → tâches 2, 3, 6.
2. Nom déjà pris, ou invalide pour rclone : refus clair avant tout appel à rclone. → tâches 1, 3, 6.
3. Connexion utilisée par une tâche : suppression refusée avec le nom des tâches. → tâche 3.
4. Arrêt de l'agent pendant une attente de navigateur : rclone arrêté, connexion à moitié créée supprimée. → tâche 3.
5. Sortie de rclone inattendue (champ absent, texte non JSON) : erreur lisible, pas de plantage. → tâche 1.

---

### Tâche 1 : types, commandes et lecture des réponses de rclone (SyncKit)

**Fichiers :** créer `Sources/SyncKit/Remotes.swift`, `Sources/SyncKit/RcloneConfigCommand.swift`, `Tests/SyncKitTests/RemotesTests.swift` ; fixtures déjà capturées dans `Tests/SyncKitTests/Fixtures/` : `rclone_config_bool.json` (OneDrive, `config_is_local`), `rclone_config_string.json` (`config_token`), `rclone_config_choice.json` (S3 `--all`, `provider`, 53 exemples), `rclone_config_drive_shared.json` (`client_id_warning`), `rclone_config_done.json`, `rclone_listremotes.json`.

**Interfaces (produit) :**
- `struct RemoteInfo: Codable, Equatable, Sendable, Identifiable` (`name`, `type`, `id = name`) ;
- `struct RemoteChoice: Codable, Equatable, Sendable` (`value`, `help`) ;
- `struct RemoteQuestion: Codable, Equatable, Sendable` (`state`, `option`, `help`, `kind`, `defaultValue`, `choices`, `exclusive`, `required`, `isPassword`) ;
- `enum RemoteConfigStep: Codable, Equatable, Sendable` : `start(name:type:parameters:)`, `answer(name:state:result:)`, `reconnect(name:)` ; `var name: String` ;
- `enum RemoteConfigOutcome: Codable, Equatable, Sendable` : `question(RemoteQuestion)`, `done` ;
- `struct RemoteTestResult: Codable, Equatable, Sendable` (`ok`, `message: String?`) ;
- `enum RemoteConfigError: Error, Equatable, LocalizedError` : `rclone(String)`, `unreadable`, `timedOut`, `cancelled` ;
- `enum RcloneConfigReply { static func outcome(from: Data) throws -> RemoteConfigOutcome; static func remotes(from: Data) throws -> [RemoteInfo]; static func folders(from: Data) throws -> [String] }` ;
- `enum RcloneConfigCommand` : `listRemotes(config:)`, `arguments(for: RemoteConfigStep, config:)`, `delete(_:config:)`, `test(_:config:)`, `folders(remote:path:config:)` → `[String]` ;
- `enum RemoteNameProblem: Equatable { empty, invalidCharacters, badStart, badEnd, taken }` ; `enum RemoteNameRule { static func problem(_:existing:) -> RemoteNameProblem?; static func suggestion(_:existing:) -> String }` ;
- `extension SyncTask { var remoteNames: Set<String> }`.

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncKitTests/RemotesTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class RemotesTests: XCTestCase {
    func data(_ name: String) throws -> Data { Data(try Fixture.text(name, ext: "json").utf8) }

    func testBooleanQuestion() throws {
        guard case .question(let q) = try RcloneConfigReply.outcome(from: data("rclone_config_bool")) else { return XCTFail() }
        XCTAssertEqual(q.state, "*oauth-islocal,choose_type,,")
        XCTAssertEqual(q.option, "config_is_local")
        XCTAssertEqual(q.kind, "bool")
        XCTAssertEqual(q.defaultValue, "true")
        XCTAssertEqual(q.choices.map(\.value), ["true", "false"])
        XCTAssertTrue(q.exclusive)
        XCTAssertFalse(q.isPassword)
    }

    func testTextQuestion() throws {
        guard case .question(let q) = try RcloneConfigReply.outcome(from: data("rclone_config_string")) else { return XCTFail() }
        XCTAssertEqual(q.option, "config_token")
        XCTAssertTrue(q.required)
        XCTAssertTrue(q.choices.isEmpty)
    }

    func testChoiceQuestion() throws {
        guard case .question(let q) = try RcloneConfigReply.outcome(from: data("rclone_config_choice")) else { return XCTFail() }
        XCTAssertEqual(q.option, "provider")
        XCTAssertGreaterThan(q.choices.count, 10)
        XCTAssertTrue(q.choices.contains { $0.value == "AWS" })
        XCTAssertFalse(q.exclusive)
    }

    func testDriveSharedClientWarning() throws {
        guard case .question(let q) = try RcloneConfigReply.outcome(from: data("rclone_config_drive_shared")) else { return XCTFail() }
        XCTAssertEqual(q.option, "client_id_warning")
        XCTAssertTrue(q.help.contains("2026"))
    }

    func testDone() throws {
        XCTAssertEqual(try RcloneConfigReply.outcome(from: data("rclone_config_done")), .done)
    }

    func testRcloneErrorAndGarbage() {
        let error = Data(#"{"State":"","Option":null,"Error":"valeur refusée","Result":""}"#.utf8)
        XCTAssertThrowsError(try RcloneConfigReply.outcome(from: error)) {
            XCTAssertEqual($0 as? RemoteConfigError, .rclone("valeur refusée"))
        }
        XCTAssertThrowsError(try RcloneConfigReply.outcome(from: Data("NOTICE: rien\n".utf8))) {
            XCTAssertEqual($0 as? RemoteConfigError, .unreadable)
        }
        let partial = Data(#"{"State":"x","Option":{"Name":"n"}}"#.utf8)
        guard case .question(let q) = try? RcloneConfigReply.outcome(from: partial) else { return XCTFail("lecture tolérante") }
        XCTAssertEqual(q.option, "n")
        XCTAssertEqual(q.kind, "string")
    }

    func testRemotesAndFolders() throws {
        let remotes = try RcloneConfigReply.remotes(from: data("rclone_listremotes"))
        XCTAssertEqual(remotes, [RemoteInfo(name: "od", type: "onedrive"), RemoteInfo(name: "s", type: "s3"), RemoteInfo(name: "a", type: "alias")])
        let listing = Data(#"[{"Path":"b","Name":"b","IsDir":true},{"Path":"A","Name":"A","IsDir":true},{"Name":"f.txt","IsDir":false}]"#.utf8)
        XCTAssertEqual(try RcloneConfigReply.folders(from: listing), ["A", "b"])
    }

    func testCommands() {
        let config = "/tmp/r.conf"
        XCTAssertEqual(RcloneConfigCommand.listRemotes(config: config), ["listremotes", "--long", "--json", "--config", config])
        XCTAssertEqual(
            RcloneConfigCommand.arguments(for: .start(name: "Drive", type: "drive", parameters: ["scope": "drive", "client_id": "x"]), config: nil),
            ["config", "create", "Drive", "drive", "client_id=x", "scope=drive", "--non-interactive"]
        )
        XCTAssertEqual(
            RcloneConfigCommand.arguments(for: .answer(name: "Drive", state: "*oauth", result: "true"), config: config),
            ["config", "update", "Drive", "--continue", "--state", "*oauth", "--result", "true", "--non-interactive", "--config", config]
        )
        XCTAssertEqual(
            RcloneConfigCommand.arguments(for: .reconnect(name: "Drive"), config: nil),
            ["config", "update", "Drive", "config_refresh_token=true", "--non-interactive"]
        )
        XCTAssertEqual(RcloneConfigCommand.delete("Drive", config: nil), ["config", "delete", "Drive"])
        XCTAssertEqual(RcloneConfigCommand.test("Drive", config: nil), ["lsjson", "Drive:", "--dirs-only", "--max-depth", "1"])
        XCTAssertEqual(RcloneConfigCommand.folders(remote: "Drive", path: "/Photos/", config: nil),
                       ["lsjson", "Drive:Photos", "--dirs-only", "--max-depth", "1"])
    }

    func testNameRule() {
        let existing = ["Google Drive", "nas"]
        XCTAssertNil(RemoteNameRule.problem("Mon Drive", existing: existing))
        XCTAssertNil(RemoteNameRule.problem("s3_backup-1.eu@x+y", existing: existing))
        XCTAssertEqual(RemoteNameRule.problem("", existing: existing), .empty)
        XCTAssertEqual(RemoteNameRule.problem("a:b", existing: existing), .invalidCharacters)
        XCTAssertEqual(RemoteNameRule.problem("a/b", existing: existing), .invalidCharacters)
        XCTAssertEqual(RemoteNameRule.problem("-a", existing: existing), .badStart)
        XCTAssertEqual(RemoteNameRule.problem(" a", existing: existing), .badStart)
        XCTAssertEqual(RemoteNameRule.problem("a ", existing: existing), .badEnd)
        XCTAssertEqual(RemoteNameRule.problem("NAS", existing: existing), .taken, "rclone distingue la casse, mais deux noms identiques à la casse près prêtent à confusion")
        XCTAssertEqual(RemoteNameRule.suggestion("Google Drive", existing: existing), "Google Drive 2")
        XCTAssertEqual(RemoteNameRule.suggestion("Dropbox", existing: existing), "Dropbox")
    }

    func testRemoteNamesOfATask() {
        let task = SyncTask(name: "t", source: .cloud(remote: "drive", path: "a"), destination: .cloud(remote: "s3", path: "b"))
        XCTAssertEqual(task.remoteNames, ["drive", "s3"])
        XCTAssertEqual(SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b")).remoteNames, [])
    }
}
```

`swift test --filter RemotesTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`Sources/SyncKit/Remotes.swift` :

```swift
import Foundation

/// Une connexion rclone (« remote ») : son nom et son type (`drive`, `s3`…).
public struct RemoteInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String
    public var id: String { name }

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

public struct RemoteChoice: Codable, Equatable, Sendable {
    public var value: String
    public var help: String

    public init(value: String, help: String) {
        self.value = value
        self.help = help
    }
}

/// Une question de rclone pendant la configuration (protocole non interactif).
public struct RemoteQuestion: Codable, Equatable, Sendable {
    /// À renvoyer tel quel avec la réponse.
    public var state: String
    /// Nom de l'option (`config_is_local`, `provider`…).
    public var option: String
    public var help: String
    /// `bool`, `string`, `int`…
    public var kind: String
    public var defaultValue: String
    public var choices: [RemoteChoice]
    /// Vrai : la réponse doit être l'un des choix.
    public var exclusive: Bool
    public var required: Bool
    public var isPassword: Bool

    public init(
        state: String, option: String, help: String = "", kind: String = "string", defaultValue: String = "",
        choices: [RemoteChoice] = [], exclusive: Bool = false, required: Bool = false, isPassword: Bool = false
    ) {
        self.state = state
        self.option = option
        self.help = help
        self.kind = kind
        self.defaultValue = defaultValue
        self.choices = choices
        self.exclusive = exclusive
        self.required = required
        self.isPassword = isPassword
    }
}

public enum RemoteConfigStep: Codable, Equatable, Sendable {
    /// Crée la connexion avec des paramètres connus d'avance.
    case start(name: String, type: String, parameters: [String: String])
    /// Répond à la dernière question.
    case answer(name: String, state: String, result: String)
    /// Renouvelle le jeton (navigateur).
    case reconnect(name: String)

    public var name: String {
        switch self {
        case .start(let name, _, _), .answer(let name, _, _), .reconnect(let name): return name
        }
    }
}

public enum RemoteConfigOutcome: Codable, Equatable, Sendable {
    case question(RemoteQuestion)
    case done
}

public struct RemoteTestResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String?

    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }
}

public enum RemoteConfigError: Error, Equatable, LocalizedError {
    case rclone(String)
    case unreadable
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .rclone(let message): return message
        case .unreadable: return "Réponse de rclone illisible."
        case .timedOut: return "rclone n'a pas répondu à temps (connexion dans le navigateur non terminée ?)."
        case .cancelled: return "Configuration annulée."
        }
    }
}

/// Lecture des sorties JSON de rclone (tolérante : un champ absent prend une valeur neutre).
public enum RcloneConfigReply {
    private struct Reply: Decodable {
        var State: String?
        var Option: Option?
        var Error: String?
    }

    private struct Option: Decodable {
        var Name: String?
        var Help: String?
        var `Type`: String?
        var DefaultStr: String?
        var Examples: [Example]?
        var Exclusive: Bool?
        var Required: Bool?
        var IsPassword: Bool?
    }

    private struct Example: Decodable {
        var Value: String?
        var Help: String?
    }

    public static func outcome(from data: Data) throws -> RemoteConfigOutcome {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw RemoteConfigError.unreadable }
        if let error = reply.Error, !error.isEmpty { throw RemoteConfigError.rclone(error) }
        guard let option = reply.Option, let name = option.Name else { return .done }
        return .question(RemoteQuestion(
            state: reply.State ?? "", option: name, help: option.Help ?? "", kind: option.Type ?? "string",
            defaultValue: option.DefaultStr ?? "",
            choices: (option.Examples ?? []).compactMap { example in
                example.Value.map { RemoteChoice(value: $0, help: example.Help ?? "") }
            },
            exclusive: option.Exclusive ?? false, required: option.Required ?? false, isPassword: option.IsPassword ?? false
        ))
    }

    public static func remotes(from data: Data) throws -> [RemoteInfo] {
        struct Entry: Decodable { var name: String; var type: String? }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { throw RemoteConfigError.unreadable }
        return entries.map { RemoteInfo(name: $0.name, type: $0.type ?? "") }
    }

    public static func folders(from data: Data) throws -> [String] {
        struct Entry: Decodable { var Name: String; var IsDir: Bool? }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { throw RemoteConfigError.unreadable }
        return entries.filter { $0.IsDir ?? false }.map(\.Name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

public enum RemoteNameProblem: Equatable, Sendable {
    case empty, invalidCharacters, badStart, badEnd, taken
}

/// Règles de nom de rclone : lettres, chiffres, `_ - . + @` et espaces ; ni espace ni « - » au début, pas d'espace à la fin.
public enum RemoteNameRule {
    public static func problem(_ name: String, existing: [String]) -> RemoteNameProblem? {
        if name.isEmpty { return .empty }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.+@ "))
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) { return .invalidCharacters }
        if name.hasPrefix("-") || name.hasPrefix(" ") { return .badStart }
        if name.hasSuffix(" ") { return .badEnd }
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return .taken }
        return nil
    }

    public static func suggestion(_ base: String, existing: [String]) -> String {
        guard problem(base, existing: existing) == .taken else { return base }
        var index = 2
        while problem("\(base) \(index)", existing: existing) == .taken { index += 1 }
        return "\(base) \(index)"
    }
}

extension SyncTask {
    /// Connexions rclone utilisées par la tâche.
    public var remoteNames: Set<String> {
        var names = Set<String>()
        for endpoint in [source, destination] {
            if case .cloud(let remote, _) = endpoint { names.insert(remote) }
        }
        return names
    }
}
```

`Sources/SyncKit/RcloneConfigCommand.swift` :

```swift
import Foundation

/// Arguments des commandes de configuration de rclone. `config` : fichier à utiliser (`nil` : celui de rclone).
public enum RcloneConfigCommand {
    static func configArguments(_ config: String?) -> [String] { config.map { ["--config", $0] } ?? [] }

    public static func listRemotes(config: String?) -> [String] {
        ["listremotes", "--long", "--json"] + configArguments(config)
    }

    public static func arguments(for step: RemoteConfigStep, config: String?) -> [String] {
        let base: [String]
        switch step {
        case .start(let name, let type, let parameters):
            base = ["config", "create", name, type] + parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }
        case .answer(let name, let state, let result):
            base = ["config", "update", name, "--continue", "--state", state, "--result", result]
        case .reconnect(let name):
            base = ["config", "update", name, "config_refresh_token=true"]
        }
        return base + ["--non-interactive"] + configArguments(config)
    }

    public static func delete(_ name: String, config: String?) -> [String] {
        ["config", "delete", name] + configArguments(config)
    }

    public static func test(_ name: String, config: String?) -> [String] {
        folders(remote: name, path: "", config: config)
    }

    public static func folders(remote: String, path: String, config: String?) -> [String] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ["lsjson", "\(remote):\(trimmed)", "--dirs-only", "--max-depth", "1"] + configArguments(config)
    }
}
```

- [ ] **Étape 3 : vérifier** — `swift test --filter RemotesTests 2>&1 | grep -E "error:|Executed .* tests" | tail -3` → 9 tests passent.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources/SyncKit Tests/SyncKitTests
git commit -m "SyncKit : types, commandes et lecture des réponses de configuration rclone" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 2 : `RcloneConfigurator` (dialogue réel avec rclone)

**Fichiers :** créer `Sources/SyncKit/RcloneConfigurator.swift`, `Tests/SyncKitTests/RcloneConfiguratorTests.swift`.

**Interfaces :** consomme la tâche 1. Produit :

```swift
public protocol RemoteConfiguring: Sendable {
    func listRemotes() async throws -> [RemoteInfo]
    func configure(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome
    func cancelConfiguration(_ name: String)
    func cancelAll()
    func delete(_ name: String) async throws
    func test(_ name: String) async -> RemoteTestResult
    func folders(remote: String, path: String) async throws -> [String]
}
public final class RcloneConfigurator: RemoteConfiguring
// init(rclonePath: String, configPath: String?, configureTimeout: TimeInterval = 600, listTimeout: TimeInterval = 30)
```

- [ ] **Étape 1 : tests qui échouent** (vrai rclone, fichier de configuration temporaire)

`Tests/SyncKitTests/RcloneConfiguratorTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class RcloneConfiguratorTests: XCTestCase {
    var folder: URL!
    var config: String { folder.appendingPathComponent("rclone.conf").path }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data/Photos"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data/Docs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func configurator(timeout: TimeInterval = 600) throws -> RcloneConfigurator {
        guard let rclone = BinaryLocator.locate(.rclone) else { throw XCTSkip("rclone introuvable") }
        return RcloneConfigurator(rclonePath: rclone, configPath: config, configureTimeout: timeout)
    }

    func testCreateListTestAndDelete() async throws {
        let rclone = try configurator()
        let made = try await rclone.configure(.start(name: "local", type: "alias", parameters: ["remote": folder.appendingPathComponent("data").path]))
        XCTAssertEqual(made, .done)
        let remotes = try await rclone.listRemotes()
        XCTAssertEqual(remotes, [RemoteInfo(name: "local", type: "alias")])
        let test = await rclone.test("local")
        XCTAssertTrue(test.ok, test.message ?? "")
        let folders = try await rclone.folders(remote: "local", path: "")
        XCTAssertEqual(folders, ["Docs", "Photos"])
        try await rclone.delete("local")
        let after = try await rclone.listRemotes()
        XCTAssertTrue(after.isEmpty)
    }

    func testS3IsCreatedWithoutNetwork() async throws {
        let rclone = try configurator()
        let outcome = try await rclone.configure(.start(name: "s3", type: "s3", parameters: [
            "provider": "AWS", "env_auth": "false", "access_key_id": "AKIAFAKE", "secret_access_key": "secret", "region": "eu-west-3",
        ]))
        XCTAssertEqual(outcome, .done)
        let remotes = try await rclone.listRemotes()
        XCTAssertEqual(remotes.map(\.type), ["s3"])
    }

    func testQuestionsThenAnswer() async throws {
        let rclone = try configurator()
        guard case .question(let first) = try await rclone.configure(.start(name: "od", type: "onedrive", parameters: [:])) else {
            return XCTFail("OneDrive demande d'abord comment s'authentifier")
        }
        XCTAssertEqual(first.option, "config_is_local")
        // « false » : pas de navigateur, rclone demande alors un jeton collé (on ne va pas plus loin).
        guard case .question(let second) = try await rclone.configure(.answer(name: "od", state: first.state, result: "false")) else {
            return XCTFail()
        }
        XCTAssertEqual(second.option, "config_token")
    }

    func testUnreachableRemoteFailsTheTest() async throws {
        let rclone = try configurator()
        _ = try await rclone.configure(.start(name: "absent", type: "alias", parameters: ["remote": "/n-existe-pas-\(UUID().uuidString)"]))
        let test = await rclone.test("absent")
        XCTAssertFalse(test.ok)
        XCTAssertFalse((test.message ?? "").isEmpty)
        let unknown = await rclone.test("inconnue")
        XCTAssertFalse(unknown.ok)
    }

    func testTimeoutStopsRclone() async throws {
        // `config_is_local = true` lance l'attente du navigateur (sans l'ouvrir : --auth-no-open-browser est ajouté
        // par le test via le paramètre d'environnement) ; le délai très court l'interrompt.
        let rclone = try configurator(timeout: 1.5)
        guard case .question(let first) = try await rclone.configure(.start(name: "db", type: "dropbox", parameters: [:])) else {
            return XCTFail()
        }
        let started = Date()
        do {
            _ = try await rclone.configure(.answer(name: "db", state: first.state, result: "true"))
            XCTFail("doit expirer")
        } catch {
            XCTAssertEqual(error as? RemoteConfigError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testCancelStopsRclone() async throws {
        let rclone = try configurator()
        guard case .question(let first) = try await rclone.configure(.start(name: "db", type: "dropbox", parameters: [:])) else {
            return XCTFail()
        }
        let pending = Task { try await rclone.configure(.answer(name: "db", state: first.state, result: "true")) }
        try await Task.sleep(nanoseconds: 800_000_000)
        rclone.cancelConfiguration("db")
        do {
            _ = try await pending.value
            XCTFail("doit être annulée")
        } catch {
            XCTAssertEqual(error as? RemoteConfigError, .cancelled)
        }
    }
}
```

Le test d'attente du navigateur ne doit **jamais** ouvrir de navigateur : `RcloneConfigurator` accepte un paramètre `openBrowser: Bool = true` ; à `false`, il ajoute `--auth-no-open-browser`. Les deux tests d'attente construisent le configurateur avec `openBrowser: false` (adapter `configurator(timeout:)` : `RcloneConfigurator(rclonePath:configPath:configureTimeout:openBrowser: false)`).

`swift test --filter RcloneConfiguratorTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`Sources/SyncKit/RcloneConfigurator.swift` :

```swift
import Foundation

/// Ce que l'agent demande pour gérer les connexions ; un faux le remplace dans les tests de l'agent.
public protocol RemoteConfiguring: Sendable {
    func listRemotes() async throws -> [RemoteInfo]
    func configure(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome
    func cancelConfiguration(_ name: String)
    func cancelAll()
    func delete(_ name: String) async throws
    func test(_ name: String) async -> RemoteTestResult
    func folders(remote: String, path: String) async throws -> [String]
}

/// Dialogue avec rclone par son protocole non interactif. Toute écriture de la configuration passe par rclone.
public final class RcloneConfigurator: RemoteConfiguring, @unchecked Sendable {
    let rclonePath: String
    let configPath: String?
    let configureTimeout: TimeInterval
    let listTimeout: TimeInterval
    let openBrowser: Bool
    private let lock = NSLock()
    private var running: [String: RunningProcess] = [:]
    private var cancelled: Set<String> = []

    public init(
        rclonePath: String, configPath: String?, configureTimeout: TimeInterval = 600, listTimeout: TimeInterval = 30,
        openBrowser: Bool = true
    ) {
        self.rclonePath = rclonePath
        self.configPath = configPath
        self.configureTimeout = configureTimeout
        self.listTimeout = listTimeout
        self.openBrowser = openBrowser
    }

    struct Output {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    /// Lance rclone et attend sa fin ; `key` permet de l'annuler ; au-delà du délai, il est arrêté.
    func run(_ arguments: [String], timeout: TimeInterval, key: String? = nil) async throws -> Output {
        let collected = Locked<(out: [String], err: [String])>(([], []))
        let process = try ProcessRunner.spawn(executable: rclonePath, arguments: arguments) { line in
            collected.set({
                var value = collected.get()
                if line.stream == .stdout { value.out.append(line.text) } else { value.err.append(line.text) }
                return value
            }())
        }
        if let key {
            lock.withLock {
                running[key] = process
                cancelled.remove(key)
            }
        }
        let timedOut = Locked(false)
        let timer = DispatchWorkItem {
            timedOut.set(true)
            process.terminate(killAfter: 2)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let code = await process.waitForExit()
        timer.cancel()
        var wasCancelled = false
        if let key {
            lock.withLock {
                running[key] = nil
                wasCancelled = cancelled.remove(key) != nil
            }
        }
        if wasCancelled { throw RemoteConfigError.cancelled }
        if timedOut.get() { throw RemoteConfigError.timedOut }
        let value = collected.get()
        return Output(code: code, stdout: value.out.joined(separator: "\n"), stderr: value.err.joined(separator: "\n"))
    }

    /// Dernière ligne utile de rclone (sans l'horodatage ni le niveau).
    static func message(_ stderr: String) -> String {
        let line = stderr.split(separator: "\n").last.map(String.init) ?? ""
        for marker in ["CRITICAL: ", "ERROR : ", "ERROR: ", "Failed to "] {
            if let range = line.range(of: marker) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return line.isEmpty ? "rclone a échoué." : line
    }

    public func listRemotes() async throws -> [RemoteInfo] {
        let output = try await run(RcloneConfigCommand.listRemotes(config: configPath), timeout: listTimeout)
        guard output.code == 0 else { throw RemoteConfigError.rclone(Self.message(output.stderr)) }
        return try RcloneConfigReply.remotes(from: Data(output.stdout.utf8))
    }

    public func configure(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome {
        var arguments = RcloneConfigCommand.arguments(for: step, config: configPath)
        if !openBrowser { arguments.append("--auth-no-open-browser") }
        let output = try await run(arguments, timeout: configureTimeout, key: step.name)
        guard output.code == 0 else { throw RemoteConfigError.rclone(Self.message(output.stderr)) }
        return try RcloneConfigReply.outcome(from: Data(output.stdout.utf8))
    }

    public func cancelConfiguration(_ name: String) {
        let process: RunningProcess? = lock.withLock {
            guard let process = running[name] else { return nil }
            cancelled.insert(name)
            return process
        }
        process?.terminate(killAfter: 2)
    }

    public func cancelAll() {
        let names = lock.withLock { Array(running.keys) }
        names.forEach(cancelConfiguration)
    }

    public func delete(_ name: String) async throws {
        let output = try await run(RcloneConfigCommand.delete(name, config: configPath), timeout: listTimeout)
        guard output.code == 0 else { throw RemoteConfigError.rclone(Self.message(output.stderr)) }
    }

    public func test(_ name: String) async -> RemoteTestResult {
        do {
            let output = try await run(RcloneConfigCommand.test(name, config: configPath), timeout: listTimeout)
            return output.code == 0 ? RemoteTestResult(ok: true) : RemoteTestResult(ok: false, message: Self.message(output.stderr))
        } catch {
            return RemoteTestResult(ok: false, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public func folders(remote: String, path: String) async throws -> [String] {
        let output = try await run(RcloneConfigCommand.folders(remote: remote, path: path, config: configPath), timeout: listTimeout)
        guard output.code == 0 else { throw RemoteConfigError.rclone(Self.message(output.stderr)) }
        return try RcloneConfigReply.folders(from: Data(output.stdout.utf8))
    }
}
```

`Locked` vient des tests aujourd'hui : s'il n'existe pas dans SyncKit, ajouter dans `RcloneConfigurator.swift` un petit `final class Locked<Value>: @unchecked Sendable` (verrou + `get`/`set`) **interne** à SyncKit, et vérifier que le `Locked` des tests ne le masque pas (renommer celui de SyncKit `LockedValue` si conflit).

- [ ] **Étape 3 : vérifier** — `swift test --filter RcloneConfiguratorTests 2>&1 | grep -E "error:|Executed .* tests|XCTAssert" | tail -4` → 6 tests passent ; aucun navigateur ne s'ouvre.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources/SyncKit Tests/SyncKitTests
git commit -m "SyncKit : RcloneConfigurator, dialogue non interactif avec rclone (délai, annulation)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 3 : l'agent gère les connexions (contrat v4)

**Fichiers :** modifier `AgentProtocol.swift`, `AgentRouter.swift`, `AgentTypes.swift` (`AgentError`), `AgentCore.swift` (dépendance `remotes`), `AgentCore+Control.swift` (`shutdown`), `Sources/syncmacpro-agent/main.swift`, `scripts/dev-launchd.sh` ; créer `Sources/SyncKit/Agent/AgentCore+Remotes.swift`, `Tests/SyncKitTests/AgentRemotesTests.swift` ; faux `FakeRemotes` dans `Tests/SyncKitTests/AgentTestSupport.swift` ; `AgentHarness.makeCore(remotes:)`.

**Interfaces :**
- `AgentRequest` + `listRemotes`, `configureRemote(RemoteConfigStep)`, `cancelRemoteConfiguration(String)`, `deleteRemote(String)`, `testRemote(String)`, `listRemoteFolders(remote: String, path: String)` ;
- `AgentResponse` + `remotes([RemoteInfo])`, `remoteConfig(RemoteConfigOutcome)`, `remoteTest(RemoteTestResult)`, `folders([String])` ;
- `AgentError` + `remoteInUse([String])`, `invalidRemote(String)`, `remoteBusy`, `rcloneMissing` ;
- `AgentCore.init(…, remotes: RemoteConfiguring? = nil, …)` (avant `makeRunner`) ;
- `AgentCore` : `listRemotes()`, `configureRemote(_:)`, `cancelRemoteConfiguration(_:)`, `deleteRemote(_:)`, `testRemote(_:)`, `listRemoteFolders(remote:path:)`.

- [ ] **Étape 1 : tests qui échouent**

Dans `AgentTestSupport.swift` :

```swift
final class FakeRemotes: RemoteConfiguring, @unchecked Sendable {
    let remotes = Locked<[RemoteInfo]>([])
    let steps = Locked<[RemoteConfigStep]>([])
    let deleted = Locked<[String]>([])
    let cancelled = Locked<[String]>([])
    let outcomes = Locked<[Result<RemoteConfigOutcome, RemoteConfigError>]>([])
    let gate = Locked<TestGate?>(nil)

    func listRemotes() async throws -> [RemoteInfo] { remotes.get() }
    func configure(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome {
        steps.set(steps.get() + [step])
        if case .start(let name, let type, _) = step { remotes.set(remotes.get() + [RemoteInfo(name: name, type: type)]) }
        if let gate = gate.get() { await gate.wait() }
        var queue = outcomes.get()
        let next = queue.isEmpty ? .success(.done) : queue.removeFirst()
        outcomes.set(queue)
        return try next.get()
    }
    func cancelConfiguration(_ name: String) {
        cancelled.set(cancelled.get() + [name])
        gate.get()?.open()
    }
    func cancelAll() { cancelled.set(cancelled.get() + ["*"]); gate.get()?.open() }
    func delete(_ name: String) async throws {
        deleted.set(deleted.get() + [name])
        remotes.set(remotes.get().filter { $0.name != name })
    }
    func test(_ name: String) async -> RemoteTestResult { RemoteTestResult(ok: remotes.get().contains { $0.name == name }) }
    func folders(remote: String, path: String) async throws -> [String] { ["A", "B"] }
}
```

(`TestGate` : réutiliser celui des tests de l'app s'il existe dans SyncKitTests ; sinon l'ajouter : `actor`-free `final class TestGate` avec `wait()` async et `open()`, à base de `CheckedContinuation` protégée par un verrou.)

`AgentHarness.makeCore` gagne `remotes: RemoteConfiguring? = nil` transmis à `AgentCore`.

`Tests/SyncKitTests/AgentRemotesTests.swift` :

```swift
import XCTest
@testable import SyncKit

final class AgentRemotesTests: XCTestCase {
    func testCreateValidatesTheNameFirst() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.remotes.set([RemoteInfo(name: "Drive", type: "drive")])
        let core = h.makeCore(remotes: remotes)
        do {
            _ = try await core.configureRemote(.start(name: "drive", type: "drive", parameters: [:]))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AgentError, .invalidRemote("Ce nom est déjà utilisé par une autre connexion."))
        }
        do {
            _ = try await core.configureRemote(.start(name: "a:b", type: "s3", parameters: [:]))
            XCTFail()
        } catch {
            guard case .invalidRemote = error as? AgentError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(remotes.steps.get().isEmpty, "rien n'est demandé à rclone")
    }

    func testFailedCreationIsRolledBack() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.outcomes.set([.success(.question(RemoteQuestion(state: "s", option: "config_is_local"))), .failure(.rclone("refus"))])
        let core = h.makeCore(remotes: remotes)
        let first = try await core.configureRemote(.start(name: "Dropbox", type: "dropbox", parameters: [:]))
        guard case .question = first else { return XCTFail() }
        do {
            _ = try await core.configureRemote(.answer(name: "Dropbox", state: "s", result: "true"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AgentError, .invalidRemote("refus"))
        }
        XCTAssertEqual(remotes.deleted.get(), ["Dropbox"], "une création ratée ne laisse rien")
    }

    func testCancelDeletesAHalfMadeRemote() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.outcomes.set([.success(.question(RemoteQuestion(state: "s", option: "config_is_local")))])
        let core = h.makeCore(remotes: remotes)
        _ = try await core.configureRemote(.start(name: "Dropbox", type: "dropbox", parameters: [:]))
        await core.cancelRemoteConfiguration("Dropbox")
        XCTAssertEqual(remotes.cancelled.get(), ["Dropbox"])
        XCTAssertEqual(remotes.deleted.get(), ["Dropbox"])
        // Une reconnexion annulée ne supprime pas la connexion existante.
        remotes.outcomes.set([.success(.question(RemoteQuestion(state: "s", option: "config_is_local")))])
        _ = try await core.configureRemote(.reconnect(name: "Existante"))
        await core.cancelRemoteConfiguration("Existante")
        XCTAssertEqual(remotes.deleted.get(), ["Dropbox"])
    }

    func testOneConfigurationAtATimePerName() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        let gate = TestGate()
        remotes.gate.set(gate)
        let core = h.makeCore(remotes: remotes)
        let pending = Task { try await core.configureRemote(.start(name: "S3", type: "s3", parameters: [:])) }
        _ = await eventually { remotes.steps.get().count == 1 }
        do {
            _ = try await core.configureRemote(.answer(name: "S3", state: "x", result: "y"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AgentError, .remoteBusy)
        }
        gate.open()
        _ = try await pending.value
    }

    func testDeleteIsRefusedWhileATaskUsesTheRemote() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.remotes.set([RemoteInfo(name: "Drive", type: "drive")])
        try h.save([SyncTask(name: "Photos vers Drive", source: .local(path: "/a"), destination: .cloud(remote: "Drive", path: "x"))])
        let core = h.makeCore(remotes: remotes)
        await core.start()
        do {
            try await core.deleteRemote("Drive")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AgentError, .remoteInUse(["Photos vers Drive"]))
        }
        XCTAssertTrue(remotes.deleted.get().isEmpty)
    }

    func testShutdownStopsConfigurations() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        let core = h.makeCore(remotes: remotes)
        await core.start()
        await core.shutdown()
        XCTAssertEqual(remotes.cancelled.get(), ["*"])
    }

    func testWithoutRclone() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        do { _ = try await core.listRemotes(); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .rcloneMissing) }
    }

    func testRouterSpeaksVersion4() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.remotes.set([RemoteInfo(name: "Drive", type: "drive")])
        let core = h.makeCore(remotes: remotes)
        let request = try JSONEncoder().encode(AgentRequestEnvelope(request: .listRemotes))
        let data = await AgentRouter.handle(request, core: core)
        let reply = try JSONDecoder().decode(AgentResponseEnvelope.self, from: data)
        XCTAssertEqual(reply.version, 4)
        XCTAssertEqual(reply.response, .remotes([RemoteInfo(name: "Drive", type: "drive")]))
    }

    func testRealRcloneThroughTheAgent() async throws {
        guard let rclone = BinaryLocator.locate(.rclone) else { throw XCTSkip("rclone introuvable") }
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let config = h.directory.appendingPathComponent("rclone.conf").path
        let core = h.makeCore(remotes: RcloneConfigurator(rclonePath: rclone, configPath: config))
        let outcome = try await core.configureRemote(.start(name: "Local", type: "alias", parameters: ["remote": h.directory.path]))
        XCTAssertEqual(outcome, .done)
        let listed = try await core.listRemotes()
        XCTAssertEqual(listed.map(\.name), ["Local"])
        let test = try await core.testRemote("Local")
        XCTAssertTrue(test.ok)
        try await core.deleteRemote("Local")
        let after = try await core.listRemotes()
        XCTAssertTrue(after.isEmpty)
    }
}
```

Ajouter les nouvelles requêtes à `AgentProtocolTests.testEveryRequestSurvivesEncoding` : `.listRemotes, .configureRemote(.start(name: "a", type: "s3", parameters: ["k": "v"])), .cancelRemoteConfiguration("a"), .deleteRemote("a"), .testRemote("a"), .listRemoteFolders(remote: "a", path: "x")`.

`swift test --filter "AgentRemotesTests|AgentProtocolTests" 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`AgentProtocol.swift` : version 4 ; les requêtes et réponses de l'Interface. `AgentTypes.swift`, `AgentError` : les quatre cas, avec

```swift
        case .remoteInUse(let tasks):
            return "Cette connexion est utilisée par : \(tasks.joined(separator: ", ")). Modifiez ou supprimez ces tâches d'abord."
        case .invalidRemote(let reason): return reason
        case .remoteBusy: return "Cette connexion est déjà en cours de configuration."
        case .rcloneMissing: return "rclone est introuvable : installez-le avec « brew install rclone »."
```

`AgentCore.swift` : propriétés `let remotes: RemoteConfiguring?`, `var configuringRemotes: Set<String> = []`, `var creatingRemotes: Set<String> = []` ; paramètre d'init `remotes: RemoteConfiguring? = nil` placé avant `makeRunner`.

`AgentCore+Control.swift`, `shutdown()` : `remotes?.cancelAll()` après l'arrêt des simulations.

`Sources/SyncKit/Agent/AgentCore+Remotes.swift` :

```swift
import Foundation

extension AgentCore {
    func configurator() throws -> RemoteConfiguring {
        guard let remotes else { throw AgentError.rcloneMissing }
        return remotes
    }

    static func agentError(_ error: Error) -> Error {
        if error is AgentError { return error }
        if let config = error as? RemoteConfigError { return AgentError.invalidRemote(config.errorDescription ?? "\(config)") }
        return AgentError.invalidRemote((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

    public func listRemotes() async throws -> [RemoteInfo] {
        do { return try await configurator().listRemotes() } catch { throw Self.agentError(error) }
    }

    /// Une étape de configuration. Une création ratée ou annulée ne laisse rien dans la configuration de rclone.
    public func configureRemote(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome {
        let rclone = try configurator()
        let name = step.name
        guard !configuringRemotes.contains(name) else { throw AgentError.remoteBusy }
        if case .start = step {
            let existing = try await listRemotes().map(\.name)
            if let problem = RemoteNameRule.problem(name, existing: existing) {
                throw AgentError.invalidRemote(Self.message(problem))
            }
            creatingRemotes.insert(name)
        }
        configuringRemotes.insert(name)
        defer { configuringRemotes.remove(name) }
        do {
            let outcome = try await rclone.configure(step)
            if outcome == .done { creatingRemotes.remove(name) }
            return outcome
        } catch {
            if creatingRemotes.remove(name) != nil { try? await rclone.delete(name) }
            throw Self.agentError(error)
        }
    }

    public func cancelRemoteConfiguration(_ name: String) async {
        remotes?.cancelConfiguration(name)
        if creatingRemotes.remove(name) != nil { try? await remotes?.delete(name) }
    }

    public func deleteRemote(_ name: String) async throws {
        let rclone = try configurator()
        let users = tasks.filter { $0.remoteNames.contains(name) }.map(\.name).sorted()
        guard users.isEmpty else { throw AgentError.remoteInUse(users) }
        do { try await rclone.delete(name) } catch { throw Self.agentError(error) }
    }

    public func testRemote(_ name: String) async throws -> RemoteTestResult {
        await try configurator().test(name)
    }

    public func listRemoteFolders(remote: String, path: String) async throws -> [String] {
        do { return try await configurator().folders(remote: remote, path: path) } catch { throw Self.agentError(error) }
    }

    static func message(_ problem: RemoteNameProblem) -> String {
        switch problem {
        case .empty: return "Donnez un nom à la connexion."
        case .invalidCharacters: return "Le nom ne peut contenir que des lettres, des chiffres, des espaces et _ - . + @."
        case .badStart: return "Le nom ne peut pas commencer par une espace ni par « - »."
        case .badEnd: return "Le nom ne peut pas finir par une espace."
        case .taken: return "Ce nom est déjà utilisé par une autre connexion."
        }
    }
}
```

(`await try` n'existe pas : écrire `try await configurator().test(name)` — `test` n'est pas `throws`, seul `configurator()` l'est ; garder `try` devant l'expression.)

Note : dans `cancelRemoteConfiguration`, une étape en cours reçoit `RemoteConfigError.cancelled`, son `catch` supprime alors elle-même la connexion (création) ; l'appel à `delete` en double est sans effet (rclone ne connaît plus le nom). Garder `try?`.

`AgentRouter.swift` :

```swift
            case .listRemotes: return .remotes(try await core.listRemotes())
            case .configureRemote(let step): return .remoteConfig(try await core.configureRemote(step))
            case .cancelRemoteConfiguration(let name): await core.cancelRemoteConfiguration(name)
            case .deleteRemote(let name): try await core.deleteRemote(name)
            case .testRemote(let name): return .remoteTest(try await core.testRemote(name))
            case .listRemoteFolders(let remote, let path): return .folders(try await core.listRemoteFolders(remote: remote, path: path))
```

`syncmacpro-agent/main.swift` : `let rcloneConfig = option("--rclone-config")` ; `RunnerConfiguration(…, rcloneConfigPath: rcloneConfig, …)` ; `remotes: BinaryLocator.locate(.rclone).map { RcloneConfigurator(rclonePath: $0, configPath: rcloneConfig) }` passé à `AgentCore`. En-tête d'usage : `[--rclone-config FICHIER]`.

`scripts/dev-launchd.sh install` : si `SYNCMACPRO_DEV_RCLONE_CONFIG` est défini, ajouter `<string>--rclone-config</string><string>$SYNCMACPRO_DEV_RCLONE_CONFIG</string>` aux arguments.

- [ ] **Étape 3 : vérifier** — `swift test --filter "AgentRemotesTests|AgentProtocolTests" 2>&1 | grep -E "error:|Executed .* tests" | tail -3` → passent ; suite complète verte.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests scripts
git commit -m "Agent : connexions rclone par XPC (liste, configuration, annulation, test, dossiers, suppression protégée ; contrat v4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 4 : `ctl remotes` et `ctl remote test|delete`

**Fichiers :** modifier `CtlParser.swift`, `Sources/syncmacpro-ctl/main.swift`, `AgentXPC.swift` (méthodes client), `Tests/SyncKitTests/CtlTests.swift`.

**Interfaces :** `CtlCommand.remotes`, `.remoteTest(String)`, `.remoteDelete(String)` ; `AgentClient.listRemotes()`, `testRemote(_:)`, `configureRemote(_:)` (délai 600 s), `remoteFolders(remote:path:)`.

- [ ] **Étape 1 : test qui échoue**

```swift
    func testRemoteCommands() throws {
        XCTAssertEqual(try parse("remotes").command, .remotes)
        XCTAssertEqual(try parse("connexions").command, .remotes)
        XCTAssertEqual(try parse("remote", "test", "Drive").command, .remoteTest("Drive"))
        XCTAssertEqual(try parse("remote", "delete", "Mon Drive").command, .remoteDelete("Mon Drive"))
        XCTAssertThrowsError(try parse("remote", "test"))
        XCTAssertThrowsError(try parse("remote", "rename", "x"))
    }
```

- [ ] **Étape 2 : implémenter**

`CtlParser` : cas `remotes`, `remoteTest(String)`, `remoteDelete(String)` ; alias `"connexions": "remotes"` ; dans `switch name` :

```swift
        case "remotes": return invocation(.remotes)
        case "remote":
            guard rest.count >= 2 else { throw CtlParseError.invalid("remote attend : test NOM ou delete NOM") }
            let target = rest.dropFirst().joined(separator: " ")
            switch rest[0] {
            case "test": return invocation(.remoteTest(target))
            case "delete": return invocation(.remoteDelete(target))
            default: throw CtlParseError.invalid("remote attend : test NOM ou delete NOM")
            }
```

`usage` : `remotes                        connexions rclone` et `remote test | delete <nom>`.

`AgentClient` :

```swift
    public func listRemotes() async throws -> [RemoteInfo] {
        guard case .remotes(let remotes) = try await send(.listRemotes) else { throw AgentClientError.badReply }
        return remotes
    }

    /// Une étape peut attendre la connexion dans le navigateur : 10 minutes et un peu plus.
    public func configureRemote(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome {
        guard case .remoteConfig(let outcome) = try await send(.configureRemote(step), timeout: 630) else {
            throw AgentClientError.badReply
        }
        return outcome
    }

    public func testRemote(_ name: String) async throws -> RemoteTestResult {
        guard case .remoteTest(let result) = try await send(.testRemote(name), timeout: 60) else { throw AgentClientError.badReply }
        return result
    }

    public func remoteFolders(remote: String, path: String) async throws -> [String] {
        guard case .folders(let folders) = try await send(.listRemoteFolders(remote: remote, path: path), timeout: 60) else {
            throw AgentClientError.badReply
        }
        return folders
    }
```

`syncmacpro-ctl/main.swift` :

```swift
    case .remotes:
        let remotes = try await client.listRemotes()
        show(remotes, lines: remotes.isEmpty ? ["Aucune connexion."] : remotes.map { "\($0.name)  (\($0.type))" })

    case .remoteTest(let name):
        let result = try await client.testRemote(name)
        print(result.ok ? "« \(name) » répond." : "« \(name) » ne répond pas : \(result.message ?? "")")
        if !result.ok { exit(1) }

    case .remoteDelete(let name):
        try await client.perform(.deleteRemote(name))
        print("Connexion « \(name) » supprimée.")
```

- [ ] **Étape 3 : vérifier** — `swift test --filter CtlParserTests` → passe ; `swift build` propre.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "ctl : remotes, remote test et remote delete" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 5 : l'app parle des connexions (`AgentConnecting`, `AgentModel`)

**Fichiers :** modifier `Sources/SyncMacProUI/Agent/AgentConnecting.swift`, `AgentModel.swift`, `Tests/SyncMacProUITests/FakeAgent.swift` ; créer `Tests/SyncMacProUITests/AgentModelRemotesTests.swift`.

**Interfaces :** consomme la tâche 4 (`AgentClient.listRemotes/configureRemote/testRemote/remoteFolders`). Produit :
- `AgentConnecting` + `listRemotes()`, `configureRemote(_:)`, `testRemote(_:)`, `remoteFolders(remote:path:)` (et `UnavailableAgent`) ;
- `enum RemoteStepResult: Equatable { question(RemoteQuestion), done, failed(String) }` ;
- `enum FolderListing: Equatable { loaded([String]), failed(String) }` ;
- `AgentModel` : `remotes: [RemoteInfo]`, `remotesError: String?`, `reloadRemotes()`, `configureRemote(_:) -> RemoteStepResult`, `cancelRemoteConfiguration(_:)`, `deleteRemote(_:) -> String?`, `testRemote(_:) -> RemoteTestResult`, `remoteFolders(remote:path:) -> FolderListing`, `tasks(usingRemote:) -> [SyncTask]`.

- [ ] **Étape 1 : tests qui échouent**

`FakeAgent` gagne : `setRemotes(_ result: Result<[RemoteInfo], Error>)`, `setConfigOutcomes(_ outcomes: [Result<RemoteConfigOutcome, Error>])`, `setRemoteTest(_ result: RemoteTestResult)`, `setFolders(_ result: Result<[String], Error>)`, `configured: [RemoteConfigStep]`, `folderRequests: [String]` (« remote:path »), `holdConfiguration: TestGate?` (attendu avant de répondre), et les quatre méthodes (`configureRemote` dépile `configOutcomes`, `.done` si vide).

`Tests/SyncMacProUITests/AgentModelRemotesTests.swift` :

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class AgentModelRemotesTests: XCTestCase {
    func testReloadAndUsage() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([RemoteInfo(name: "Drive", type: "drive")]))
        agent.setTasks([SyncTask(name: "Photos", source: .local(path: "/a"), destination: .cloud(remote: "Drive", path: "p"))])
        agent.setStatus(.success(makeStatus()))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.refreshNow()
        await model.reloadRemotes()
        XCTAssertEqual(model.remotes.map(\.name), ["Drive"])
        XCTAssertNil(model.remotesError)
        XCTAssertEqual(model.tasks(usingRemote: "Drive").map(\.name), ["Photos"])
        XCTAssertTrue(model.tasks(usingRemote: "Autre").isEmpty)
        agent.setRemotes(.failure(AgentClientError.agent(.rcloneMissing)))
        await model.reloadRemotes()
        XCTAssertEqual(model.remotesError, AgentError.rcloneMissing.errorDescription)
    }

    func testConfigureMapsOutcomes() async {
        let agent = FakeAgent()
        let question = RemoteQuestion(state: "s", option: "config_is_local")
        agent.setConfigOutcomes([.success(.question(question)), .success(.done), .failure(AgentClientError.agent(.invalidRemote("refus")))])
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let step = RemoteConfigStep.start(name: "D", type: "dropbox", parameters: [:])
        let first = await model.configureRemote(step)
        XCTAssertEqual(first, .question(question))
        let second = await model.configureRemote(step)
        XCTAssertEqual(second, .done)
        let third = await model.configureRemote(step)
        XCTAssertEqual(third, .failed("refus"))
        XCTAssertEqual(agent.configured.count, 3)
    }

    func testDeleteReloadsAndReportsRefusal() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([]))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let ok = await model.deleteRemote("Drive")
        XCTAssertNil(ok)
        XCTAssertEqual(agent.performed.last, .deleteRemote("Drive"))
        agent.setPerformError(AgentClientError.agent(.remoteInUse(["Photos"])))
        let refused = await model.deleteRemote("Drive")
        XCTAssertEqual(refused, AgentError.remoteInUse(["Photos"]).errorDescription)
    }

    func testTestAndFolders() async {
        let agent = FakeAgent()
        agent.setRemoteTest(RemoteTestResult(ok: false, message: "jeton expiré"))
        agent.setFolders(.success(["A", "B"]))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let test = await model.testRemote("Drive")
        XCTAssertEqual(test, RemoteTestResult(ok: false, message: "jeton expiré"))
        let folders = await model.remoteFolders(remote: "Drive", path: "Photos")
        XCTAssertEqual(folders, .loaded(["A", "B"]))
        XCTAssertEqual(agent.folderRequests, ["Drive:Photos"])
        agent.setFolders(.failure(AgentClientError.unreachable))
        let failed = await model.remoteFolders(remote: "Drive", path: "")
        guard case .failed = failed else { return XCTFail() }
    }

    func testCancelIsSent() async {
        let agent = FakeAgent()
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.cancelRemoteConfiguration("D")
        XCTAssertEqual(agent.performed.last, .cancelRemoteConfiguration("D"))
    }
}
```

`swift test --filter AgentModelRemotesTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`AgentConnecting.swift` : ajouter au protocole

```swift
    func listRemotes() async throws -> [RemoteInfo]
    func configureRemote(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome
    func testRemote(_ name: String) async throws -> RemoteTestResult
    func remoteFolders(remote: String, path: String) async throws -> [String]
```

(`AgentClient` les a depuis la tâche 4.) `UnavailableAgent` : les quatre lèvent `AgentClientError.unreachable`. Après `LogOutcome` :

```swift
public enum RemoteStepResult: Equatable, Sendable {
    case question(RemoteQuestion)
    case done
    case failed(String)
}

public enum FolderListing: Equatable, Sendable {
    case loaded([String])
    case failed(String)
}
```

`AgentModel.swift` : propriétés `public private(set) var remotes: [RemoteInfo] = []` et `public private(set) var remotesError: String?` ; puis

```swift
    // MARK: connexions

    public func reloadRemotes() async {
        do {
            remotes = try await agent.listRemotes()
            remotesError = nil
        } catch {
            remotesError = Self.describe(error)
        }
    }

    public func configureRemote(_ step: RemoteConfigStep) async -> RemoteStepResult {
        do {
            switch try await agent.configureRemote(step) {
            case .question(let question): return .question(question)
            case .done:
                await reloadRemotes()
                return .done
            }
        } catch {
            // Délai dépassé côté app : l'agent attend peut-être encore le navigateur.
            if case .unreachable? = error as? AgentClientError { try? await agent.perform(.cancelRemoteConfiguration(step.name)) }
            return .failed(Self.describe(error))
        }
    }

    public func cancelRemoteConfiguration(_ name: String) async {
        try? await agent.perform(.cancelRemoteConfiguration(name))
        await reloadRemotes()
    }

    /// `nil` si la connexion est supprimée, sinon la raison du refus.
    public func deleteRemote(_ name: String) async -> String? {
        do {
            try await agent.perform(.deleteRemote(name))
            await reloadRemotes()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    public func testRemote(_ name: String) async -> RemoteTestResult {
        do { return try await agent.testRemote(name) } catch { return RemoteTestResult(ok: false, message: Self.describe(error)) }
    }

    public func remoteFolders(remote: String, path: String) async -> FolderListing {
        do { return .loaded(try await agent.remoteFolders(remote: remote, path: path)) } catch { return .failed(Self.describe(error)) }
    }

    /// Les tâches qui passent par cette connexion (source ou destination).
    public func tasks(usingRemote name: String) -> [SyncTask] {
        tasks.values.filter { $0.remoteNames.contains(name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
```

`describe` doit traduire `AgentClientError.agent(e)` par `e.errorDescription` (vérifier ; c'est déjà le cas pour `invalidTask`).

- [ ] **Étape 3 : vérifier** — `swift test --filter AgentModelRemotesTests` → 5 tests passent ; suite complète verte.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "App : connexions dans AgentModel (liste, configuration, test, dossiers, suppression)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 6 : catalogue des services et modèle de l'assistant

**Fichiers :** créer `Sources/SyncMacProUI/Connections/ServiceCatalog.swift`, `Sources/SyncMacProUI/Connections/WizardModel.swift`, `Tests/SyncMacProUITests/WizardModelTests.swift` ; chaînes `service.*`.

**Interfaces :**
- `enum CloudService: String, CaseIterable { drive, dropbox, onedrive, s3 }` : `rcloneType`, `symbol`, `usesBrowser`, `nameKey` ; `static func forType(_:) -> CloudService?` ; `static func autoAnswer(option:) -> String?` ;
- `enum S3Provider: String, CaseIterable { aws = "AWS", cloudflare = "Cloudflare", wasabi = "Wasabi", minio = "Minio", other = "Other" }` : `needsEndpoint` ;
- `enum WizardStep: Equatable { service, prepare, name, connect, test, done }` ;
- `@MainActor @Observable final class WizardModel` (`init(model:localizer:)`, `init(reconnecting:model:localizer:)`) : champs de saisie, `step`, `question`, `answer`, `busy`, `waitingForBrowser`, `error`, `testResult`, `nameProblem`, `canContinue`, `parameters`, `choose(_:)`, `next()`, `back()`, `connect() async`, `submitAnswer() async`, `cancel() async`, `retest() async`, `fix() async`, `keepAnyway()`.

- [ ] **Étape 1 : tests qui échouent**

`Tests/SyncMacProUITests/WizardModelTests.swift` :

```swift
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class WizardModelTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func make(_ agent: FakeAgent, remotes: [RemoteInfo] = []) async -> WizardModel {
        agent.setRemotes(.success(remotes))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.reloadRemotes()
        return WizardModel(model: model, localizer: fr)
    }

    func q(_ option: String, state: String = "s") -> RemoteQuestion { RemoteQuestion(state: state, option: option) }

    func testCatalog() {
        XCTAssertEqual(CloudService.drive.rcloneType, "drive")
        XCTAssertEqual(CloudService.forType("onedrive"), .onedrive)
        XCTAssertNil(CloudService.forType("alias"))
        XCTAssertFalse(CloudService.s3.usesBrowser)
        XCTAssertEqual(CloudService.autoAnswer(option: "config_shared_client_id"), "true")
        XCTAssertEqual(CloudService.autoAnswer(option: "config_is_local"), "true")
        XCTAssertEqual(CloudService.autoAnswer(option: "config_change_team_drive"), "false")
        XCTAssertNil(CloudService.autoAnswer(option: "config_driveid"))
        XCTAssertFalse(S3Provider.aws.needsEndpoint)
        XCTAssertTrue(S3Provider.minio.needsEndpoint)
    }

    func testDriveFlowAnswersKnownQuestionsAlone() async {
        let agent = FakeAgent()
        let wizard = await make(agent, remotes: [RemoteInfo(name: "Google Drive", type: "drive")])
        wizard.choose(.drive)
        XCTAssertEqual(wizard.step, .prepare)
        XCTAssertEqual(wizard.name, "Google Drive 2", "nom proposé, libre")
        XCTAssertFalse(wizard.canContinue, "identifiant propre par défaut : ID et secret requis")
        wizard.clientID = "123.apps.googleusercontent.com"
        wizard.clientSecret = "secret"
        XCTAssertTrue(wizard.canContinue)
        wizard.next()
        XCTAssertEqual(wizard.step, .name)
        wizard.next()
        XCTAssertEqual(wizard.step, .connect)
        agent.setConfigOutcomes([
            .success(.question(q("config_is_local", state: "a"))),
            .success(.question(q("config_change_team_drive", state: "b"))),
            .success(.done),
        ])
        agent.setRemoteTest(RemoteTestResult(ok: true))
        await wizard.connect()
        XCTAssertEqual(agent.configured, [
            .start(name: "Google Drive 2", type: "drive", parameters: [
                "scope": "drive", "client_id": "123.apps.googleusercontent.com", "client_secret": "secret",
            ]),
            .answer(name: "Google Drive 2", state: "a", result: "true"),
            .answer(name: "Google Drive 2", state: "b", result: "false"),
        ])
        XCTAssertEqual(wizard.step, .done)
        XCTAssertEqual(wizard.testResult?.ok, true)
    }

    func testSharedDriveClientNeedsNothing() async {
        let wizard = await make(FakeAgent())
        wizard.choose(.drive)
        wizard.ownClient = false
        XCTAssertTrue(wizard.canContinue)
        XCTAssertEqual(wizard.parameters, ["scope": "drive"])
    }

    func testUnknownQuestionIsAskedThenAnswered() async {
        let agent = FakeAgent()
        let wizard = await make(agent)
        wizard.choose(.onedrive)
        wizard.next(); wizard.next()
        let drives = RemoteQuestion(state: "c", option: "config_driveid", defaultValue: "id1",
                                    choices: [RemoteChoice(value: "id1", help: "OneDrive (personal)")], exclusive: true)
        agent.setConfigOutcomes([.success(.question(q("config_is_local", state: "a"))), .success(.question(drives))])
        await wizard.connect()
        XCTAssertEqual(wizard.question, drives)
        XCTAssertEqual(wizard.answer, "id1", "la valeur par défaut est proposée")
        XCTAssertEqual(wizard.step, .connect)
        agent.setConfigOutcomes([.success(.done)])
        agent.setRemoteTest(RemoteTestResult(ok: true))
        await wizard.submitAnswer()
        XCTAssertEqual(agent.configured.last, .answer(name: wizard.name, state: "c", result: "id1"))
        XCTAssertEqual(wizard.step, .done)
    }

    func testS3Parameters() async {
        let wizard = await make(FakeAgent())
        wizard.choose(.s3)
        XCTAssertFalse(wizard.canContinue)
        wizard.accessKey = "AK"
        wizard.secretKey = "SK"
        wizard.region = "eu-west-3"
        XCTAssertTrue(wizard.canContinue)
        XCTAssertEqual(wizard.parameters, ["provider": "AWS", "env_auth": "false", "access_key_id": "AK",
                                           "secret_access_key": "SK", "region": "eu-west-3"])
        wizard.s3Provider = .minio
        XCTAssertFalse(wizard.canContinue, "adresse du service requise")
        wizard.endpoint = "https://minio.local:9000"
        XCTAssertEqual(wizard.parameters["endpoint"], "https://minio.local:9000")
        XCTAssertEqual(wizard.parameters["provider"], "Minio")
    }

    func testNameProblems() async {
        let wizard = await make(FakeAgent(), remotes: [RemoteInfo(name: "nas", type: "smb")])
        wizard.choose(.dropbox)
        wizard.next()
        wizard.name = "NAS"
        XCTAssertEqual(wizard.nameProblem, .taken)
        XCTAssertFalse(wizard.canContinue)
        wizard.name = "Mon Dropbox"
        XCTAssertTrue(wizard.canContinue)
    }

    func testFailureIsShownAndCanBeRetried() async {
        let agent = FakeAgent()
        let wizard = await make(agent)
        wizard.choose(.dropbox)
        wizard.next(); wizard.next()
        agent.setConfigOutcomes([.failure(AgentClientError.agent(.invalidRemote("Accès refusé.")))])
        await wizard.connect()
        XCTAssertEqual(wizard.error, "Accès refusé.")
        XCTAssertEqual(wizard.step, .connect)
        XCTAssertFalse(wizard.busy)
    }

    func testFailedTestOffersFixOrKeep() async {
        let agent = FakeAgent()
        let wizard = await make(agent)
        wizard.choose(.s3)
        wizard.accessKey = "AK"; wizard.secretKey = "faux"; wizard.region = "eu-west-3"
        wizard.next(); wizard.next()
        agent.setConfigOutcomes([.success(.done)])
        agent.setRemoteTest(RemoteTestResult(ok: false, message: "InvalidAccessKeyId"))
        await wizard.connect()
        XCTAssertEqual(wizard.step, .test)
        XCTAssertEqual(wizard.testResult?.message, "InvalidAccessKeyId")
        await wizard.fix()
        XCTAssertEqual(agent.performed.last, .deleteRemote(wizard.name))
        XCTAssertEqual(wizard.step, .prepare)
        agent.setConfigOutcomes([.success(.done)])
        wizard.next(); wizard.next()
        await wizard.connect()
        wizard.keepAnyway()
        XCTAssertEqual(wizard.step, .done)
    }

    func testCancelDuringTheBrowserWait() async {
        let agent = FakeAgent()
        let wizard = await make(agent)
        wizard.choose(.dropbox)
        wizard.next(); wizard.next()
        let gate = TestGate()
        agent.holdConfiguration = gate
        agent.setConfigOutcomes([.success(.question(q("config_is_local"))), .failure(AgentClientError.agent(.invalidRemote("Configuration annulée.")))])
        let pending = Task { await wizard.connect() }
        _ = await eventually { wizard.waitingForBrowser }
        await wizard.cancel()
        XCTAssertEqual(agent.performed.last, .cancelRemoteConfiguration(wizard.name))
        gate.open()
        await pending.value
        XCTAssertFalse(wizard.waitingForBrowser)
        XCTAssertNil(wizard.error, "une annulation voulue n'est pas une erreur")
    }

    func testReconnect() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([RemoteInfo(name: "Drive", type: "drive")]))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let wizard = WizardModel(reconnecting: RemoteInfo(name: "Drive", type: "drive"), model: model, localizer: fr)
        XCTAssertEqual(wizard.step, .connect)
        agent.setConfigOutcomes([.success(.question(q("config_is_local"))), .success(.done)])
        agent.setRemoteTest(RemoteTestResult(ok: true))
        await wizard.connect()
        XCTAssertEqual(agent.configured.first, .reconnect(name: "Drive"))
        XCTAssertEqual(wizard.step, .done)
    }
}
```

`eventually` (attente bornée d'une condition) existe-t-il dans les tests de l'app ? Sinon, l'ajouter dans `UITestSupport.swift` : `@MainActor func eventually(_ condition: () -> Bool) async -> Bool` (jusqu'à 2 s, pas de 10 ms via `Task.sleep`).

`FakeAgent.holdConfiguration` : si défini, `configureRemote` attend `gate.wait()` **après** avoir rendu la première réponse — c'est-à-dire que la deuxième étape (la réponse à `config_is_local`) attend : implémenter « attendre la porte avant toute étape autre que `.start` ».

`swift test --filter WizardModelTests 2>&1 | grep -E "error:" | head -2` → compilation.

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Connections/ServiceCatalog.swift` :

```swift
import Foundation

/// Les services proposés par l'assistant.
public enum CloudService: String, CaseIterable, Identifiable, Sendable {
    case drive, dropbox, onedrive, s3
    public var id: String { rawValue }

    public var rcloneType: String { rawValue }

    public var symbol: String {
        switch self {
        case .drive: return "externaldrive.connected.to.line.below"
        case .dropbox: return "shippingbox"
        case .onedrive: return "cloud"
        case .s3: return "server.rack"
        }
    }

    /// Connexion par le navigateur (OAuth) ; S3 se contente de clés.
    public var usesBrowser: Bool { self != .s3 }

    /// Clé du nom affiché (et du nom proposé pour la connexion).
    public var nameKey: String { "service.\(rawValue)" }

    public static func forType(_ type: String) -> CloudService? { CloudService(rawValue: type) }

    /// Réponses données à la place de l'utilisateur, par nom d'option de rclone.
    public static func autoAnswer(option: String) -> String? {
        switch option {
        case "config_shared_client_id": return "true"           // l'assistant a déjà expliqué l'identifiant partagé
        case "config_is_local": return "true"             // l'utilisateur a cliqué « Se connecter »
        case "config_change_team_drive": return "false"   // un Drive partagé se choisit plus tard, à la main
        case "config_drive_ok": return "true"
        default: return nil
        }
    }
}

public enum S3Provider: String, CaseIterable, Identifiable, Sendable {
    case aws = "AWS", cloudflare = "Cloudflare", wasabi = "Wasabi", minio = "Minio", other = "Other"
    public var id: String { rawValue }
    /// Hors AWS, l'adresse du service est demandée.
    public var needsEndpoint: Bool { self != .aws }
}
```

`Sources/SyncMacProUI/Connections/WizardModel.swift` :

```swift
import Foundation
import Observation
import SyncKit

public enum WizardStep: Equatable, Sendable {
    case service, prepare, name, connect, test, done
}

/// L'assistant de connexion, sans vue : étapes, saisies, dialogue avec rclone par l'agent.
@MainActor
@Observable
public final class WizardModel {
    public var step: WizardStep = .service
    public private(set) var service: CloudService = .drive
    public var ownClient = true
    public var clientID = ""
    public var clientSecret = ""
    public var s3Provider: S3Provider = .aws
    public var accessKey = ""
    public var secretKey = ""
    public var region = ""
    public var endpoint = ""
    public var name = ""
    public private(set) var question: RemoteQuestion?
    public var answer = ""
    public private(set) var busy = false
    public private(set) var waitingForBrowser = false
    public private(set) var error: String?
    public private(set) var testResult: RemoteTestResult?
    public private(set) var reconnecting = false
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored let model: AgentModel
    @ObservationIgnored let localizer: Localizer

    public init(model: AgentModel, localizer: Localizer = .system) {
        self.model = model
        self.localizer = localizer
    }

    /// Reconnexion d'une connexion existante : on va droit au navigateur.
    public init(reconnecting remote: RemoteInfo, model: AgentModel, localizer: Localizer = .system) {
        self.model = model
        self.localizer = localizer
        service = CloudService.forType(remote.type) ?? .drive
        name = remote.name
        reconnecting = true
        step = .connect
    }

    public var nameProblem: RemoteNameProblem? {
        RemoteNameRule.problem(name, existing: model.remotes.map(\.name))
    }

    public var canContinue: Bool {
        switch step {
        case .service: return true
        case .prepare:
            switch service {
            case .drive: return !ownClient || (!clientID.trimmed.isEmpty && !clientSecret.trimmed.isEmpty)
            case .s3:
                return !accessKey.trimmed.isEmpty && !secretKey.trimmed.isEmpty
                    && (!s3Provider.needsEndpoint || !endpoint.trimmed.isEmpty)
            case .dropbox, .onedrive: return true
            }
        case .name: return nameProblem == nil
        case .connect:
            guard let question else { return !busy }
            return !question.required || !answer.trimmed.isEmpty
        case .test, .done: return true
        }
    }

    /// Paramètres connus d'avance, passés à `rclone config create`.
    public var parameters: [String: String] {
        switch service {
        case .drive:
            var values = ["scope": "drive"]
            if ownClient {
                values["client_id"] = clientID.trimmed
                values["client_secret"] = clientSecret.trimmed
            }
            return values
        case .s3:
            var values = [
                "provider": s3Provider.rawValue, "env_auth": "false",
                "access_key_id": accessKey.trimmed, "secret_access_key": secretKey.trimmed,
            ]
            if !region.trimmed.isEmpty { values["region"] = region.trimmed }
            if s3Provider.needsEndpoint { values["endpoint"] = endpoint.trimmed }
            return values
        case .dropbox, .onedrive: return [:]
        }
    }

    public func choose(_ chosen: CloudService) {
        service = chosen
        name = RemoteNameRule.suggestion(localizer.text(chosen.nameKey), existing: model.remotes.map(\.name))
        step = .prepare
    }

    public func next() {
        guard canContinue else { return }
        switch step {
        case .service: step = .prepare
        case .prepare: step = .name
        case .name: step = .connect
        case .connect, .test, .done: break
        }
    }

    public func back() {
        error = nil
        switch step {
        case .prepare: step = .service
        case .name: step = .prepare
        case .connect where question == nil && !busy && !reconnecting: step = .name
        default: break
        }
    }

    /// Crée la connexion (ou la reconnecte), puis répond seul aux questions connues.
    public func connect() async {
        let first: RemoteConfigStep = reconnecting
            ? .reconnect(name: name)
            : .start(name: name, type: service.rcloneType, parameters: parameters)
        await run(first)
    }

    public func submitAnswer() async {
        guard let question, canContinue else { return }
        self.question = nil
        await run(.answer(name: name, state: question.state, result: answer.trimmed))
    }

    private func run(_ first: RemoteConfigStep) async {
        error = nil
        cancelled = false
        busy = true
        defer {
            busy = false
            waitingForBrowser = false
        }
        var result = await model.configureRemote(first)
        while true {
            if cancelled { return }
            switch result {
            case .failed(let message):
                error = message
                return
            case .done:
                step = .test
                await retest()
                return
            case .question(let next):
                guard let automatic = CloudService.autoAnswer(option: next.option) else {
                    question = next
                    answer = next.defaultValue
                    return
                }
                waitingForBrowser = next.option == "config_is_local" && automatic == "true"
                result = await model.configureRemote(.answer(name: name, state: next.state, result: automatic))
                waitingForBrowser = false
            }
        }
    }

    public func cancel() async {
        cancelled = true
        question = nil
        await model.cancelRemoteConfiguration(name)
    }

    public func retest() async {
        testResult = nil
        let result = await model.testRemote(name)
        testResult = result
        if result.ok { step = .done }
    }

    /// Le test a échoué : on supprime la connexion et on revient corriger les saisies.
    public func fix() async {
        _ = await model.deleteRemote(name)
        testResult = nil
        step = reconnecting ? .connect : .prepare
    }

    public func keepAnyway() {
        step = .done
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
```

Chaînes (fr / en) : `"service.drive" = "Google Drive"`, `"service.dropbox" = "Dropbox"`, `"service.onedrive" = "OneDrive"`, `"service.s3" = "Amazon S3"` (identiques en anglais) ; ajouter `connections|wizard|service|remote` à la regex du test de complétude.

- [ ] **Étape 3 : vérifier** — `swift test --filter WizardModelTests` → 10 tests passent.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "App : catalogue des services et modèle de l'assistant (réponses automatiques, questions de rclone, test, correction)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 7 : l'écran Connexions

**Fichiers :** créer `Sources/SyncMacProUI/Views/ConnectionsView.swift`, `Tests/SyncMacProUITests/ConnectionsRenderTests.swift` ; modifier `RootView.swift`, `RootViewTests.swift`, chaînes.

**Interfaces :** `struct ConnectionRowState: Equatable` (`testing: Bool`, `result: RemoteTestResult?`) ; `struct ConnectionsListBody: View` (`remotes`, `usage: [String: [String]]`, `rows: [String: ConnectionRowState]`, `error: String?`, `offline`, `localizer`, actions `onTest`, `onReconnect`, `onDelete`) ; `struct ConnectionsView: View` (`model`, `localizer`) ; `SidebarItem.connections` (avant `settings`).

- [ ] **Étape 1 : tests qui échouent**

```swift
import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class ConnectionsRenderTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func body(_ remotes: [RemoteInfo], rows: [String: ConnectionRowState] = [:], error: String? = nil) -> ConnectionsListBody {
        ConnectionsListBody(
            remotes: remotes, usage: ["Drive": ["Photos vers Drive"]], rows: rows, error: error, offline: false,
            localizer: fr, onTest: { _ in }, onReconnect: { _ in }, onDelete: { _ in }
        )
    }

    func testListRendersEveryRowState() throws {
        let remotes = [RemoteInfo(name: "Drive", type: "drive"), RemoteInfo(name: "nas", type: "smb"), RemoteInfo(name: "S3", type: "s3")]
        let rows: [String: ConnectionRowState] = [
            "Drive": ConnectionRowState(testing: false, result: RemoteTestResult(ok: true)),
            "nas": ConnectionRowState(testing: true, result: nil),
            "S3": ConnectionRowState(testing: false, result: RemoteTestResult(ok: false, message: "InvalidAccessKeyId")),
        ]
        for scheme in [ColorScheme.light, .dark] {
            assertNotBlank(try render(body(remotes, rows: rows), name: "connections", size: CGSize(width: 640, height: 260), scheme: scheme))
        }
    }

    func testEmptyAndErrorStatesRender() throws {
        assertNotBlank(try render(body([]), name: "connections-empty", size: CGSize(width: 640, height: 160), scheme: .light))
        assertNotBlank(try render(body([], error: "rclone est introuvable."), name: "connections-error", size: CGSize(width: 640, height: 160), scheme: .light))
    }

    func testServiceLabels() {
        XCTAssertEqual(ConnectionsListBody.serviceName("drive", localizer: fr), "Google Drive")
        XCTAssertEqual(ConnectionsListBody.serviceName("smb", localizer: fr), "smb")
        XCTAssertTrue(ConnectionsListBody.canReconnect("drive"))
        XCTAssertFalse(ConnectionsListBody.canReconnect("s3"))
        XCTAssertFalse(ConnectionsListBody.canReconnect("smb"))
    }
}
```

`RootViewTests.testSidebarEntries` : `[.dashboard, .tasks, .copy, .history, .connections, .settings]`.

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Views/ConnectionsView.swift` :

```swift
import SwiftUI
import SyncKit

public struct ConnectionRowState: Equatable, Sendable {
    public var testing: Bool
    public var result: RemoteTestResult?

    public init(testing: Bool, result: RemoteTestResult?) {
        self.testing = testing
        self.result = result
    }
}

/// La liste des connexions, sans défilement (rendue par les tests).
@MainActor
struct ConnectionsListBody: View {
    let remotes: [RemoteInfo]
    let usage: [String: [String]]
    let rows: [String: ConnectionRowState]
    let error: String?
    let offline: Bool
    let localizer: Localizer
    let onTest: (RemoteInfo) -> Void
    let onReconnect: (RemoteInfo) -> Void
    let onDelete: (RemoteInfo) -> Void

    static func serviceName(_ type: String, localizer: Localizer) -> String {
        CloudService.forType(type).map { localizer.text($0.nameKey) } ?? type
    }

    /// Les services à jeton peuvent être reconnectés (jeton expiré ou révoqué).
    static func canReconnect(_ type: String) -> Bool {
        CloudService.forType(type)?.usesBrowser ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if remotes.isEmpty && error == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localizer.text("connections.empty.title")).font(.headline)
                    Text(localizer.text("connections.empty.body")).foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
            }
            ForEach(remotes) { remote in row(remote) }
        }
    }

    private func row(_ remote: RemoteInfo) -> some View {
        let state = rows[remote.name]
        let users = usage[remote.name] ?? []
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: CloudService.forType(remote.type)?.symbol ?? "externaldrive.badge.icloud")
                .font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(remote.name).font(.headline)
                Text(Self.serviceName(remote.type, localizer: localizer)).font(.caption).foregroundStyle(.secondary)
                Text(users.isEmpty ? localizer.text("connections.unused") : localizer.format("connections.usedBy", users.joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let state { status(state) }
            }
            Spacer(minLength: 8)
            Button(localizer.text("connections.test")) { onTest(remote) }.disabled(offline || state?.testing == true)
            if Self.canReconnect(remote.type) {
                Button(localizer.text("connections.reconnect")) { onReconnect(remote) }.disabled(offline)
            }
            Button(role: .destructive) { onDelete(remote) } label: { Image(systemName: "trash") }
                .disabled(offline).help(localizer.text("connections.delete"))
        }
        .controlSize(.small)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func status(_ state: ConnectionRowState) -> some View {
        if state.testing {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(localizer.text("connections.testing")) }.font(.caption)
        } else if let result = state.result {
            Label(
                result.ok ? localizer.text("connections.ok") : localizer.format("connections.failed", result.message ?? ""),
                systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.caption).foregroundStyle(result.ok ? .green : .red).lineLimit(3)
        }
    }
}

/// L'écran Connexions : liste, Ajouter, Tester, Reconnecter, Supprimer.
@MainActor
struct ConnectionsView: View {
    let model: AgentModel
    let localizer: Localizer
    @State private var rows: [String: ConnectionRowState] = [:]
    @State private var wizard: WizardModel?
    @State private var deleting: RemoteInfo?
    @State private var refusal: String?

    private var offline: Bool { model.connection != .connected }

    private var usage: [String: [String]] {
        Dictionary(uniqueKeysWithValues: model.remotes.map { ($0.name, model.tasks(usingRemote: $0.name).map(\.name)) })
    }

    var body: some View {
        ScrollView {
            ConnectionsListBody(
                remotes: model.remotes, usage: usage, rows: rows, error: model.remotesError, offline: offline,
                localizer: localizer,
                onTest: { remote in Task { await test(remote) } },
                onReconnect: { remote in wizard = WizardModel(reconnecting: remote, model: model, localizer: localizer) },
                onDelete: { deleting = $0 }
            )
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(localizer.text("sidebar.connections"))
        .toolbar {
            Button { wizard = WizardModel(model: model, localizer: localizer) } label: {
                Label(localizer.text("connections.add"), systemImage: "plus")
            }
            .disabled(offline)
        }
        .task { await model.reloadRemotes() }
        .sheet(item: Binding(get: { wizard.map(WizardSession.init) }, set: { if $0 == nil { wizard = nil } })) { session in
            ConnectionWizardView(wizard: session.wizard, localizer: localizer) {
                wizard = nil
                Task { await model.reloadRemotes() }
            }
        }
        .confirmationDialog(
            localizer.format("connections.delete.confirm", deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(localizer.text("connections.delete"), role: .destructive) {
                if let remote = deleting { Task { refusal = await model.deleteRemote(remote.name) } }
            }
        }
        .alert(localizer.text("alert.title"), isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button(localizer.text("alert.ok")) {}
        } message: {
            Text(refusal ?? "")
        }
    }

    private func test(_ remote: RemoteInfo) async {
        rows[remote.name] = ConnectionRowState(testing: true, result: nil)
        let result = await model.testRemote(remote.name)
        rows[remote.name] = ConnectionRowState(testing: false, result: result)
    }
}

/// Enveloppe identifiable d'un assistant ouvert (pour `.sheet(item:)`).
struct WizardSession: Identifiable {
    let wizard: WizardModel
    var id: ObjectIdentifier { ObjectIdentifier(wizard) }
}
```

`ConnectionWizardView` vient de la tâche 8 : pour que cette tâche compile seule, créer ici un `ConnectionWizardView` minimal (titre et bouton Fermer) que la tâche 8 remplacera.

`RootView.swift` : `case dashboard, tasks, copy, history, connections, settings` ; `detail` : `case .connections: ConnectionsView(model: model, localizer: localizer)` ; titre `sidebar.connections`, icône `"link"`.

Chaînes fr :

```
"sidebar.connections" = "Connexions";
"connections.empty.title" = "Aucune connexion";
"connections.empty.body" = "Ajoutez Google Drive, Dropbox, OneDrive ou un stockage S3 pour vous en servir dans vos tâches.";
"connections.unused" = "Utilisée par aucune tâche";
"connections.usedBy" = "Utilisée par : %@";
"connections.test" = "Tester";
"connections.testing" = "Test en cours…";
"connections.ok" = "La connexion répond.";
"connections.failed" = "La connexion ne répond pas : %@";
"connections.reconnect" = "Reconnecter";
"connections.delete" = "Supprimer";
"connections.delete.confirm" = "Supprimer la connexion « %@ » ?";
"connections.add" = "Ajouter une connexion";
```

en :

```
"sidebar.connections" = "Connections";
"connections.empty.title" = "No connections";
"connections.empty.body" = "Add Google Drive, Dropbox, OneDrive or S3 storage to use it in your tasks.";
"connections.unused" = "Not used by any task";
"connections.usedBy" = "Used by: %@";
"connections.test" = "Test";
"connections.testing" = "Testing…";
"connections.ok" = "The connection responds.";
"connections.failed" = "The connection doesn’t respond: %@";
"connections.reconnect" = "Reconnect";
"connections.delete" = "Delete";
"connections.delete.confirm" = "Delete the connection “%@”?";
"connections.add" = "Add a connection";
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "ConnectionsRenderTests|RootViewTests|StringsCompletenessTests"` → passent ; regarder `connections-*.png`.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "Écran Connexions : liste, test, reconnexion, suppression protégée" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 8 : la feuille de l'assistant

**Fichiers :** remplacer `ConnectionWizardView` (créé minimal en tâche 7) par `Sources/SyncMacProUI/Views/ConnectionWizardView.swift` ; tester `Tests/SyncMacProUITests/WizardRenderTests.swift` ; chaînes `wizard.*`.

**Interfaces :** `struct WizardStepContent: View` (`wizard: WizardModel`, `localizer`) sans défilement ; `struct ConnectionWizardView: View` (`wizard`, `localizer`, `onClose`) ; `static let googleConsoleURL`.

- [ ] **Étape 1 : tests qui échouent**

```swift
import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class WizardRenderTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func wizard(_ configure: (WizardModel) -> Void) -> WizardModel {
        let model = AgentModel(agent: FakeAgent(), sleeper: ManualSleeper())
        let wizard = WizardModel(model: model, localizer: fr)
        configure(wizard)
        return wizard
    }

    func testEveryStepRenders() throws {
        let cases: [(String, WizardModel)] = [
            ("service", wizard { _ in }),
            ("drive-own", wizard { $0.choose(.drive) }),
            ("drive-shared", wizard { $0.choose(.drive); $0.ownClient = false }),
            ("s3", wizard { $0.choose(.s3); $0.s3Provider = .minio }),
            ("name", wizard { $0.choose(.dropbox); $0.next() }),
            ("connect", wizard { $0.choose(.dropbox); $0.next(); $0.next() }),
            ("test", wizard { $0.choose(.dropbox); $0.step = .test }),
            ("done", wizard { $0.choose(.dropbox); $0.step = .done }),
        ]
        for (name, wizard) in cases {
            let view = WizardStepContent(wizard: wizard, localizer: fr)
            assertNotBlank(try render(view, name: "wizard-\(name)", size: CGSize(width: 560, height: 420), scheme: .light))
        }
    }

    func testGenericQuestionRenders() throws {
        let view = WizardQuestionView(
            question: RemoteQuestion(state: "s", option: "config_driveid", help: "Choisissez le lecteur",
                                     choices: [RemoteChoice(value: "a", help: "OneDrive (personal)"), RemoteChoice(value: "b", help: "Documents")],
                                     exclusive: true),
            answer: .constant("a"), localizer: fr
        )
        assertNotBlank(try render(view, name: "wizard-question", size: CGSize(width: 520, height: 200), scheme: .light))
    }

    func testDriveGuideLinksToTheConsole() {
        XCTAssertEqual(ConnectionWizardView.googleConsoleURL.host, "console.cloud.google.com")
    }
}
```

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Views/ConnectionWizardView.swift` :

```swift
import AppKit
import SwiftUI
import SyncKit

/// Une question de rclone posée telle quelle : choix parmi les exemples, ou champ libre (secret si besoin).
@MainActor
struct WizardQuestionView: View {
    let question: RemoteQuestion
    @Binding var answer: String
    let localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.help.isEmpty ? question.option : question.help).fixedSize(horizontal: false, vertical: true)
            if question.exclusive && !question.choices.isEmpty {
                Picker("", selection: $answer) {
                    ForEach(question.choices, id: \.value) { choice in
                        Text(choice.help.isEmpty ? choice.value : choice.help).tag(choice.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            } else if question.isPassword {
                SecureField(question.option, text: $answer).textFieldStyle(.roundedBorder)
            } else {
                TextField(question.option, text: $answer).textFieldStyle(.roundedBorder)
                if !question.choices.isEmpty {
                    Text(localizer.format("wizard.question.examples", question.choices.prefix(5).map(\.value).joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Le contenu de l'étape courante, sans défilement ni boutons (rendu par les tests).
@MainActor
struct WizardStepContent: View {
    @Bindable var wizard: WizardModel
    let localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch wizard.step {
            case .service: services
            case .prepare: prepare
            case .name: nameStep
            case .connect: connect
            case .test: test
            case .done: done
            }
            if let error = wizard.error {
                Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serviceName: String { localizer.text(wizard.service.nameKey) }

    private var services: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localizer.text("wizard.service.title")).font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(CloudService.allCases) { service in
                    Button { wizard.choose(service) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: service.symbol).font(.title2).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(localizer.text(service.nameKey)).font(.headline)
                                Text(localizer.text("wizard.service.\(service.rawValue).help"))
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var prepare: some View {
        Text(serviceName).font(.title3.bold())
        switch wizard.service {
        case .drive:
            Picker("", selection: $wizard.ownClient) {
                Text(localizer.text("wizard.drive.own")).tag(true)
                Text(localizer.text("wizard.drive.shared")).tag(false)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if wizard.ownClient {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(1...5, id: \.self) { index in
                        Text(localizer.text("wizard.drive.step\(index)")).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
                Button(localizer.text("wizard.drive.console")) { NSWorkspace.shared.open(ConnectionWizardView.googleConsoleURL) }
                TextField(localizer.text("wizard.drive.clientID"), text: $wizard.clientID).textFieldStyle(.roundedBorder)
                SecureField(localizer.text("wizard.drive.clientSecret"), text: $wizard.clientSecret).textFieldStyle(.roundedBorder)
            } else {
                Label(localizer.text("wizard.drive.shared.warning"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        case .s3:
            Picker(localizer.text("wizard.s3.provider"), selection: $wizard.s3Provider) {
                ForEach(S3Provider.allCases) { provider in
                    Text(localizer.text("wizard.s3.provider.\(provider.rawValue)")).tag(provider)
                }
            }
            TextField(localizer.text("wizard.s3.accessKey"), text: $wizard.accessKey).textFieldStyle(.roundedBorder)
            SecureField(localizer.text("wizard.s3.secretKey"), text: $wizard.secretKey).textFieldStyle(.roundedBorder)
            TextField(localizer.text("wizard.s3.region"), text: $wizard.region).textFieldStyle(.roundedBorder)
            if wizard.s3Provider.needsEndpoint {
                TextField(localizer.text("wizard.s3.endpoint"), text: $wizard.endpoint).textFieldStyle(.roundedBorder)
            }
        case .dropbox, .onedrive:
            Text(localizer.format("wizard.browser.help", serviceName)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var nameStep: some View {
        Text(localizer.text("wizard.name.title")).font(.title3.bold())
        TextField(localizer.text("wizard.name.placeholder"), text: $wizard.name).textFieldStyle(.roundedBorder)
        Text(localizer.text("wizard.name.help")).font(.caption).foregroundStyle(.secondary)
        if let problem = wizard.nameProblem {
            Text(localizer.text("wizard.name.problem.\(Self.key(problem))")).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var connect: some View {
        Text(localizer.format(wizard.reconnecting ? "wizard.connect.reconnect" : "wizard.connect.title", wizard.name))
            .font(.title3.bold())
        if wizard.waitingForBrowser {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(localizer.text("wizard.connect.browser")) }
        } else if let question = wizard.question {
            WizardQuestionView(question: question, answer: $wizard.answer, localizer: localizer)
        } else if wizard.busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(localizer.text("wizard.connect.working")) }
        } else {
            Text(localizer.text(wizard.service.usesBrowser ? "wizard.connect.help.browser" : "wizard.connect.help.keys"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var test: some View {
        Text(localizer.text("wizard.test.title")).font(.title3.bold())
        if let result = wizard.testResult, !result.ok {
            Label(localizer.format("connections.failed", result.message ?? ""), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Text(localizer.text("wizard.test.fixHelp")).font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(localizer.text("connections.testing")) }
        }
    }

    @ViewBuilder private var done: some View {
        Label(localizer.format("wizard.done.title", wizard.name), systemImage: "checkmark.seal.fill")
            .font(.title3.bold()).foregroundStyle(.green)
        Text(localizer.text("wizard.done.body")).fixedSize(horizontal: false, vertical: true)
    }

    static func key(_ problem: RemoteNameProblem) -> String {
        switch problem {
        case .empty: return "empty"
        case .invalidCharacters: return "characters"
        case .badStart: return "start"
        case .badEnd: return "end"
        case .taken: return "taken"
        }
    }
}

/// La feuille de l'assistant : contenu de l'étape et boutons (Annuler, Précédent, Suivant / Se connecter / Terminé).
@MainActor
struct ConnectionWizardView: View {
    @Bindable var wizard: WizardModel
    let localizer: Localizer
    let onClose: () -> Void

    static let googleConsoleURL = URL(string: "https://console.cloud.google.com/apis/credentials")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView { WizardStepContent(wizard: wizard, localizer: localizer).padding(.bottom, 8) }
            HStack {
                Button(localizer.text("confirm.cancel"), role: .cancel) {
                    Task {
                        if wizard.busy || wizard.question != nil { await wizard.cancel() }
                        onClose()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(wizard.step == .done)
                if [.prepare, .name].contains(wizard.step) || (wizard.step == .connect && !wizard.busy && wizard.question == nil && !wizard.reconnecting) {
                    Button(localizer.text("editor.previous")) { wizard.back() }
                }
                Spacer()
                primary
            }
        }
        .padding(20)
        .frame(width: 580, height: 480)
    }

    @ViewBuilder private var primary: some View {
        switch wizard.step {
        case .service: EmptyView()
        case .prepare, .name:
            Button(localizer.text("editor.next")) { wizard.next() }.keyboardShortcut(.defaultAction).disabled(!wizard.canContinue)
        case .connect:
            if wizard.question != nil {
                Button(localizer.text("wizard.question.continue")) { Task { await wizard.submitAnswer() } }
                    .keyboardShortcut(.defaultAction).disabled(!wizard.canContinue)
            } else {
                Button(localizer.text(wizard.service.usesBrowser ? "wizard.connect.go.browser" : "wizard.connect.go.keys")) {
                    Task { await wizard.connect() }
                }
                .keyboardShortcut(.defaultAction).disabled(wizard.busy)
            }
        case .test:
            if let result = wizard.testResult, !result.ok {
                Button(localizer.text("wizard.test.keep")) { wizard.keepAnyway() }
                Button(localizer.text("wizard.test.fix")) { Task { await wizard.fix() } }.keyboardShortcut(.defaultAction)
            }
        case .done:
            Button(localizer.text("wizard.done.close")) { onClose() }.keyboardShortcut(.defaultAction)
        }
    }
}
```

(`editor.previous` / `editor.next` : vérifier les clés existantes de l'éditeur 3b et les réutiliser ; sinon ajouter `wizard.previous` / `wizard.next`.)

Chaînes fr :

```
"wizard.service.title" = "Quel service voulez-vous connecter ?";
"wizard.service.drive.help" = "Votre Drive personnel ou professionnel";
"wizard.service.dropbox.help" = "Votre Dropbox";
"wizard.service.onedrive.help" = "OneDrive personnel, professionnel ou SharePoint";
"wizard.service.s3.help" = "Amazon S3, Cloudflare R2, Wasabi, MinIO…";
"wizard.drive.own" = "Avec mon propre identifiant Google (recommandé)";
"wizard.drive.shared" = "Avec l’identifiant partagé de rclone (plus rapide)";
"wizard.drive.step1" = "1. Ouvrez la console Google Cloud et créez un projet (ou choisissez-en un).";
"wizard.drive.step2" = "2. Activez « Google Drive API » (Bibliothèque).";
"wizard.drive.step3" = "3. Écran de consentement OAuth : type « Externe », ajoutez votre adresse comme utilisateur test, puis « Publier l’application » (sinon la connexion expire au bout de 7 jours).";
"wizard.drive.step4" = "4. Identifiants › Créer des identifiants › ID client OAuth › type « Application de bureau ».";
"wizard.drive.step5" = "5. Copiez ici l’ID client et le code secret.";
"wizard.drive.console" = "Ouvrir la console Google Cloud";
"wizard.drive.clientID" = "ID client";
"wizard.drive.clientSecret" = "Code secret du client";
"wizard.drive.shared.warning" = "L’identifiant partagé de rclone est limité (lenteurs aux heures chargées) et Google le retire en 2026 : la connexion pourra cesser de fonctionner. Préférez votre propre identifiant pour un usage durable.";
"wizard.s3.provider" = "Fournisseur";
"wizard.s3.provider.AWS" = "Amazon S3";
"wizard.s3.provider.Cloudflare" = "Cloudflare R2";
"wizard.s3.provider.Wasabi" = "Wasabi";
"wizard.s3.provider.Minio" = "MinIO";
"wizard.s3.provider.Other" = "Autre service compatible S3";
"wizard.s3.accessKey" = "Clé d’accès";
"wizard.s3.secretKey" = "Clé secrète";
"wizard.s3.region" = "Région (ex. eu-west-3), facultative";
"wizard.s3.endpoint" = "Adresse du service (ex. https://…)";
"wizard.browser.help" = "%@ s’ouvrira dans votre navigateur pour autoriser SyncMacPro : connectez-vous et acceptez.";
"wizard.name.title" = "Nom de la connexion";
"wizard.name.placeholder" = "Nom";
"wizard.name.help" = "C’est ce nom que vous choisirez dans vos tâches.";
"wizard.name.problem.empty" = "Donnez un nom à la connexion.";
"wizard.name.problem.characters" = "Lettres, chiffres, espaces et _ - . + @ seulement.";
"wizard.name.problem.start" = "Le nom ne peut pas commencer par une espace ni par « - ».";
"wizard.name.problem.end" = "Le nom ne peut pas finir par une espace.";
"wizard.name.problem.taken" = "Ce nom est déjà utilisé par une autre connexion.";
"wizard.connect.title" = "Connexion de « %@ »";
"wizard.connect.reconnect" = "Reconnexion de « %@ »";
"wizard.connect.help.browser" = "Cliquez sur « Se connecter » : votre navigateur s’ouvre ; revenez ici une fois l’accès accordé.";
"wizard.connect.help.keys" = "Cliquez sur « Créer » : la connexion est enregistrée puis testée.";
"wizard.connect.go.browser" = "Se connecter";
"wizard.connect.go.keys" = "Créer";
"wizard.connect.browser" = "Terminez la connexion dans votre navigateur…";
"wizard.connect.working" = "Configuration en cours…";
"wizard.question.continue" = "Continuer";
"wizard.question.examples" = "Exemples : %@";
"wizard.test.title" = "Vérification de la connexion";
"wizard.test.fixHelp" = "Corriger supprime cette connexion et revient aux réglages ; vous pouvez aussi la garder telle quelle.";
"wizard.test.fix" = "Corriger";
"wizard.test.keep" = "Garder quand même";
"wizard.done.title" = "« %@ » est prête";
"wizard.done.body" = "Vous pouvez la choisir comme source ou destination dans vos tâches (côté « Service en ligne »).";
"wizard.done.close" = "Terminé";
```

en :

```
"wizard.service.title" = "Which service do you want to connect?";
"wizard.service.drive.help" = "Your personal or work Drive";
"wizard.service.dropbox.help" = "Your Dropbox";
"wizard.service.onedrive.help" = "OneDrive personal, business or SharePoint";
"wizard.service.s3.help" = "Amazon S3, Cloudflare R2, Wasabi, MinIO…";
"wizard.drive.own" = "With my own Google client ID (recommended)";
"wizard.drive.shared" = "With rclone’s shared client ID (faster)";
"wizard.drive.step1" = "1. Open the Google Cloud console and create a project (or pick one).";
"wizard.drive.step2" = "2. Enable “Google Drive API” (Library).";
"wizard.drive.step3" = "3. OAuth consent screen: type “External”, add your address as a test user, then “Publish app” (otherwise the connection expires after 7 days).";
"wizard.drive.step4" = "4. Credentials › Create credentials › OAuth client ID › type “Desktop app”.";
"wizard.drive.step5" = "5. Copy the client ID and client secret here.";
"wizard.drive.console" = "Open the Google Cloud console";
"wizard.drive.clientID" = "Client ID";
"wizard.drive.clientSecret" = "Client secret";
"wizard.drive.shared.warning" = "rclone’s shared client ID is rate-limited and Google is retiring it in 2026: the connection may stop working. Use your own client ID for lasting use.";
"wizard.s3.provider" = "Provider";
"wizard.s3.provider.AWS" = "Amazon S3";
"wizard.s3.provider.Cloudflare" = "Cloudflare R2";
"wizard.s3.provider.Wasabi" = "Wasabi";
"wizard.s3.provider.Minio" = "MinIO";
"wizard.s3.provider.Other" = "Other S3-compatible service";
"wizard.s3.accessKey" = "Access key";
"wizard.s3.secretKey" = "Secret key";
"wizard.s3.region" = "Region (e.g. eu-west-3), optional";
"wizard.s3.endpoint" = "Service address (e.g. https://…)";
"wizard.browser.help" = "%@ will open in your browser to authorize SyncMacPro: sign in and accept.";
"wizard.name.title" = "Connection name";
"wizard.name.placeholder" = "Name";
"wizard.name.help" = "This is the name you’ll pick in your tasks.";
"wizard.name.problem.empty" = "Give the connection a name.";
"wizard.name.problem.characters" = "Letters, digits, spaces and _ - . + @ only.";
"wizard.name.problem.start" = "The name can’t start with a space or “-”.";
"wizard.name.problem.end" = "The name can’t end with a space.";
"wizard.name.problem.taken" = "This name is already used by another connection.";
"wizard.connect.title" = "Connecting “%@”";
"wizard.connect.reconnect" = "Reconnecting “%@”";
"wizard.connect.help.browser" = "Click “Sign in”: your browser opens; come back here once access is granted.";
"wizard.connect.help.keys" = "Click “Create”: the connection is saved, then tested.";
"wizard.connect.go.browser" = "Sign in";
"wizard.connect.go.keys" = "Create";
"wizard.connect.browser" = "Finish signing in in your browser…";
"wizard.connect.working" = "Configuring…";
"wizard.question.continue" = "Continue";
"wizard.question.examples" = "Examples: %@";
"wizard.test.title" = "Checking the connection";
"wizard.test.fixHelp" = "Fix deletes this connection and goes back to the settings; you can also keep it as is.";
"wizard.test.fix" = "Fix";
"wizard.test.keep" = "Keep anyway";
"wizard.done.title" = "“%@” is ready";
"wizard.done.body" = "You can pick it as a source or destination in your tasks (“Online service” side).";
"wizard.done.close" = "Done";
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "WizardRenderTests|StringsCompletenessTests"` → passent ; regarder `wizard-*.png`.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "Assistant de connexion : services, préparation (Drive guidé, S3), nom, connexion par le navigateur, test" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 9 : l'éditeur choisit une connexion et un dossier distant

**Fichiers :** créer `Sources/SyncMacProUI/Views/RemoteFolderPicker.swift`, `Tests/SyncMacProUITests/RemoteFolderPickerTests.swift` ; modifier `EditorSteps.swift` (`SideEditor`, `EndpointsStepView`, `EditorStepContent`), `TaskEditorView.swift`, `EditorRenderTests.swift`, chaînes `remote.*`.

**Interfaces :**
- `struct RemoteContext` : `remotes: [RemoteInfo]`, `onAdd: () -> Void`, `browse: (String, String) async -> FolderListing` ; `static let none` ; passé à `EditorStepContent(…, remotes: RemoteContext = .none)` puis à `EndpointsStepView` / `SideEditor` ;
- `struct RemotePath` (logique pure) : `static func components(_ path: String) -> [String]`, `static func join(_ parts: [String]) -> String`, `static func parent(_ path: String) -> String` ;
- `struct RemoteFolderListBody: View` (`remote`, `path`, `listing: FolderListing?`, `localizer`, `onOpen(String)`) ; `struct RemoteFolderPicker: View` (`remote`, `startPath`, `localizer`, `browse`, `onChoose: (String) -> Void`, `onCancel`).

- [ ] **Étape 1 : tests qui échouent**

```swift
import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class RemoteFolderPickerTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func testPaths() {
        XCTAssertEqual(RemotePath.components("/Photos//2024/"), ["Photos", "2024"])
        XCTAssertEqual(RemotePath.join(["Photos", "2024"]), "Photos/2024")
        XCTAssertEqual(RemotePath.parent("Photos/2024"), "Photos")
        XCTAssertEqual(RemotePath.parent("Photos"), "")
        XCTAssertEqual(RemotePath.parent(""), "")
    }

    func testListingStatesRender() throws {
        let states: [FolderListing?] = [nil, .loaded(["2023", "2024"]), .loaded([]), .failed("jeton expiré")]
        for (index, state) in states.enumerated() {
            let view = RemoteFolderListBody(remote: "Drive", path: "Photos", listing: state, localizer: fr, onOpen: { _ in })
            assertNotBlank(try render(view, name: "remote-folders-\(index)", size: CGSize(width: 480, height: 220), scheme: .light))
        }
    }

    func testCloudSideRendersWithConnections() throws {
        var draft = TaskDraft()
        draft.destination.kind = .cloud
        draft.destination.remote = "Drive"
        draft.destination.path = "Sauvegardes"
        let context = RemoteContext(remotes: [RemoteInfo(name: "Drive", type: "drive")], onAdd: {}, browse: { _, _ in .loaded([]) })
        let view = EndpointsStepView(draft: .constant(draft), localizer: fr, remotes: context)
        assertNotBlank(try render(view, name: "editor-cloud-side", size: CGSize(width: 620, height: 300), scheme: .light))
    }
}
```

- [ ] **Étape 2 : implémenter**

`Sources/SyncMacProUI/Views/RemoteFolderPicker.swift` :

```swift
import SwiftUI
import SyncKit

/// Ce que l'éditeur sait des connexions : la liste, l'ajout, la navigation dans un service.
struct RemoteContext {
    var remotes: [RemoteInfo]
    var onAdd: () -> Void
    var browse: (String, String) async -> FolderListing

    static let none = RemoteContext(remotes: [], onAdd: {}, browse: { _, _ in .loaded([]) })
}

enum RemotePath {
    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func join(_ parts: [String]) -> String { parts.joined(separator: "/") }

    static func parent(_ path: String) -> String { join(Array(components(path).dropLast())) }
}

/// Les sous-dossiers d'un dossier distant, sans défilement (rendu par les tests).
@MainActor
struct RemoteFolderListBody: View {
    let remote: String
    let path: String
    let listing: FolderListing?
    let localizer: Localizer
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(remote):\(path.isEmpty ? "" : "/" + path)").font(.callout.monospaced()).foregroundStyle(.secondary).padding(8)
            switch listing {
            case nil:
                HStack { ProgressView().controlSize(.small); Text(localizer.text("remote.loading")) }.padding(8)
            case .failed(let message)?:
                Label(localizer.format("remote.failed", message), systemImage: "xmark.circle.fill").foregroundStyle(.red).padding(8)
            case .loaded(let folders)?:
                if folders.isEmpty {
                    Text(localizer.text("remote.empty")).foregroundStyle(.secondary).padding(8)
                }
                ForEach(folders, id: \.self) { folder in
                    Button { onOpen(folder) } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                            Text(folder).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Feuille de choix d'un dossier dans un service en ligne : on descend, on remonte, on peut ajouter un nouveau dossier au bout.
@MainActor
struct RemoteFolderPicker: View {
    let remote: String
    let startPath: String
    let localizer: Localizer
    let browse: (String, String) async -> FolderListing
    let onChoose: (String) -> Void
    let onCancel: () -> Void
    @State private var path = ""
    @State private var listing: FolderListing?
    @State private var newFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizer.format("remote.title", remote)).font(.title3.bold())
            HStack {
                Button { open(RemotePath.parent(path)) } label: { Label(localizer.text("copy.up"), systemImage: "arrow.up") }
                    .disabled(path.isEmpty)
                Spacer()
            }
            ScrollView {
                RemoteFolderListBody(remote: remote, path: path, listing: listing, localizer: localizer) { folder in
                    open(RemotePath.join(RemotePath.components(path) + [folder]))
                }
            }
            .frame(minHeight: 220)
            .background(.background)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            TextField(localizer.text("remote.newFolder"), text: $newFolder).textFieldStyle(.roundedBorder)
            HStack {
                Button(localizer.text("confirm.cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(localizer.text("remote.choose")) {
                    let extra = RemotePath.components(newFolder)
                    onChoose(RemotePath.join(RemotePath.components(path) + extra))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task(id: path) { listing = nil; listing = await browse(remote, path) }
        .onAppear { path = RemotePath.join(RemotePath.components(startPath)) }
    }

    private func open(_ next: String) {
        newFolder = ""
        path = next
    }
}
```

`EditorSteps.swift` :
- `EditorStepContent` : propriété `var remotes: RemoteContext = .none` (dernière, valeur par défaut : les appels existants compilent) ; `case .endpoints: EndpointsStepView(draft: $draft, localizer: text.localizer, remotes: remotes)`.
- `EndpointsStepView` : propriété `var remotes: RemoteContext = .none`, transmise aux deux `SideEditor`.
- `SideEditor` : propriété `var remotes: RemoteContext = .none` et `@State private var browsing = false` ; la branche service en ligne devient :

```swift
            } else {
                HStack {
                    Picker(localizer.text("editor.remote"), selection: $side.remote) {
                        if side.remote.isEmpty { Text(localizer.text("remote.pick")).tag("") }
                        ForEach(remotes.remotes) { remote in Text(remote.name).tag(remote.name) }
                        // Une connexion inconnue (supprimée, ou tapée avant 4) reste affichée telle quelle.
                        if !side.remote.isEmpty && !remotes.remotes.contains(where: { $0.name == side.remote }) {
                            Text(side.remote).tag(side.remote)
                        }
                    }
                    .frame(width: 220)
                    Button(localizer.text("remote.add"), action: remotes.onAdd)
                }
                HStack {
                    TextField(localizer.text("editor.path"), text: $side.path).textFieldStyle(.roundedBorder)
                    Button(localizer.text("editor.choose")) { browsing = true }.disabled(side.remote.isEmpty)
                }
                Text(localizer.text("editor.remote.help")).font(.caption).foregroundStyle(.secondary)
            }
```

et sur le `VStack` de `SideEditor` :

```swift
        .sheet(isPresented: $browsing) {
            RemoteFolderPicker(
                remote: side.remote, startPath: side.path, localizer: localizer, browse: remotes.browse,
                onChoose: { side.path = $0; browsing = false }, onCancel: { browsing = false }
            )
        }
```

`TaskEditorView.swift` : `@State private var wizard: WizardModel?` ; passer à `EditorStepContent` :

```swift
                    remotes: RemoteContext(
                        remotes: model.remotes,
                        onAdd: { wizard = WizardModel(model: model, localizer: localizer) },
                        browse: { remote, path in await model.remoteFolders(remote: remote, path: path) }
                    )
```

`.task { await model.reloadRemotes() }` et la feuille de l'assistant (comme dans `ConnectionsView`, avec `WizardSession`) qui, à la fermeture, recharge les connexions et sélectionne la nouvelle si un côté « service en ligne » est vide (choix : la destination d'abord, sinon la source).

`editor.remote.help` (existant) : remplacer le texte par « Choisissez une connexion (écran Connexions) puis le dossier ; un nom de dossier nouveau sera créé. » / « Pick a connection (Connections screen), then the folder; a new folder name will be created. ».

Chaînes `remote.*` fr :

```
"remote.loading" = "Lecture du dossier…";
"remote.failed" = "Lecture impossible : %@";
"remote.empty" = "Aucun sous-dossier";
"remote.title" = "Choisir un dossier dans « %@ »";
"remote.newFolder" = "Nouveau dossier au bout du chemin (facultatif)";
"remote.choose" = "Choisir ce dossier";
"remote.pick" = "Choisir…";
"remote.add" = "Ajouter une connexion…";
```

en :

```
"remote.loading" = "Reading the folder…";
"remote.failed" = "Can’t read: %@";
"remote.empty" = "No subfolders";
"remote.title" = "Choose a folder in “%@”";
"remote.newFolder" = "New folder at the end of the path (optional)";
"remote.choose" = "Choose this folder";
"remote.pick" = "Choose…";
"remote.add" = "Add a connection…";
```

- [ ] **Étape 3 : vérifier** — `swift test --filter "RemoteFolderPickerTests|EditorRenderTests|StringsCompletenessTests"` → passent ; suite complète verte.

- [ ] **Étape 4 : commit et push**

```bash
git add Sources Tests
git commit -m "Éditeur : connexion choisie dans la liste, dossier distant choisi en naviguant, ajout d'une connexion" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```

---

### Tâche 10 : essai réel et documentation

**Fichiers :** modifier `README.md`, `docs/manual-checks-ui.md`.

- [ ] **Étape 1 : essai réel** (agent de développement, **fichier de configuration rclone temporaire** pour ne jamais toucher au vrai) :

```bash
SYNCMACPRO_DEV_RCLONE_CONFIG="$SCRATCH/rclone-e2e.conf" SYNCMACPRO_RSYNC=… scripts/dev-launchd.sh install
```

1. `ctl remotes` → « Aucune connexion ».
2. Dans l'app (`SYNCMACPRO_AGENT_SERVICE=com.sylvain.syncmacpro.agent.dev .build/debug/SyncMacPro`) : écran Connexions vide ; Ajouter › Amazon S3 › clés factices › Créer → test en échec avec le message d'AWS (ou de réseau) → Corriger → la connexion disparaît (`ctl remotes`).
3. Créer à la main (`rclone config create Local alias remote=$SCRATCH/e2e --config $SCRATCH/rclone-e2e.conf`) : l'écran l'affiche ; Tester → répond ; créer une tâche « vers Local », choisir le dossier par le sélecteur ; Supprimer → refus « utilisée par » ; supprimer la tâche ; Supprimer → OK.
4. Assistant Dropbox jusqu'à « Terminez la connexion dans votre navigateur… » puis **Annuler sans se connecter** (le navigateur s'ouvre : fermer l'onglet) : `ctl remotes` ne montre rien.
5. Captures de la fenêtre seule (`screencapture -l`), supprimées ensuite.

Arrêter l'agent de développement et supprimer `$SCRATCH/rclone-e2e.conf`.

- [ ] **Étape 2 : documentation**

`README.md`, section « Connexions aux services (sous-projet 4) » : écran Connexions, assistant (Google Drive avec son propre identifiant ou l'identifiant partagé, Dropbox, OneDrive, S3 et compatibles), test, reconnexion, suppression protégée ; le fichier de configuration est celui de rclone (partagé avec la ligne de commande) ; les secrets y restent comme rclone les écrit (fichier privé de l'utilisateur, chiffrement prévu plus tard) ; `syncmacpro-ctl remotes`, `remote test|delete` ; option d'agent `--rclone-config` et `SYNCMACPRO_DEV_RCLONE_CONFIG` pour le développement.

`docs/manual-checks-ui.md`, section « Connexions (4) » :

```markdown
## Connexions (4)
- [ ] Google Drive avec son propre identifiant : guide, console, connexion dans le navigateur, test réussi ; une tâche vers Drive avec un dossier choisi s'exécute.
- [ ] Google Drive avec l'identifiant partagé : avertissement, connexion, test.
- [ ] Dropbox et OneDrive (choix du lecteur posé tel que rclone le formule).
- [ ] S3 : bonnes clés → test réussi ; mauvaises clés → échec clair, « Corriger » revient aux réglages.
- [ ] Annuler pendant l'attente du navigateur : la connexion n'apparaît pas.
- [ ] Reconnecter une connexion Drive (jeton expiré ou révoqué).
- [ ] Supprimer une connexion utilisée par une tâche : refus avec le nom de la tâche.
- [ ] Les connexions créées avec rclone en ligne de commande apparaissent et sont utilisables.
```

- [ ] **Étape 3 : vérifier** — suite complète verte.

- [ ] **Étape 4 : commit et push**

```bash
git add README.md docs/manual-checks-ui.md
git commit -m "Docs : connexions aux services, ctl remotes, vérifications manuelles" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push
```
