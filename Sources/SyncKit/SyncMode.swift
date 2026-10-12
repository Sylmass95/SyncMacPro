import Foundation

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    /// Ajoute ce qui est nouveau ou modifié, ne supprime jamais.
    case copy
    /// La destination devient identique ; ce qui est supprimé ou écrasé est archivé.
    case mirror
    /// Les deux côtés restent à jour, suppressions comprises (rclone bisync).
    case bidirectional
    /// Copie puis supprime la source.
    case move
    /// Garde l'historique des anciennes versions pendant N jours.
    case versioned
    /// Compare sans rien modifier.
    case verify

    /// Vrai si le mode peut supprimer des fichiers (garde-fous obligatoires).
    public var deletesData: Bool {
        switch self {
        case .mirror, .bidirectional, .move: return true
        case .copy, .versioned, .verify: return false
        }
    }

    /// Vrai si seul rclone sait faire ce mode.
    public var requiresRclone: Bool {
        self == .bidirectional || self == .versioned
    }
}
