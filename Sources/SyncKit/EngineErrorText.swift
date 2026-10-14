import Foundation

/// Message d'échec lisible à partir des erreurs d'un moteur.
///
/// rsync et rclone écrivent d'abord la cause (« No space left on device »), puis ses conséquences (« Broken pipe »,
/// « error in file IO (code 11) »). La dernière ligne n'est donc presque jamais la bonne : on garde la première
/// cause, précédée d'une explication en français quand elle est connue.
public enum EngineErrorText {
    /// - Parameters:
    ///   - errors: les premières erreurs, dans l'ordre d'apparition.
    ///   - total: nombre total d'erreurs de l'exécution.
    public static func summary(errors: [String], total: Int) -> String? {
        guard !errors.isEmpty else { return nil }
        let cause = errors.first { !isConsequence($0) } ?? errors.last!
        var text = explanation(for: cause).map { "\($0) \(cause)" } ?? cause
        if total > 1 { text += " (\(total) erreurs au total : voir le journal)" }
        return text
    }

    /// Lignes qui découlent d'une erreur précédente : la cause est ailleurs.
    static func isConsequence(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("broken pipe")
            || lower.contains("connection unexpectedly closed")
            || lower.contains("error in rsync protocol data stream")
            || lower.hasPrefix("rsync error:")
            || lower.contains("] rsync error:")
    }

    private static let explanations: [(patterns: [String], text: String)] = [
        (["no space left on device", "disk quota exceeded"], "Plus de place sur le disque de destination."),
        (["input/output error"], "Erreur de lecture ou d'écriture : le disque ou le NAS a peut-être été débranché."),
        (["no such file or directory", "directory not found"], "Dossier introuvable (disque débranché ou dossier déplacé ?)."),
        (["permission denied", "operation not permitted"], "Accès refusé."),
        (["read-only file system"], "La destination est en lecture seule."),
        (["operation timed out", "host is down", "network is unreachable", "no route to host",
          "connection refused", "connection reset"], "Le NAS ou le service ne répond pas (réseau ?)."),
        (["file name too long"], "Nom ou chemin de fichier trop long."),
    ]

    static func explanation(for line: String) -> String? {
        let lower = line.lowercased()
        return explanations.first { entry in entry.patterns.contains { lower.contains($0) } }?.text
    }
}
