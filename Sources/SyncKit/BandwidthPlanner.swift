import Foundation

public enum BandwidthDirection: Equatable, Sendable { case download, upload, both, local }

/// Répartit les plafonds des réglages entre les exécutions en cours.
public enum BandwidthPlanner {
    /// Types de connexion rclone du réseau local : tout le reste passe par internet.
    static let localTypes: Set<String> = ["smb", "local", "alias"]

    static func isInternet(_ endpoint: Endpoint, _ remoteTypes: [String: String]) -> Bool {
        guard case .cloud(let remote, _) = endpoint else { return false }
        guard let type = remoteTypes[remote] else { return true }   // inconnu : on protège la connexion
        return !localTypes.contains(type)
    }

    public static func direction(of task: SyncTask, remoteTypes: [String: String]) -> BandwidthDirection {
        switch (isInternet(task.source, remoteTypes), isInternet(task.destination, remoteTypes)) {
        case (true, true): return .both
        case (true, false): return .download
        case (false, true): return .upload
        case (false, false): return .local
        }
    }

    /// Part de chaque exécution : les exécutions d'un même sens se partagent le plafond ; le plafond propre à une tâche
    /// (`bandwidthLimitKBps`, Kio/s) reste appliqué s'il est plus bas.
    public static func rates(
        for running: [(id: UUID, task: SyncTask)], limits: BandwidthLimits, remoteTypes: [String: String]
    ) -> [UUID: BandwidthRate] {
        let directions = running.map { (id: $0.id, task: $0.task, direction: direction(of: $0.task, remoteTypes: remoteTypes)) }
        func share(_ mbps: Double?, among count: Int) -> Int64? {
            guard let mbps, mbps > 0, count > 0 else { return nil }
            return BandwidthRate.bytesPerSecond(mbps: mbps) / Int64(count)
        }
        let downloaders = directions.filter { $0.direction == .download || $0.direction == .both }.count
        let uploaders = directions.filter { $0.direction == .upload || $0.direction == .both }.count
        let locals = directions.filter { $0.direction == .local }.count
        var result: [UUID: BandwidthRate] = [:]
        for entry in directions {
            var rate = BandwidthRate.unlimited
            switch entry.direction {
            case .download: rate.downBytesPerSecond = share(limits.downloadMbps, among: downloaders)
            case .upload: rate.upBytesPerSecond = share(limits.uploadMbps, among: uploaders)
            case .both:
                rate.downBytesPerSecond = share(limits.downloadMbps, among: downloaders)
                rate.upBytesPerSecond = share(limits.uploadMbps, among: uploaders)
            case .local:
                let cap = share(limits.localMbps, among: locals)
                rate = BandwidthRate(upBytesPerSecond: cap, downBytesPerSecond: cap)
            }
            if let kbps = entry.task.options.bandwidthLimitKBps, kbps > 0 {
                let own = Int64(kbps) * 1024
                rate.upBytesPerSecond = min(rate.upBytesPerSecond ?? own, own)
                rate.downBytesPerSecond = min(rate.downBytesPerSecond ?? own, own)
            }
            result[entry.id] = rate
        }
        return result
    }
}
