import Foundation
import SyncKit

/// Les lignes de progression façon RsyncGUI, communes aux cartes, à la liste, à la miniature et au bilan.
public struct ProgressPresentation {
    public let localizer: Localizer
    public init(localizer: Localizer) { self.localizer = localizer }

    public func filesLine(done: Int, total: Int?) -> String {
        localizer.format("progress.files", localizer.number(done), total.map(localizer.number) ?? "?")
    }

    public func dirsLine(done: Int?, total: Int?) -> String? {
        guard let total, total > 0 else { return nil }
        return localizer.format("progress.dirs", localizer.number(done ?? 0), localizer.number(total))
    }

    public func averageSpeedLine(_ speed: Double?) -> String? {
        guard let speed, speed > 0 else { return nil }
        return localizer.format("progress.average", localizer.speed(speed))
    }

    public func elapsedLine(_ seconds: TimeInterval) -> String {
        localizer.format("progress.elapsed", localizer.longDuration(seconds))
    }

    /// Bilan d'une exécution terminée : fichiers, volume, dossiers, vitesse moyenne, durée.
    public func summaryLines(_ summary: RunSummary) -> [String] {
        var lines = [localizer.format("summary.files", summary.filesTransferred), localizer.bytes(summary.bytesTransferred)]
        if let dirs = summary.directories { lines.append(localizer.format("summary.dirs", dirs)) }
        if let speed = averageSpeedLine(summary.averageSpeed) { lines.append(speed) }
        lines.append(elapsedLine(summary.durationSeconds))
        return lines
    }
}
