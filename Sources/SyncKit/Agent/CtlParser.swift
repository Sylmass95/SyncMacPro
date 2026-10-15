import Foundation

public struct NewTask: Equatable, Sendable {
    public var name: String
    public var source: Endpoint
    public var destination: Endpoint
    public var mode: SyncMode
    public var schedule: Schedule
    public var requiresACPower: Bool
}

/// Une copie ponctuelle demandée en ligne de commande.
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

public enum CtlCommand: Equatable, Sendable {
    case status, list, watch, help
    case run(String), pause(String), resume(String), stop(String), approve(String), remove(String)
    case simulate(String), log(String)
    case pauseAll, resumeAll
    case history(String?, limit: Int)
    /// Vider l'historique, tout ou celui d'une tâche.
    case clearHistory(String?)
    case add(NewTask)
    case copy(OneOffRequest)
    case remotes, remoteTest(String), remoteDelete(String)
    case version, doctor
    /// File d'attente explicite et plafonds de débit (1.3.0).
    case queue, queueAdd(String), queueRemove(String), queueMove(String, up: Bool), queueRun(Bool)
    case bandwidth, setBandwidth(down: String?, up: String?, local: String?)
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
      history [<tâche>] --clear      vide l'historique (tout, ou celui d'une tâche) et ses journaux
      watch                          avancement en direct
      add --name N --source P --dest P [--mode copy|mirror|bidirectional|move|versioned|verify]
          [--every MINUTES | --daily HH:MM] [--ac-power]
      remove <tâche>
      remotes                        connexions rclone (services en ligne)
      version                        version de SyncMacPro
      doctor                         rsync et rclone retenus, état de l'agent
      remote test | delete <nom>     tester ou supprimer une connexion
      copy --source DOSSIER --dest DOSSIER [--item NOM]... [--mirror]
                                     copie ponctuelle par l'agent (sans créer de tâche)
      simulate <tâche>               ce que ferait la tâche, sans rien modifier
      log <tâche>                    journal de la dernière exécution
      queue                          file d'attente (ordre, état)
      queue add | remove | up | down <tâche>
      queue start | stop             lancer ou suspendre la file
      bandwidth                      plafonds de débit (Mbit/s, comme speedtest)
      bandwidth [--down N] [--up N] [--local N]
                                     réception internet, envoi internet, réseau local ; « off » pour retirer
      agent install | uninstall | status

    Options : --json   --state-dir DOSSIER   --service NOM
    Une tâche se désigne par son nom (ou un début de nom) ou par son identifiant.
    """

    private static let aliases: [String: String] = [
        "statut": "status", "liste": "list", "lancer": "run", "reprendre": "resume", "arreter": "stop",
        "arrêter": "stop", "historique": "history", "valider": "approve", "pause-tout": "pause-all",
        "reprendre-tout": "resume-all", "ajouter": "add", "supprimer": "remove", "aide": "help",
        "simuler": "simulate", "journal": "log", "copier": "copy", "connexions": "remotes", "diagnostic": "doctor",
        "file": "queue", "debit": "bandwidth", "débit": "bandwidth",
    ]

    private static let valued: Set<String> = [
        "state-dir", "service", "name", "source", "dest", "mode", "every", "daily", "limit", "item", "down", "up", "local",
    ]
    private static let flags: Set<String> = ["json", "ac-power", "help", "mirror", "clear"]

    public static func parse(_ arguments: [String]) throws -> CtlInvocation {
        if arguments == ["--version"] {
            return CtlInvocation(command: .version, json: false, stateDirectory: nil, service: nil)
        }
        var json = false
        var stateDirectory: String?
        var service: String?
        var positional: [String] = []
        var values: [String: String] = [:]
        var flagged: Set<String> = []
        var items: [String] = []

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
                if name == "item" { items.append(arguments[index]) } else { values[name] = arguments[index] }
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
        case "simulate": return invocation(.simulate(try single()))
        case "log": return invocation(.log(try single()))
        case "history":
            if flagged.contains("clear") { return invocation(.clearHistory(rest.first)) }
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
        case "remotes": return invocation(.remotes)
        case "version": return invocation(.version)
        case "doctor": return invocation(.doctor)
        case "remote":
            guard rest.count >= 2 else { throw CtlParseError.invalid("remote attend : test NOM ou delete NOM") }
            let target = rest.dropFirst().joined(separator: " ")
            switch rest[0] {
            case "test": return invocation(.remoteTest(target))
            case "delete": return invocation(.remoteDelete(target))
            default: throw CtlParseError.invalid("remote attend : test NOM ou delete NOM")
            }
        case "copy":
            guard let source = values["source"] else { throw CtlParseError.missingValue("--source") }
            guard let destination = values["dest"] else { throw CtlParseError.missingValue("--dest") }
            return invocation(.copy(OneOffRequest(
                source: (source as NSString).expandingTildeInPath,
                destination: (destination as NSString).expandingTildeInPath,
                items: items, mirror: flagged.contains("mirror")
            )))
        case "queue":
            guard let action = rest.first else { return invocation(.queue) }
            let target = rest.dropFirst().joined(separator: " ")
            switch action {
            case "start": return invocation(.queueRun(true))
            case "stop": return invocation(.queueRun(false))
            case "add", "remove", "up", "down":
                guard !target.isEmpty else { throw CtlParseError.missingValue("tâche") }
                switch action {
                case "add": return invocation(.queueAdd(target))
                case "remove": return invocation(.queueRemove(target))
                default: return invocation(.queueMove(target, up: action == "up"))
                }
            default: throw CtlParseError.invalid("queue attend : add, remove, up, down, start ou stop")
            }
        case "bandwidth":
            if values["down"] == nil && values["up"] == nil && values["local"] == nil { return invocation(.bandwidth) }
            return invocation(.setBandwidth(down: values["down"], up: values["up"], local: values["local"]))
        default: throw CtlParseError.unknownCommand(first)
        }
    }

    /// « 200 », « 12,5 » ou « off » (sans plafond), en Mbit/s.
    public static func mbps(_ text: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "off" || trimmed == "aucun" { return nil }
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")), value > 0 else {
            throw CtlParseError.invalid("Débit attendu en Mbit/s (nombre positif) ou « off » : \(text)")
        }
        return value
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
