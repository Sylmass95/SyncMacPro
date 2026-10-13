import Foundation

/// La quarantaine posée par le navigateur sur l'app téléchargée bloque aussi rsync, rclone et l'agent quand ils sont
/// lancés comme programmes. Une fois l'app ouverte (donc autorisée par l'utilisateur), elle la retire de son propre bundle.
public enum Quarantine {
    public static let attribute = "com.apple.quarantine"

    public static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Retire l'attribut du bundle et de tout son contenu ; renvoie le nombre de fichiers traités.
    @discardableResult
    public static func clear(bundle: URL) -> Int {
        var cleared = 0
        var paths = [bundle.path]
        if let enumerator = FileManager.default.enumerator(atPath: bundle.path) {
            for case let relative as String in enumerator { paths.append(bundle.appendingPathComponent(relative).path) }
        }
        for path in paths where removexattr(path, attribute, XATTR_NOFOLLOW) == 0 { cleared += 1 }
        return cleared
    }
}
