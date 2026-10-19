import Foundation
import SyncKit

/// L'essentiel d'une tâche, modifiable sous la liste (1.7.0) : horaire, activation, conditions, déclencheur du disque.
/// Le reste (source, destination, mode, exclusions, lier un disque) se change dans l'éditeur complet.
public struct QuickSettings: Equatable, Sendable {
    public var schedule: Schedule
    public var isEnabled: Bool
    public var requiresACPower: Bool
    public var allowedHours: HourRange?
    /// Seulement pour une tâche déjà liée à un disque amovible.
    public var driveTrigger: RemovableDrive.Trigger?

    public init(task: SyncTask) {
        schedule = task.schedule
        isEnabled = task.isEnabled
        requiresACPower = task.conditions.requiresACPower
        allowedHours = task.conditions.allowedHours
        driveTrigger = task.removableDrive?.trigger
    }

    public func apply(to task: SyncTask) -> SyncTask {
        var updated = task
        updated.schedule = schedule
        updated.isEnabled = isEnabled
        updated.conditions.requiresACPower = requiresACPower
        updated.conditions.allowedHours = allowedHours
        if let driveTrigger, updated.removableDrive != nil { updated.removableDrive?.trigger = driveTrigger }
        return updated
    }
}
