import Foundation
import SyncKit

/// Textes et listes du disque amovible (cartes, miniature, barre de menus), sans vue.
public struct DrivePresentation {
    public let localizer: Localizer
    public let now: Date

    public init(localizer: Localizer = .system, now: Date = Date()) {
        self.localizer = localizer
        self.now = now
    }

    /// « 12 min », « 2 h », « 3 j ».
    public func elapsed(since date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds >= 86_400 { return localizer.format("drive.elapsed.d", Int(seconds / 86_400)) }
        if seconds >= 3_600 { return localizer.format("drive.elapsed.h", Int(seconds / 3_600)) }
        return localizer.format("drive.elapsed.min", max(1, Int(seconds / 60)))
    }

    /// La ligne « disque » d'une carte ; `nil` pour une tâche sans disque amovible.
    public func line(info: AgentTaskInfo, task: SyncTask?) -> String? {
        guard let drive = task?.removableDrive else { return nil }
        // Disque revenu, la reprise attend une condition (secteur, plage horaire) : on dit laquelle.
        if info.driveSuspendedSince != nil, info.driveMounted == true, case .waiting(let reason) = info.state {
            return localizer.format("card.drive.suspended.back", drive.volumeName, reason)
        }
        if let since = info.driveSuspendedSince {
            return localizer.format("card.drive.suspended", drive.volumeName, elapsed(since: since))
        }
        if info.driveMounted == true { return localizer.format("card.drive.mounted", drive.volumeName) }
        return localizer.format("card.drive.unplugged", drive.volumeName)
    }

    /// Tâches dont le disque demande un geste : sauvegarde en pause (Abandonner) ou disque à éjecter (bouton).
    @MainActor public static func attentionIDs(status: AgentStatus?, tasks: [UUID: SyncTask]) -> [UUID] {
        (status?.tasks ?? []).filter { info in
            let actions = TaskCard.availableActions(info: info, task: tasks[info.id], driveMounted: info.driveMounted)
            return actions.contains(.abandon) || actions.contains(.eject)
        }.map(\.id)
    }
}
