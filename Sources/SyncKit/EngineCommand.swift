import Foundation

public enum CommandError: Error, Equatable {
    case unsupportedMode(mode: SyncMode, engine: EngineKind)
    /// rsync a besoin de deux chemins sur le disque (dossier local ou volume monté).
    case missingFilesystemPath
}

/// Paramètres propres à une exécution (et non à la tâche).
public struct RunOptions: Equatable, Sendable {
    /// Simulation : rien n'est copié ni supprimé.
    public var dryRun: Bool
    /// Sous-dossier daté de l'archive, par exemple « 2026-10-12_14-30 ».
    public var archiveStamp: String
    /// bisync : initialisation (première exécution ou reprise après un échec grave).
    public var resync: Bool
    /// bisync : dossier d'état propre à la tâche.
    public var bisyncWorkdir: String?
    /// Fichier de configuration rclone à utiliser (`--config`).
    public var rcloneConfigPath: String?
    /// rclone : nombre maximum de suppressions autorisées pour cette exécution.
    public var maxDeleteCount: Int?
    /// bisync : liens courts vers chaque côté sur le disque (bisync nomme ses fichiers d'état d'après les chemins).
    public var bisyncPath1: String?
    public var bisyncPath2: String?
    /// Limite de débit de l'exécution (plafonds des réglages) ; `nil` : celle de la tâche.
    public var bandwidth: BandwidthRate?
    /// rclone : prise Unix de son contrôle à distance (limite modifiable en route).
    public var rcSocketPath: String?

    public init(
        dryRun: Bool = false,
        archiveStamp: String,
        resync: Bool = false,
        bisyncWorkdir: String? = nil,
        rcloneConfigPath: String? = nil,
        maxDeleteCount: Int? = nil
    ) {
        self.dryRun = dryRun
        self.archiveStamp = archiveStamp
        self.resync = resync
        self.bisyncWorkdir = bisyncWorkdir
        self.rcloneConfigPath = rcloneConfigPath
        self.maxDeleteCount = maxDeleteCount
    }
}

/// Un moteur et ses arguments ; le chemin de l'exécutable est résolu plus tard.
public struct EngineCommand: Equatable, Sendable {
    public let engine: EngineKind
    public let arguments: [String]

    public init(engine: EngineKind, arguments: [String]) {
        self.engine = engine
        self.arguments = arguments
    }
}

enum PathText {
    static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    static func withoutTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
