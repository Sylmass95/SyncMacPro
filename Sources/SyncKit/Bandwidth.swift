import Foundation

/// Plafonds de débit des réglages, en Mbit/s (l'unité de speedtest : 1 Mbit/s = 1 000 000 bit/s). `nil` : pas de plafond.
public struct BandwidthLimits: Codable, Equatable, Sendable {
    /// Réception depuis internet (source sur un service en ligne).
    public var downloadMbps: Double?
    /// Envoi vers internet (destination sur un service en ligne).
    public var uploadMbps: Double?
    /// Copies entre disques et NAS du réseau local.
    public var localMbps: Double?

    public init(downloadMbps: Double? = nil, uploadMbps: Double? = nil, localMbps: Double? = nil) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.localMbps = localMbps
    }
}

/// Limite appliquée à une exécution, en octets par seconde ; `nil` d'un côté : sans limite.
public struct BandwidthRate: Equatable, Sendable {
    public var upBytesPerSecond: Int64?
    public var downBytesPerSecond: Int64?

    public init(upBytesPerSecond: Int64? = nil, downBytesPerSecond: Int64? = nil) {
        self.upBytesPerSecond = upBytesPerSecond
        self.downBytesPerSecond = downBytesPerSecond
    }

    public static let unlimited = BandwidthRate()

    public static func bytesPerSecond(mbps: Double) -> Int64 { Int64((mbps * 1_000_000 / 8).rounded()) }
}

/// La file d'attente explicite, vue par l'app.
public struct QueueInfo: Codable, Equatable, Sendable {
    public var running: Bool
    public var items: [UUID]
    /// L'élément de la file qui s'exécute.
    public var current: UUID?

    public init(running: Bool, items: [UUID], current: UUID?) {
        self.running = running
        self.items = items
        self.current = current
    }
}
