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
