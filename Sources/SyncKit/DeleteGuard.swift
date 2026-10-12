import Foundation

public enum GuardVerdict: Equatable, Sendable {
    case allowed
    /// Trop de suppressions : l'exécution ne doit pas démarrer.
    case blocked(percent: Int, deletions: Int, existing: Int)
}

/// Garde-fou : refuse une exécution qui supprimerait trop de fichiers d'un coup.
public enum DeleteGuard {
    /// Part des fichiers existants qui seraient supprimés (arrondie à l'entier inférieur).
    /// Sans fichier existant mais avec des suppressions, c'est 100 %.
    public static func percent(deletions: Int, existing: Int) -> Int {
        guard deletions > 0 else { return 0 }
        guard existing > 0 else { return 100 }
        return min(100, deletions * 100 / existing)
    }

    /// Bloque si le pourcentage **dépasse** le seuil (égal au seuil est accepté).
    public static func verdict(deletions: Int, existing: Int, thresholdPercent: Int) -> GuardVerdict {
        let percent = percent(deletions: deletions, existing: existing)
        return percent > thresholdPercent
            ? .blocked(percent: percent, deletions: deletions, existing: existing)
            : .allowed
    }

    /// rsync : fichiers présents à la destination avant l'exécution =
    /// ceux qui vont être supprimés + ceux de la source qui y existent déjà.
    public static func verdict(for plan: RsyncPlan, thresholdPercent: Int) -> GuardVerdict {
        let deletions = plan.deletions.count
        let alreadyThere = max(0, (plan.sourceRegularFiles ?? 0) - (plan.createdRegularFiles ?? 0))
        return verdict(deletions: deletions, existing: deletions + alreadyThere, thresholdPercent: thresholdPercent)
    }

    /// Nombre maximum de suppressions à passer à rclone (`--max-delete`) en dernier recours.
    public static func maxDeleteCount(existing: Int, thresholdPercent: Int) -> Int {
        existing * thresholdPercent / 100
    }
}

/// Lecture de `rclone size --json` (`{"count":3,"bytes":8,"sizeless":0}`).
public enum RcloneSizeParser {
    public static func count(from text: String) -> Int? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = object["count"] as? Int else { return nil }
        return count
    }
}
