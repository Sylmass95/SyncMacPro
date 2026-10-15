import Foundation

/// Dossiers « faits » d'une exécution rclone : un dossier l'est quand tous ses fichiers à copier le sont.
/// rclone ne donne que des fichiers ; le total vient d'une simulation (fichiers à copier) et des fichiers déjà copiés.
public struct RcloneDirectoryProgress: Sendable {
    private var remaining: [String: Int]
    private var copied: Set<String> = []
    public private(set) var done = 0
    public let total: Int

    /// - Parameters:
    ///   - pendingFiles: fichiers que la simulation verrait encore à copier.
    ///   - alreadyCopied: fichiers déjà copiés quand le comptage se termine. La simulation tourne en même temps que la
    ///     copie : un fichier déjà copié n'y figure plus, il est donc ajouté ici (une seule fois), puis compté comme fait.
    public init(pendingFiles: Set<String>, alreadyCopied: [String] = []) {
        var counts: [String: Int] = [:]
        for path in pendingFiles.union(alreadyCopied) { counts[(path as NSString).deletingLastPathComponent, default: 0] += 1 }
        remaining = counts
        total = counts.count
        for path in alreadyCopied { fileCopied(path) }
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
    public static func notePending(_ line: String, into files: inout Set<String>) {
        guard case .notice(let message, let object?)? = RcloneOutputParser.parse(line: line),
              message.hasPrefix("Skipped copy as --dry-run") || message.hasPrefix("Skipped move as --dry-run")
        else { return }
        files.insert(object)
    }
}
