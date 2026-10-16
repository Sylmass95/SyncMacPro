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
        var text = (privacyExplanation(for: cause) ?? explanation(for: cause)).map { "\($0) \(cause)" } ?? cause
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
            // Résumés de rclone : « Attempt 1/3 failed with 1 errors and: … », « Failed to copy with 2 errors: … ».
            || (lower.hasPrefix("attempt ") && lower.contains(" failed with "))
            || (lower.hasPrefix("failed to ") && lower.contains(" with ") && lower.contains(" error"))
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

    /// « Operation not permitted » sur un dossier protégé par macOS (Bureau, Documents, Téléchargements, volumes) :
    /// l'autorisation de SyncMacPro manque ou ne vaut plus (signature ad hoc nouvelle après une mise à jour).
    static func privacyExplanation(for line: String) -> String? {
        guard line.lowercased().contains("operation not permitted") else { return nil }
        let home = NSHomeDirectory()
        let places: [(String, String)] = [
            (home + "/Desktop", "« Dossier Bureau »"), (home + "/Documents", "« Dossier Documents »"),
            (home + "/Downloads", "« Dossier Téléchargements »"),
            ("/Volumes/", "« Volumes de réseau » (« Volumes amovibles » pour un disque externe)"),
        ]
        guard let setting = places.first(where: { line.contains($0.0) })?.1 else { return nil }
        return "macOS refuse l'accès à SyncMacPro : dans Réglages Système › Confidentialité et sécurité › Fichiers et dossiers "
            + "› SyncMacPro, activez (ou désactivez puis réactivez) \(setting), puis relancez la tâche."
    }

    static func explanation(for line: String) -> String? {
        let lower = line.lowercased()
        return explanations.first { entry in entry.patterns.contains { lower.contains($0) } }?.text
    }
}
