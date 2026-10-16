import Foundation

/// 1.6.4 : sans compte Apple Developer, chaque mise à jour change la signature de l'app et macOS ne reconnaît plus ses
/// autorisations de dossiers (elles restent cochées mais ne valent plus). Elles sont effacées (`tccutil reset`, permis
/// sans droits administrateur pour sa propre app) avant de redémarrer l'agent : macOS les redemande proprement.
public enum PermissionReset {
    /// Les autorisations de dossiers, qui se redemandent. Jamais l'accès complet au disque : il ne se redemande pas.
    public static let services = [
        "SystemPolicyNetworkVolumes", "SystemPolicyRemovableVolumes", "SystemPolicyDesktopFolder",
        "SystemPolicyDocumentsFolder", "SystemPolicyDownloadsFolder",
    ]

    /// Les services dont l'effacement a échoué.
    @discardableResult
    public static func resetAll(bundleID: String, run: ([String]) -> Int32 = PermissionReset.tccutil) -> [String] {
        services.filter { run(["reset", $0, bundleID]) != 0 }
    }

    public static func tccutil(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
