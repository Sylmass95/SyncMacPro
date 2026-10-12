import Foundation

public enum EngineSelectionError: Error, Equatable {
    /// Le moteur demandé ne sait pas faire ce mode.
    case unsupportedMode(mode: SyncMode, engine: EngineKind)
    /// rsync ne sait pas parler à un service en ligne.
    case cloudRequiresRclone
}

public enum EngineSelector {
    /// Choisit rsync ou rclone pour une tâche.
    /// - rclone si un côté est un service en ligne, ou si le mode n'existe que dans rclone ;
    /// - sinon rsync, sauf si l'utilisateur force rclone ;
    /// - forcer rsync sur un cas qu'il ne gère pas est une erreur explicite.
    public static func engine(for task: SyncTask) throws -> EngineKind {
        let touchesCloud = task.source.isCloud || task.destination.isCloud

        if let forced = task.options.forcedEngine {
            if forced == .rsync {
                if touchesCloud { throw EngineSelectionError.cloudRequiresRclone }
                if task.mode.requiresRclone {
                    throw EngineSelectionError.unsupportedMode(mode: task.mode, engine: .rsync)
                }
            }
            return forced
        }
        if touchesCloud || task.mode.requiresRclone { return .rclone }
        return .rsync
    }
}
