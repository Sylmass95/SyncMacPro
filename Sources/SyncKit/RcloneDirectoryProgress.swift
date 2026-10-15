import Foundation

/// Dossiers « faits » d'une exécution rclone : un dossier l'est quand tous ses fichiers à copier le sont.
/// rclone ne donne que des fichiers ; le total vient d'une simulation (fichiers à copier, groupés par dossier).
public struct RcloneDirectoryProgress: Sendable {
    private var remaining: [String: Int]
    private var copied: Set<String> = []
    public private(set) var done = 0
    public let total: Int

    /// - Parameter directoriesOfPendingFiles: dossier relatif (« » pour la racine) → nombre de fichiers à copier.
    public init(directoriesOfPendingFiles: [String: Int]) {
        remaining = directoriesOfPendingFiles.filter { $0.value > 0 }
        total = remaining.count
    }

    public mutating func fileCopied(_ path: String) {
        guard copied.insert(path).inserted else { return }
        let directory = (path as NSString).deletingLastPathComponent
        guard let count = remaining[directory] else { return }
        if count <= 1 {
            remaining[directory] = nil
            done += 1
        } else {
            remaining[directory] = count - 1
        }
    }

    /// Une ligne de simulation (`--dry-run -v`) : un fichier qui serait copié ou déplacé compte pour son dossier.
    public static func notePending(_ line: String, into directories: inout [String: Int]) {
        guard case .notice(let message, let object?)? = RcloneOutputParser.parse(line: line),
              message.hasPrefix("Skipped copy as --dry-run") || message.hasPrefix("Skipped move as --dry-run")
        else { return }
        directories[(object as NSString).deletingLastPathComponent, default: 0] += 1
    }
}
