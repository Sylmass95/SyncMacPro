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
    func simulate(_ task: SyncTask) async throws -> SimulationResult
    func runLog(runID: UUID) async throws -> RunLogText
    /// 1.8.2 : détails d'une exécution (fichiers copiés, supprimés…).
    func runDetails(runID: UUID) async throws -> RunDetails
    func listRemotes() async throws -> [RemoteInfo]
    func configureRemote(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome
    func testRemote(_ name: String) async throws -> RemoteTestResult
    func remoteFolders(remote: String, path: String) async throws -> [String]
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

    public func runLog(runID: UUID) async throws -> RunLogText {
        try await runLog(runID: runID, maxBytes: 262_144)
    }

    /// Au plus 200 000 lignes (une très grosse exécution) ; les totaux comptent tout.
    public func runDetails(runID: UUID) async throws -> RunDetails {
        try await runDetails(runID: runID, maxRows: 200_000)
    }
}

/// Agent absent : tout échoue comme un agent injoignable. Sert aux aperçus et aux captures.
public struct UnavailableAgent: AgentConnecting {
    public init() {}
    public func status() async throws -> AgentStatus { throw AgentClientError.unreachable }
    public func listTasks() async throws -> [SyncTask] { throw AgentClientError.unreachable }
    public func history(taskID: UUID?, limit: Int) async throws -> [RunRecord] { throw AgentClientError.unreachable }
    public func perform(_ request: AgentRequest) async throws { throw AgentClientError.unreachable }
    public func simulate(_ task: SyncTask) async throws -> SimulationResult { throw AgentClientError.unreachable }
    public func runLog(runID: UUID) async throws -> RunLogText { throw AgentClientError.unreachable }
    public func runDetails(runID: UUID) async throws -> RunDetails { throw AgentClientError.unreachable }
    public func listRemotes() async throws -> [RemoteInfo] { throw AgentClientError.unreachable }
    public func configureRemote(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome { throw AgentClientError.unreachable }
    public func testRemote(_ name: String) async throws -> RemoteTestResult { throw AgentClientError.unreachable }
    public func remoteFolders(remote: String, path: String) async throws -> [String] { throw AgentClientError.unreachable }
    public func startWatching(
        onEvent: @escaping @Sendable (AgentEvent) -> Void, onEnd: @escaping @Sendable () -> Void
    ) async throws -> any AgentWatching { throw AgentClientError.unreachable }
}

public enum SimulationOutcome: Equatable, Sendable {
    case finished(SimulationResult)
    case failed(String)
}

public enum LogOutcome: Equatable, Sendable {
    case loaded(RunLogText)
    /// Exécution antérieure au journal, ou fichier purgé.
    case missing
    case failed(String)
}

public enum RemoteStepResult: Equatable, Sendable {
    case question(RemoteQuestion)
    case done
    case failed(String)
}

public enum FolderListing: Equatable, Sendable {
    case loaded([String])
    case failed(String)
}
