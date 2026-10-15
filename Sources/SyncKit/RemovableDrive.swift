import Foundation

/// Destination sur un disque externe qu'on ne laisse pas branché (1.4.0) : reconnu par l'identifiant de son volume,
/// la sauvegarde part quand il est branché, se suspend s'il est débranché et reprend s'il revient à temps.
public struct RemovableDrive: Codable, Equatable, Hashable, Sendable {
    public enum Trigger: Codable, Equatable, Hashable, Sendable {
        /// À chaque branchement.
        case everyConnection
        /// Au branchement, si la dernière réussite a plus de N jours.
        case atMostEveryDays(Int)
    }

    public enum Eject: String, Codable, Equatable, Hashable, Sendable {
        /// Notification « vous pouvez éjecter » seulement.
        case never
        /// Bouton « Éjecter » (carte, miniature, barre de menus).
        case button
        /// Éjection à la fin d'une réussite.
        case automatic
    }

    public var volumeUUID: String
    public var volumeName: String
    /// Dossier de destination relatif à la racine du volume (« Sauvegardes/Photos »), sans « / » initial.
    public var relativePath: String
    public var trigger: Trigger
    /// Rebranché dans ce délai, l'exécution suspendue continue ; au-delà, une nouvelle part (1 à 30 jours).
    public var resumeWindowDays: Int
    public var eject: Eject

    public init(
        volumeUUID: String, volumeName: String, relativePath: String, trigger: Trigger = .everyConnection,
        resumeWindowDays: Int = 3, eject: Eject = .never
    ) {
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.relativePath = relativePath
        self.trigger = trigger
        self.resumeWindowDays = resumeWindowDays
        self.eject = eject
    }

    /// Le dossier de destination sur le volume monté à `mountPath` (qui peut changer : « Extreme Pro 1 »…).
    public func destinationPath(mountPath: String) -> String {
        let relative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? mountPath : Endpoint.join(mountPath, relative)
    }
}

/// Exécution suspendue parce que le disque a été débranché : reprise sous la même ligne d'historique.
public struct SuspendedRun: Codable, Equatable, Sendable {
    public var recordID: UUID
    public var since: Date
    /// Ce qui a déjà été fait : additionné au bilan de la reprise.
    public var summary: RunSummary

    public init(recordID: UUID, since: Date, summary: RunSummary) {
        self.recordID = recordID
        self.since = since
        self.summary = summary
    }
}
