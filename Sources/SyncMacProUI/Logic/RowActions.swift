import Foundation
import SyncKit

/// Boutons d'une ligne de la liste (1.7.6) : seuls les utiles, dans un ordre fixe, en icônes (nom au survol).
enum RowAction: Hashable, Sendable {
    case run, resume, pause, force, stop, abandon, approve, eject, enable, disable

    /// Emplacement : Lancer / Reprendre / Pause partagent le même bouton, Arrêter et Abandonner aussi.
    enum Slot: Int, Comparable, Sendable {
        case approve, playPause, force, stop, eject, power
        static func < (a: Slot, b: Slot) -> Bool { a.rawValue < b.rawValue }
    }

    var slot: Slot {
        switch self {
        case .run, .resume, .pause: return .playPause
        case .force: return .force
        case .stop, .abandon: return .stop
        case .approve: return .approve
        case .eject: return .eject
        case .enable, .disable: return .power
        }
    }

    var symbol: String {
        switch self {
        case .run, .resume: return "play.fill"
        case .pause: return "pause.fill"
        case .force: return "forward.fill"
        case .stop: return "stop.fill"
        case .abandon: return "xmark.circle.fill"
        case .approve: return "checkmark.shield.fill"
        case .eject: return "eject.fill"
        case .enable, .disable: return "power"
        }
    }

    var tipKey: String { "list.tip.\(self)" }
}

extension TaskRow {
    /// Les boutons d'une tâche selon son état. Une sauvegarde de disque en pause (disque débranché) a « Abandonner »
    /// à la place d'« Arrêter » ; une copie ponctuelle ne s'active ni ne se désactive.
    static func rowActions(_ info: AgentTaskInfo, task: SyncTask?) -> [RowAction] {
        var actions: [RowAction]
        switch info.state {
        case .disabled: return [.enable]
        case .running: actions = [.pause, .stop]
        case .paused: actions = info.resumePending == true ? [.force, .stop] : [.resume, .force, .stop]
        case .queued: actions = [.force, .stop]
        case .awaitingApproval: actions = [.approve, .run]
        case .idle, .waiting:
            if info.isOneOff { return [] }
            actions = [.run, .force]
            if info.driveSuspendedSince != nil { actions.append(.abandon) }
            if let drive = task?.removableDrive, drive.eject == .button, info.driveMounted == true, info.driveSuspendedSince == nil {
                actions.append(.eject)
            }
        }
        if !info.isOneOff { actions.append(.disable) }
        return actions
    }
}
