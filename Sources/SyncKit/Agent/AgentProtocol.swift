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
