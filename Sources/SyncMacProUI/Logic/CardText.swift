import Foundation
import SyncKit

/// Tous les textes d'une carte, d'une ligne d'historique ou du panneau de la barre de menus.
/// Horloge et calendrier injectés : « il y a 2 h » et « demain à 03:00 » se testent sans attendre.
public struct CardText {
    public let localizer: Localizer
    public let calendar: Calendar
    public let now: Date

    public init(localizer: Localizer = .system, calendar: Calendar = .current, now: Date = Date()) {
        self.localizer = localizer
        self.calendar = calendar
        self.now = now
    }

    public func state(_ state: TaskRunState) -> String {
        switch state {
        case .idle: return localizer.text("state.idle")
        case .queued: return localizer.text("state.queued")
        case .running: return localizer.text("state.running")
        case .paused: return localizer.text("state.paused")
        case .waiting(let reason): return localizer.format("state.waiting", reason)
        case .awaitingApproval: return localizer.text("state.approval")
        case .disabled: return localizer.text("state.disabled")
        }
    }

    public func status(_ status: RunStatus) -> String {
        switch status {
        case .running: return localizer.text("status.running")
        case .succeeded: return localizer.text("status.succeeded")
        case .failed: return localizer.text("status.failed")
        case .blocked: return localizer.text("status.blocked")
        case .quotaReached: return localizer.text("status.quota")
        case .interrupted: return localizer.text("status.interrupted")
        case .stopped: return localizer.text("status.stopped")
        }
    }

    public func mode(_ mode: SyncMode) -> String {
        switch mode {
        case .copy: return localizer.text("mode.copy")
        case .mirror: return localizer.text("mode.mirror")
        case .bidirectional: return localizer.text("mode.bidirectional")
        case .move: return localizer.text("mode.move")
        case .versioned: return localizer.text("mode.versioned")
        case .verify: return localizer.text("mode.verify")
        }
    }

    public func schedule(_ schedule: Schedule) -> String {
        func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
        switch schedule {
        case .manual: return localizer.text("schedule.manual")
        case .whenAvailable: return localizer.text("schedule.whenAvailable")
        case .everyMinutes(let minutes): return localizer.format("schedule.everyMinutes", minutes)
        case .daily(let hour, let minute): return localizer.format("schedule.daily", clock(hour, minute))
        case .weekdays(let days, let hour, let minute):
            let names = days.sorted().filter { (1...7).contains($0) }.map { localizer.text("weekday.\($0)") }
            return localizer.format("schedule.weekdays", names.joined(separator: ", "), clock(hour, minute))
        }
    }

    /// « à l'instant », « il y a 5 min », « il y a 2 h », « il y a 3 j ».
    public func relative(_ date: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return localizer.text("relative.now")
        case ..<3_600: return localizer.format("relative.minutes", Int(seconds / 60))
        case ..<86_400: return localizer.format("relative.hours", Int(seconds / 3_600))
        default: return localizer.format("relative.days", Int(seconds / 86_400))
        }
    }

    /// « aujourd'hui à 23:00 », « demain à 03:00 », ou « mar. 20 oct. 03:00 ». `nil` : « Sans échéance ».
    public func nextRun(_ date: Date?) -> String {
        guard let date else { return localizer.text("next.none") }
        let time = DateFormatter()
        time.locale = localizer.locale
        time.timeZone = calendar.timeZone
        time.timeStyle = .short
        time.dateStyle = .none
        if calendar.isDate(date, inSameDayAs: now) { return localizer.format("next.today", time.string(from: date)) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return localizer.format("next.tomorrow", time.string(from: date))
        }
        let full = DateFormatter()
        full.locale = localizer.locale
        full.timeZone = calendar.timeZone
        full.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return full.string(from: date)
    }

    /// « Réussie il y a 2 h — 3 fichier(s), 5,0 Mo » ; « Jamais lancée » sans exécution.
    public func lastRun(_ record: RunRecord?) -> String {
        guard let record else { return localizer.text("last.never") }
        let label = status(record.status)
        let when = relative(record.startedAt)
        if record.status != .running, let summary = record.summary {
            return localizer.format("last.format.summary", label, when, summaryLine(summary))
        }
        return localizer.format("last.format", label, when)
    }

    /// Ligne « Prochaine : … » ; `nil` pour une tâche manuelle ou une copie (rien à annoncer).
    public func nextRunLine(info: AgentTaskInfo, task: SyncTask?) -> String? {
        if info.isOneOff || task?.schedule == .manual { return nil }
        return localizer.format("card.next", nextRun(info.nextDue))
    }

    /// « 3 fichier(s), 5,0 Mo » ; ajoute « , 2 erreur(s) » s'il y en a.
    public func summaryLine(_ summary: RunSummary?) -> String {
        guard let summary else { return "" }
        var parts = [
            localizer.format("summary.files", summary.filesTransferred),
            localizer.bytes(summary.bytesTransferred),
        ]
        if summary.errors > 0 { parts.append(localizer.format("summary.errors", summary.errors)) }
        return parts.joined(separator: ", ")
    }

    /// « 1,00 Go sur 3,00 Go · 45,0 Mo/s · reste 0:12 », sans durée restante, ou sans total connu.
    public func progressLine(_ info: ProgressInfo) -> String {
        let done = localizer.bytes(info.doneBytes)
        guard let total = info.totalBytes, total > 0 else { return localizer.format("progress.line.unknown", done) }
        let speed = localizer.speed(info.currentSpeed)
        if let eta = info.totalETA {
            return localizer.format("progress.line", done, localizer.bytes(total), speed, localizer.duration(eta))
        }
        return localizer.format("progress.line.noeta", done, localizer.bytes(total), speed)
    }

    public func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = localizer.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
