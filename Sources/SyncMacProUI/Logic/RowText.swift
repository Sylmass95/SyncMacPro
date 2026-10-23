import Foundation
import SyncKit

/// Textes d'une ligne de la liste (1.7.0) : rang, lieux en clair, état avec la raison de l'attente.
public struct RowText: Sendable {
    public let localizer: Localizer

    public init(localizer: Localizer) { self.localizer = localizer }

    public func rank(_ info: AgentTaskInfo) -> String { info.rank.map(String.init) ?? "•" }

    /// « Bureau », « Documents », « NAS « Documents » », « Disque « HDDExtBRSM » », « Drive partagé »…
    public func place(_ endpoint: Endpoint, drive: RemovableDrive?) -> String {
        switch endpoint {
        case .network(_, let mountPath):
            let share = NetworkShare.volumesRoot(of: mountPath).map { ($0 as NSString).lastPathComponent }
                ?? (mountPath as NSString).lastPathComponent
            return localizer.format("place.nas", share)
        case .cloud(let remote, _):
            if remote.contains("team_drive=") { return localizer.text("place.shared") }
            return localizer.format("place.cloud", remote.split(separator: ",").first.map(String.init) ?? remote)
        case .local(let path):
            if let drive { return localizer.format("place.disk", drive.volumeName) }
            let home = NSHomeDirectory()
            for (folder, key) in [("Desktop", "place.desktop"), ("Documents", "place.documents"), ("Downloads", "place.downloads")] {
                let root = home + "/" + folder
                if path == root || path.hasPrefix(root + "/") { return localizer.text(key) }
            }
            if let root = NetworkShare.volumesRoot(of: path) { return localizer.format("place.disk", (root as NSString).lastPathComponent) }
            return (path as NSString).lastPathComponent
        }
    }

    public func route(_ task: SyncTask) -> String {
        let source = place(task.source, drive: nil)
        let destination = place(task.destination, drive: task.removableDrive)
        return "\(source) → \(destination)"
    }

    /// État, avec la raison quand la tâche attend.
    public func state(_ info: AgentTaskInfo, text: CardText) -> String {
        if info.state == .paused, info.resumePending == true {
            return localizer.format("state.resume.pending", info.waitReason ?? "")
        }
        if info.state == .queued, let reason = info.waitReason { return localizer.format("state.queued.reason", reason) }
        // 1.7.1 : une copie sans progression dit ce qu'elle fait.
        if info.state == .running {
            switch info.phase {
            case "preparing": return localizer.text("state.phase.preparing")
            case "planning": return localizer.text("state.phase.planning")
            case "verifying": return localizer.text("state.phase.verifying")
            default: break
            }
        }
        return text.state(info.state)
    }

    /// Dernière exécution en couleur (1.7.6) : réussie en vert, échec en rouge, interrompue ou arrêtée en orange.
    struct LastRun: Equatable {
        enum Tone: Equatable { case success, failure, warning, neutral }
        let symbol: String
        let label: String
        let detail: String?
        let tone: Tone
    }

    func lastRun(_ info: AgentTaskInfo, text: CardText) -> LastRun {
        guard let record = info.lastRun else {
            return LastRun(symbol: "circle.dashed", label: localizer.text("last.never"), detail: nil, tone: .neutral)
        }
        let label = localizer.format("last.format", text.status(record.status), text.relative(record.startedAt))
        let detail = record.status == .running ? nil : record.summary.map { text.summaryLine($0) }
        switch record.status {
        case .succeeded: return LastRun(symbol: "checkmark.circle.fill", label: label, detail: detail, tone: .success)
        case .failed, .blocked, .quotaReached: return LastRun(symbol: "xmark.circle.fill", label: label, detail: detail, tone: .failure)
        case .interrupted, .stopped: return LastRun(symbol: "exclamationmark.circle.fill", label: label, detail: detail, tone: .warning)
        case .running: return LastRun(symbol: "circle.dotted", label: label, detail: nil, tone: .neutral)
        }
    }

    /// Libellé court de l'horaire (1.7.6), affiché en étiquette au-dessus du nom.
    func scheduleTag(_ task: SyncTask?, text: CardText) -> String? {
        guard let task else { return nil }
        if task.removableDrive != nil { return localizer.text("list.schedule.drive") }
        return text.schedule(task.schedule)
    }

    /// Mentions à côté du nom.
    public func badges(_ info: AgentTaskInfo) -> [String] {
        info.isOneOff ? [localizer.text("list.oneoff")] : []
    }
}
