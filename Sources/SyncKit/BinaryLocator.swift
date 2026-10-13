import Foundation

/// Retrouve les programmes rsync et rclone.
public enum BinaryLocator {
    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// Ordre : variable d'environnement (`SYNCMACPRO_RSYNC`, `SYNCMACPRO_RCLONE`), dossier embarqué
    /// (`<bundleDirectory>/<nom>`), puis les dossiers usuels. Un rsync qui n'est pas rsync 3 (l'openrsync de macOS)
    /// est écarté : ses sorties et ses options diffèrent (simulation qui sous-estime les suppressions, miroir en échec).
    public static func locate(
        _ engine: EngineKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleDirectory: String? = nil,
        searchDirectories: [String] = BinaryLocator.searchDirectories,
        fileManager: FileManager = .default,
        isSupported: (EngineKind, String) -> Bool = BinaryLocator.isSupported
    ) -> String? {
        let name = engine.rawValue
        var candidates: [String] = []
        if let override = environment["SYNCMACPRO_\(name.uppercased())"] { candidates.append(override) }
        if let bundle = bundleDirectory { candidates.append("\(bundle)/\(name)") }
        candidates += searchDirectories.map { "\($0)/\(name)" }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) && isSupported(engine, $0) }
    }

    /// rsync doit annoncer « version 3 » ; rclone est accepté tel quel.
    public static func isSupported(_ engine: EngineKind, _ path: String) -> Bool {
        guard engine == .rsync else { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let firstLine = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.contains("rsync") && firstLine.contains("version 3.")
    }
}
