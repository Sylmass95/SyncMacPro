import Foundation
import SyncKit

/// Quand installer une mise à jour, quand réinscrire l'agent, quand annoncer la nouvelle version (logique pure).
public enum UpdatePolicy {
    /// Rien à couper : aucune exécution en cours, en pause ou en attente de départ, file arrêtée ou vide.
    /// Agent injoignable : rien ne tourne (et l'installation ne doit pas rester bloquée pour autant).
    public static func agentIsIdle(connected: Bool, status: AgentStatus?) -> Bool {
        guard connected, let status else { return true }
        for task in status.tasks {
            switch task.state {
            case .running, .paused, .queued: return false
            case .idle, .waiting, .awaitingApproval, .disabled: break
            }
        }
        if let queue = status.queue, queue.running, !queue.items.isEmpty || queue.current != nil { return false }
        return true
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
