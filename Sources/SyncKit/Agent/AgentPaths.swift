import Foundation

/// Où l'agent range ses données.
public struct AgentPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var tasks: URL { root.appendingPathComponent("tasks.json") }
    public var state: URL { root.appendingPathComponent("scheduler-state.json") }
    public var history: URL { root.appendingPathComponent("history.sqlite") }
    /// Dossier d'état propre aux tâches (bisync y garde ses listes).
    public var work: URL { root.appendingPathComponent("work") }
    /// Un journal par exécution.
    public var logs: URL { root.appendingPathComponent("logs") }

    private static func support(_ name: String) -> AgentPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AgentPaths(root: base.appendingPathComponent(name))
    }

    public static var standard: AgentPaths { support("SyncMacPro") }
    /// Pour le développement : ne touche pas aux données réelles.
    public static var development: AgentPaths { support("SyncMacPro-dev") }
}
