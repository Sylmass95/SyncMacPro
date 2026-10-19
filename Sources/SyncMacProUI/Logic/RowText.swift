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
        return text.state(info.state)
    }

    /// Mentions à côté du nom.
    public func badges(_ info: AgentTaskInfo) -> [String] {
        info.isOneOff ? [localizer.text("list.oneoff")] : []
    }
}
