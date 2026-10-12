import Foundation

public struct RcloneTransferring: Equatable, Sendable {
    public var name: String
    public var size: Int64
    public var bytes: Int64
    public var percentage: Int
    public var speed: Double
}

public struct RcloneStats: Equatable, Sendable {
    public var bytes: Int64
    public var totalBytes: Int64
    public var speed: Double
    public var eta: Double?
    public var transfers: Int
    public var totalTransfers: Int
    public var checks: Int
    public var deletes: Int
    public var errors: Int
    public var elapsedTime: Double
    public var fatalError: Bool
    public var transferring: [RcloneTransferring]
}

public enum RcloneEvent: Equatable, Sendable {
    case stats(RcloneStats)
    case notice(message: String, object: String?)
    case error(String)
}

public enum RcloneOutputParser {
    private struct Line: Decodable {
        var level: String?
        var msg: String?
        var object: String?
        var stats: Stats?
    }

    private struct Stats: Decodable {
        var bytes: Int64?
        var totalBytes: Int64?
        var speed: Double?
        var eta: Double?
        var transfers: Int?
        var totalTransfers: Int?
        var checks: Int?
        var deletes: Int?
        var errors: Int?
        var elapsedTime: Double?
        var fatalError: Bool?
        var transferring: [Transferring]?
    }

    private struct Transferring: Decodable {
        var name: String?
        var size: Int64?
        var bytes: Int64?
        var percentage: Int?
        var speed: Double?
    }

    /// Interprète une ligne du journal JSON de rclone (`--use-json-log`). `nil` pour une ligne ignorée.
    public static func parse(line: String) -> RcloneEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Line.self, from: data) else { return nil }

        if let stats = decoded.stats {
            return .stats(RcloneStats(
                bytes: stats.bytes ?? 0, totalBytes: stats.totalBytes ?? 0, speed: stats.speed ?? 0, eta: stats.eta,
                transfers: stats.transfers ?? 0, totalTransfers: stats.totalTransfers ?? 0,
                checks: stats.checks ?? 0, deletes: stats.deletes ?? 0, errors: stats.errors ?? 0,
                elapsedTime: stats.elapsedTime ?? 0, fatalError: stats.fatalError ?? false,
                transferring: (stats.transferring ?? []).map {
                    RcloneTransferring(
                        name: $0.name ?? "", size: $0.size ?? 0, bytes: $0.bytes ?? 0,
                        percentage: $0.percentage ?? 0, speed: $0.speed ?? 0
                    )
                }
            ))
        }
        let message = decoded.msg ?? ""
        switch decoded.level {
        case "error", "critical", "alert", "emergency": return .error(message)
        default: return message.isEmpty ? nil : .notice(message: message, object: decoded.object)
        }
    }
}

/// Situations importantes repérées dans la sortie d'un moteur.
public enum OutputSignal: Equatable, Sendable {
    /// Trop de suppressions : le moteur a refusé d'agir.
    case safetyAbort
    /// bisync demande une initialisation (`--resync`).
    case needsResync
    /// Le quota de transfert (`--max-transfer`) est atteint.
    case quotaReached

    public static func detect(in text: String) -> OutputSignal? {
        let lower = text.lowercased()
        if lower.contains("safety abort") || lower.contains("too many deletes") { return .safetyAbort }
        if lower.contains("must run --resync") { return .needsResync }
        if lower.contains("max transfer limit reached") { return .quotaReached }
        return nil
    }
}
