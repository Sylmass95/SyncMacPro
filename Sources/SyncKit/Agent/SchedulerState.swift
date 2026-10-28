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
    /// Disque amovible : exécution suspendue (disque débranché) et dernier branchement déjà traité.
    public var suspendedRun: SuspendedRun?
    public var lastMountHandled: Date?
    /// Début de l'attente d'un partage réseau injoignable (1.6.5).
    public var shareWaitSince: Date?
    /// Disque amovible : une exécution coupée par un redémarrage de l'agent, ou demandée pendant l'attente d'une mise à
    /// jour, repart sans attendre un nouveau branchement (1.7.4).
    public var manualRunPending: Bool?

    public init(firstSeen: Date) { self.firstSeen = firstSeen }
}

public struct SchedulerState: Codable, Equatable, Sendable {
    public var paused: Bool = false
    public var lastPurge: Date?
    /// Clé : identifiant de la tâche (`UUID.uuidString`).
    public var tasks: [String: TaskScheduleState] = [:]
    /// File d'attente explicite (1.3.0) et son état (lancée ou suspendue).
    public var userQueue: [UUID] = []
    public var userQueueRunning: Bool = false
    /// Élément de la file en cours : enregistré pour qu'après un redémarrage le suivant attende sa reprise.
    public var userQueueCurrent: UUID?
    /// Ordre de la liste (1.7.0) : l'ordre de départ des tâches. Les anciens champs de file ne servent plus qu'à la
    /// migration.
    public var order: [UUID] = []
    /// Envois récents par compte en ligne (1.8.8) : le quota vaut pour 24 h et pour toutes les tâches du compte.
    public var cloudAccounts: [String: CloudAccountState] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case paused, lastPurge, tasks, userQueue, userQueueRunning, userQueueCurrent, order, cloudAccounts
    }

    /// Un état d'avant 1.3.0 (sans file) se lit tel quel.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        lastPurge = try c.decodeIfPresent(Date.self, forKey: .lastPurge)
        tasks = try c.decodeIfPresent([String: TaskScheduleState].self, forKey: .tasks) ?? [:]
        userQueue = try c.decodeIfPresent([UUID].self, forKey: .userQueue) ?? []
        userQueueRunning = try c.decodeIfPresent(Bool.self, forKey: .userQueueRunning) ?? false
        userQueueCurrent = try c.decodeIfPresent(UUID.self, forKey: .userQueueCurrent)
        order = try c.decodeIfPresent([UUID].self, forKey: .order) ?? []
        cloudAccounts = try c.decodeIfPresent([String: CloudAccountState].self, forKey: .cloudAccounts) ?? [:]
    }
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
