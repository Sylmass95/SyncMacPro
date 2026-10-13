import Foundation
import SyncKit

/// Les textes de l'éditeur : résumé en clair, avertissements, simulation, noms des modes, des étapes et des modèles.
public struct TaskSummaryText {
    public let localizer: Localizer
    public let calendar: Calendar
    public let now: Date

    public init(localizer: Localizer = .system, calendar: Calendar = .current, now: Date = Date()) {
        self.localizer = localizer
        self.calendar = calendar
        self.now = now
    }

    private var cards: CardText { CardText(localizer: localizer, calendar: calendar, now: now) }

    /// Dernier dossier du chemin, ou « remote:chemin ».
    public func endpointLabel(_ endpoint: Endpoint) -> String {
        switch endpoint {
        case .cloud(let remote, let path):
            return path.isEmpty ? "\(remote):" : "\(remote):\(path)"
        case .local, .network:
            let path = endpoint.filesystemPath ?? ""
            let last = URL(fileURLWithPath: path).lastPathComponent
            return last.isEmpty || last == "/" ? path : last
        }
    }

    public func sentence(for task: SyncTask) -> String {
        let source = endpointLabel(task.source), destination = endpointLabel(task.destination)
        let when: String
        switch task.schedule {
        case .manual:
            when = localizer.text("summary.when.manual")
        case .weekdays:
            when = cards.schedule(task.schedule)
        case .daily, .everyMinutes, .whenAvailable:
            let schedule = cards.schedule(task.schedule)
            when = schedule.prefix(1).lowercased() + schedule.dropFirst()
        }
        var text: String
        switch task.mode {
        case .copy: text = localizer.format("summary.sentence.copy", source, destination, when)
        case .mirror: text = localizer.format("summary.sentence.mirror", source, destination, when)
        case .bidirectional: text = localizer.format("summary.sentence.bidirectional", source, destination, when)
        case .move: text = localizer.format("summary.sentence.move", source, destination, when)
        case .versioned: text = localizer.format("summary.sentence.versioned", source, destination, when)
        case .verify: text = localizer.format("summary.sentence.verify", source, destination, when)
        }
        switch task.mode {
        case .copy, .versioned: text += " " + localizer.text("summary.safe")
        case .verify: text += " " + localizer.text("summary.readonly")
        case .mirror, .bidirectional, .move: break
        }
        return text
    }

    public func warnings(for task: SyncTask) -> [String] {
        var list: [String] = []
        switch task.mode {
        case .mirror: list.append(localizer.format("warning.mirror", task.options.archiveFolder))
        case .bidirectional: list.append(localizer.text("warning.bidirectional"))
        case .move: list.append(localizer.text("warning.move"))
        case .copy, .versioned, .verify: break
        }
        if !task.isEnabled { list.append(localizer.text("warning.disabled")) }
        return list
    }

    public func nextRun(for task: SyncTask) -> String {
        if task.schedule == .whenAvailable { return localizer.text("schedule.whenAvailable") }
        return cards.nextRun(Scheduler.nextDue(for: task.schedule, after: nil, now: now, calendar: calendar))
    }

    public func simulation(_ result: SimulationResult) -> String {
        switch result.status {
        case .succeeded:
            return localizer.format(
                "simulation.result", result.filesToTransfer, localizer.bytes(result.bytesToTransfer), result.deletions
            )
        case .stopped:
            return localizer.text("simulation.stopped")
        default:
            return localizer.format("simulation.failed", result.message ?? cards.status(result.status))
        }
    }

    /// Mis en avant quand la simulation prévoit des suppressions.
    public func deletionsWarning(_ result: SimulationResult) -> String? {
        guard result.status == .succeeded, result.deletions > 0 else { return nil }
        return localizer.format("simulation.deletions", result.deletions)
    }

    public func problem(_ problem: TaskProblem) -> String {
        switch problem {
        case .emptyName: return localizer.text("problem.emptyName")
        case .missingSource: return localizer.text("problem.missingSource")
        case .missingDestination: return localizer.text("problem.missingDestination")
        case .sameSourceAndDestination: return localizer.text("problem.sameSourceAndDestination")
        case .nestedFolders: return localizer.text("problem.nestedFolders")
        case .engineMismatch: return localizer.text("problem.engineMismatch")
        case .invalidThreshold: return localizer.text("problem.invalidThreshold")
        case .invalidSchedule: return localizer.text("problem.invalidSchedule")
        }
    }

    public func modeTitle(_ mode: SyncMode) -> String { cards.mode(mode) }

    public func modeDescription(_ mode: SyncMode) -> String {
        switch mode {
        case .copy: return localizer.text("mode.copy.description")
        case .mirror: return localizer.text("mode.mirror.description")
        case .bidirectional: return localizer.text("mode.bidirectional.description")
        case .move: return localizer.text("mode.move.description")
        case .versioned: return localizer.text("mode.versioned.description")
        case .verify: return localizer.text("mode.verify.description")
        }
    }

    public func modeWarning(_ mode: SyncMode) -> String? {
        switch mode {
        case .mirror: return localizer.text("mode.mirror.warning")
        case .bidirectional: return localizer.text("mode.bidirectional.warning")
        case .move: return localizer.text("mode.move.warning")
        case .copy, .versioned, .verify: return nil
        }
    }

    public func modeNote(_ mode: SyncMode) -> String? {
        mode.requiresRclone ? localizer.text("mode.rclone.note") : nil
    }

    public func scheduleKind(_ kind: ScheduleKind) -> String {
        switch kind {
        case .manual: return localizer.text("schedule.kind.manual")
        case .daily: return localizer.text("schedule.kind.daily")
        case .weekdays: return localizer.text("schedule.kind.weekdays")
        case .everyMinutes: return localizer.text("schedule.kind.everyMinutes")
        case .whenAvailable: return localizer.text("schedule.kind.whenAvailable")
        }
    }

    public func notification(_ policy: NotificationPolicy) -> String {
        switch policy {
        case .always: return localizer.text("notify.always")
        case .errorsOnly: return localizer.text("notify.errorsOnly")
        case .never: return localizer.text("notify.never")
        }
    }

    public func templateTitle(_ template: TaskTemplate) -> String {
        switch template {
        case .copyToNAS: return localizer.text("template.copyToNAS.title")
        case .syncTwoFolders: return localizer.text("template.syncTwoFolders.title")
        case .backupToDrive: return localizer.text("template.backupToDrive.title")
        }
    }

    public func templateDescription(_ template: TaskTemplate) -> String {
        switch template {
        case .copyToNAS: return localizer.text("template.copyToNAS.description")
        case .syncTwoFolders: return localizer.text("template.syncTwoFolders.description")
        case .backupToDrive: return localizer.text("template.backupToDrive.description")
        }
    }

    public func stepTitle(_ step: EditorStep) -> String {
        switch step {
        case .endpoints: return localizer.text("editor.step.endpoints")
        case .mode: return localizer.text("editor.step.mode")
        case .options: return localizer.text("editor.step.options")
        case .schedule: return localizer.text("editor.step.schedule")
        case .summary: return localizer.text("editor.step.summary")
        }
    }
}
