import Foundation

/// Numéro du contrat XPC. À incrémenter quand un message change de forme.
public let agentProtocolVersion = 4

public enum AgentIdentifiers {
    /// Nom du service Mach déclaré dans le plist de l'agent.
    public static let machService = "com.sylvain.syncmacpro.agent"
    public static let launchdLabel = machService
    public static let bundleIdentifier = "com.sylvain.syncmacpro"

    /// Le service à joindre : `SYNCMACPRO_AGENT_SERVICE` permet d'ouvrir l'app sur l'agent de développement.
    public static func service(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard let name = environment["SYNCMACPRO_AGENT_SERVICE"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty
        else { return machService }
        return name
    }
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
    case saveTask(SyncTask)
    case removeTask(UUID)
    case simulate(SyncTask)
    case cancelSimulation(UUID)
    case runLog(runID: UUID, maxBytes: Int)
    /// Exécution ponctuelle (copie manuelle), sans enregistrer la tâche.
    case runOnce(SyncTask)
    // Connexions rclone (contrat 4)
    case listRemotes
    case configureRemote(RemoteConfigStep)
    case cancelRemoteConfiguration(String)
    case deleteRemote(String)
    case testRemote(String)
    case listRemoteFolders(remote: String, path: String)
    /// Vider l'historique, tout (`nil`) ou celui d'une tâche (1.2.4 : ajout, aucun message existant ne change).
    case clearHistory(taskID: UUID?)
    // File d'attente explicite et plafonds de débit (1.3.0 : ajouts, aucun message existant ne change)
    case enqueue(UUID)
    case enqueueOnce(SyncTask)
    case dequeue(UUID)
    case moveInQueue(UUID, to: Int)
    case setQueueRunning(Bool)
    case setBandwidth(BandwidthLimits)
    // Disque amovible (1.4.0 : ajouts)
    case abandonSuspended(UUID)
    case ejectDrive(UUID)
    /// 1.6.4 : lister les dossiers des tâches (demandes d'autorisation de macOS après une mise à jour).
    case checkAccess
}

public enum AgentResponse: Codable, Equatable, Sendable {
    case ok
    case status(AgentStatus)
    case tasks([SyncTask])
    case history([RunRecord])
    case error(AgentError)
    case simulation(SimulationResult)
    case log(RunLogText)
    case remotes([RemoteInfo])
    case remoteConfig(RemoteConfigOutcome)
    case remoteTest(RemoteTestResult)
    case folders([String])
    /// Nombre d'exécutions supprimées de l'historique.
    case cleared(Int)
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
