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

    /// rsync doit annoncer « version 3 » ; rclone doit se lancer et se présenter. Un binaire abîmé ou d'une autre
    /// architecture est écarté (on retombe alors sur celui du système).
    public static func isSupported(_ engine: EngineKind, _ path: String) -> Bool {
        let line = firstLine(of: path, arguments: engine == .rsync ? ["--version"] : ["version"]) ?? ""
        switch engine {
        case .rsync: return line.contains("rsync") && line.contains("version 3.")
        case .rclone: return line.hasPrefix("rclone v")
        }
    }

    /// Première ligne de sortie d'un programme ; `nil` s'il ne se lance pas.
    public static func firstLine(of path: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
    }

    /// `…/X.app/Contents/MacOS/programme` → `…/X.app/Contents/Resources/bin`, s'il existe.
    public static func embeddedDirectory(executable: String, fileManager: FileManager = .default) -> String? {
        let url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let macOS = url.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS" else { return nil }
        let bin = macOS.deletingLastPathComponent().appendingPathComponent("Resources/bin")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bin.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return bin.path
    }

    /// Le chemin de l'exécutable en cours (agent, ctl, app).
    public static var currentExecutable: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Recherche pour le programme en cours : les binaires de son bundle d'abord.
    public static func locateForProcess(_ engine: EngineKind) -> String? {
        locate(engine, bundleDirectory: embeddedDirectory(executable: currentExecutable))
    }
}
