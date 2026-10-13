import Foundation

public enum InstallLocationProblem: Equatable, Sendable {
    /// Gatekeeper a lancé une copie temporaire : l'agent installé disparaîtrait avec elle.
    case translocated
    /// Lancée depuis le DMG : le volume sera éjecté.
    case diskImage
}

public enum InstallLocation {
    /// `isReadOnlyVolume` : une image disque montée est en lecture seule ; un disque externe (où l'on peut garder ses
    /// apps) ne l'est pas.
    public static func problem(
        bundlePath: String, isReadOnlyVolume: (String) -> Bool = InstallLocation.isReadOnlyVolume
    ) -> InstallLocationProblem? {
        guard bundlePath.hasSuffix(".app") else { return nil }
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") && isReadOnlyVolume(bundlePath) { return .diskImage }
        return nil
    }

    public static func isReadOnlyVolume(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
    }
}
