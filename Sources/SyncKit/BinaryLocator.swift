import Foundation

/// Retrouve les programmes rsync et rclone.
public enum BinaryLocator {
    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// Ordre : variable d'environnement (`SYNCMACPRO_RSYNC`, `SYNCMACPRO_RCLONE`), dossier embarqué
    /// (`<bundleDirectory>/<nom>`), puis les dossiers usuels.
    public static func locate(
        _ engine: EngineKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleDirectory: String? = nil,
        searchDirectories: [String] = BinaryLocator.searchDirectories,
        fileManager: FileManager = .default
    ) -> String? {
        let name = engine.rawValue
        var candidates: [String] = []
        if let override = environment["SYNCMACPRO_\(name.uppercased())"] { candidates.append(override) }
        if let bundle = bundleDirectory { candidates.append("\(bundle)/\(name)") }
        candidates += searchDirectories.map { "\($0)/\(name)" }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
