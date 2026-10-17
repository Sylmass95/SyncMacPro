import Foundation
import SyncKit

/// Quand installer une mise à jour, quand réinscrire l'agent, quand annoncer la nouvelle version (logique pure).
public enum UpdatePolicy {
    /// Rien à couper : aucune exécution en cours, en pause ou en attente de départ, file arrêtée ou vide.
    /// Agent injoignable : rien ne tourne (et l'installation ne doit pas rester bloquée pour autant).
    public static func agentIsIdle(connected: Bool, status: AgentStatus?) -> Bool {
        guard connected, let status else { return true }
        // Programme remplacé (1.6.7) : l'agent ne lance plus rien ; seules ses copies en cours le retiennent.
        if status.restartPending == true {
            return !status.tasks.contains { if case .running = $0.state { return true }; if case .paused = $0.state { return true }; return false }
        }
        for task in status.tasks {
            switch task.state {
            case .running, .paused, .queued: return false
            case .idle, .waiting, .awaitingApproval, .disabled: break
            }
        }
        if let queue = status.queue, queue.running, !queue.items.isEmpty || queue.current != nil { return false }
        return true
    }

    /// `nil` tant que l'agent n'a pas répondu (lancement, reconnexion) : on attend avant de décider.
    public static func agentIdleness(connection: ConnectionState, status: AgentStatus?) -> Bool? {
        switch connection {
        case .connecting, .reconnecting: return nil
        case .connected: return agentIsIdle(connected: true, status: status)
        case .unreachable, .versionMismatch: return true
        }
    }

    public static func shouldInstall(ready: Bool, autoInstall: Bool, idle: Bool) -> Bool {
        ready && autoInstall && idle
    }

    /// Une version plus récente que celle du lancement précédent (pas à la première installation).
    public static func shouldNotifyUpdated(previous: String?, current: String) -> Bool {
        guard let previous, let old = SemanticVersion(previous), let new = SemanticVersion(current) else { return false }
        return old < new
    }
}
