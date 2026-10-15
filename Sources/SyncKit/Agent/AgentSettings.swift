import Foundation

/// Réglages tenus par l'agent (`settings.json`) : aujourd'hui les plafonds de débit.
public struct AgentSettingsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    /// Fichier absent ou illisible : aucun plafond (on ne bride jamais par surprise).
    public func load() -> BandwidthLimits {
        guard let data = try? Data(contentsOf: url) else { return BandwidthLimits() }
        return (try? JSONDecoder().decode(BandwidthLimits.self, from: data)) ?? BandwidthLimits()
    }

    public func save(_ limits: BandwidthLimits) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(limits).write(to: url, options: .atomic)
    }
}
