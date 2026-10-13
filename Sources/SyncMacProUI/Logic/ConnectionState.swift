import Foundation

/// Où en est la connexion de l'app avec l'agent.
public enum ConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting(attempt: Int)
    /// L'agent ne répond pas et n'a jamais répondu pendant cette session (non installé, ou arrêté).
    case unreachable
    case versionMismatch(agent: Int)
}
