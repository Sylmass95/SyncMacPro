import Foundation

/// Version de l'app, lue dans le bundle qui contient l'exécutable (« dev » hors bundle).
public enum AppInfo {
    public static func version(executable: String = BinaryLocator.currentExecutable) -> String {
        let contents = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let short = plist["CFBundleShortVersionString"] as? String
        else { return "dev" }
        if let build = plist["CFBundleVersion"] as? String { return "\(short) (\(build))" }
        return short
    }
}
