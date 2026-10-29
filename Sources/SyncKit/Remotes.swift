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
    /// rclone a refusé la réponse précédente et repose la question avec ce message.
    public var error: String?

    public init(
        state: String, option: String, help: String = "", kind: String = "string", defaultValue: String = "",
        choices: [RemoteChoice] = [], exclusive: Bool = false, required: Bool = false, isPassword: Bool = false,
        error: String? = nil
    ) {
        self.error = error
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
    /// Une lecture (test, liste, dossiers) sans réponse : service lent ou injoignable.
    case noAnswer
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .rclone(let message): return message
        case .unreadable: return "Réponse de rclone illisible."
        case .timedOut: return "rclone n'a pas répondu à temps (connexion dans le navigateur non terminée ?)."
        case .noAnswer: return "Le service n'a pas répondu à temps (lent ou injoignable) : réessayez."
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
        let error = reply.Error.flatMap { $0.isEmpty ? nil : $0 }
        guard let option = reply.Option, let name = option.Name else {
            if let error { throw RemoteConfigError.rclone(error) }
            return .done
        }
        return .question(RemoteQuestion(
            state: reply.State ?? "", option: name, help: option.Help ?? "", kind: option.Type ?? "string",
            defaultValue: option.DefaultStr ?? "",
            choices: (option.Examples ?? []).compactMap { example in
                example.Value.map { RemoteChoice(value: $0, help: example.Help ?? "") }
            },
            exclusive: option.Exclusive ?? false, required: option.Required ?? false, isPassword: option.IsPassword ?? false,
            error: error
        ))
    }

    public static func remotes(from data: Data) throws -> [RemoteInfo] {
        struct Entry: Decodable { var name: String; var type: String? }
        // Sans fichier de configuration, rclone n'écrit rien : aucune connexion.
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
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

    /// Un nom que rclone accepte (1.8.11 : « NAS (SMB direct) » était refusé) : caractères refusés retirés, espaces
    /// resserrés, ni « - » ni espace au début, numéroté s'il est déjà pris.
    public static func suggestion(_ name: String, existing: [String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.+@ "))
        let kept = String(String.UnicodeScalarView(name.unicodeScalars.filter { allowed.contains($0) }))
        var base = kept.split(separator: " ").joined(separator: " ")
        while base.hasPrefix("-") { base.removeFirst() }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Connexion" }
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
