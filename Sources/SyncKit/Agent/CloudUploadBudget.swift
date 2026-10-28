import Foundation

/// Un envoi vers un service en ligne : octets envoyés par une exécution, datés de sa fin.
public struct CloudUpload: Codable, Equatable, Sendable {
    public var at: Date
    public var bytes: Int64

    public init(at: Date, bytes: Int64) {
        self.at = at
        self.bytes = bytes
    }
}

/// Ce que l'agent retient d'un compte en ligne (1.8.8) : ses envois des dernières 24 h et le dernier refus du service.
public struct CloudAccountState: Codable, Equatable, Sendable {
    public var uploads: [CloudUpload] = []
    /// Le service a refusé les envois (quota du jour atteint) : rien ne part avant cette date. Gardé après l'échéance
    /// pour savoir qu'un nouveau refus n'est qu'une répétition (pas de deuxième notification).
    public var blockedUntil: Date?

    public init() {}
}

/// Google Drive n'accepte qu'environ 750 Go envoyés par 24 h et par compte, toutes copies confondues. Le quota d'une
/// tâche (`maxTransferGB`) vaut donc pour 24 h glissantes et pour toutes les tâches qui envoient vers le même compte.
public enum CloudUploadBudget {
    public static let window: TimeInterval = 86_400
    static let gib: Int64 = 1 << 30   // `--max-transfer 700G` : des Gio pour rclone

    /// Compte qui reçoit les envois d'une tâche : le nom du remote sans ses paramètres (`Drive,team_drive=…` → `Drive`).
    /// `nil` sans quota choisi, pour une vérification ou une copie qui n'envoie rien vers un service en ligne.
    public static func account(for task: SyncTask) -> String? {
        guard task.options.maxTransferGB != nil, task.mode != .verify else { return nil }
        let target: Endpoint
        if task.destination.isCloud {
            target = task.destination
        } else if task.mode == .bidirectional, task.source.isCloud {
            target = task.source
        } else {
            return nil
        }
        guard case .cloud(let remote, _) = target else { return nil }
        return String(remote.split(separator: ",", maxSplits: 1).first ?? Substring(remote))
    }

    /// Envois encore dans la fenêtre de 24 h.
    public static func recent(_ account: CloudAccountState, now: Date) -> [CloudUpload] {
        account.uploads.filter { now.timeIntervalSince($0.at) < window }
    }

    /// Gio que le compte peut encore recevoir (0 si le service refuse les envois).
    public static func remainingGB(quotaGB: Int, account: CloudAccountState, inFlight: Int64, now: Date) -> Int {
        if let blocked = account.blockedUntil, blocked > now { return 0 }
        let used = recent(account, now: now).reduce(inFlight) { $0 + $1.bytes }
        return max(0, Int((Int64(quotaGB) * gib - used) / gib))
    }

    /// Date à laquelle le compte peut de nouveau recevoir au moins 1 Gio ; `nil` s'il le peut déjà.
    public static func freeAt(quotaGB: Int, account: CloudAccountState, inFlight: Int64, now: Date) -> Date? {
        if let blocked = account.blockedUntil, blocked > now { return blocked }
        guard remainingGB(quotaGB: quotaGB, account: account, inFlight: inFlight, now: now) < 1 else { return nil }
        let limit = Int64(quotaGB - 1) * gib - inFlight
        var used = recent(account, now: now).reduce(0) { $0 + $1.bytes }
        for upload in recent(account, now: now).sorted(by: { $0.at < $1.at }) {
            used -= upload.bytes
            if used <= limit { return upload.at.addingTimeInterval(window) }
        }
        return now.addingTimeInterval(window)   // la copie en cours suffit à épuiser le compte
    }
}
