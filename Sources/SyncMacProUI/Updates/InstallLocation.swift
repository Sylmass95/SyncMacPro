import Foundation

public enum InstallLocationProblem: Equatable, Sendable {
    /// Gatekeeper a lancé une copie temporaire : l'agent installé disparaîtrait avec elle.
    case translocated
    /// Lancée depuis le DMG : le volume sera éjecté.
    case diskImage
}

public enum InstallLocation {
    public static func problem(bundlePath: String) -> InstallLocationProblem? {
        guard bundlePath.hasSuffix(".app") else { return nil }
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") { return .diskImage }
        return nil
    }
}
