import Foundation
import Darwin

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

extension InstallLocation {
    /// L'emplacement d'origine d'une app translocalisée (le fichier que l'utilisateur doit déplacer), sinon `nil`.
    /// `SecTranslocateCreateOriginalPathForURL` existe dans Security depuis macOS 10.12 sans être dans le SDK public.
    public static func originalURL(ofTranslocated url: URL) -> URL? {
        guard url.path.contains("/AppTranslocation/"),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL")
        else { return nil }
        typealias Function = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(symbol, to: Function.self)
        return original(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
