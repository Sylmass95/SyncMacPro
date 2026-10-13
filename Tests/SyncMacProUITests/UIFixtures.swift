import Foundation
import SyncKit
@testable import SyncMacProUI

/// Données factices : six tâches dans tous les états, et un historique de 30 exécutions.
enum UIFixtures {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static let now = at(12, 10)
    static let french = CardText(localizer: Localizer(language: "fr"), calendar: calendar, now: now)
    static let english = CardText(localizer: Localizer(language: "en"), calendar: calendar, now: now)

    static let ids = (0..<6).map { _ in UUID() }

    static let tasks: [SyncTask] = [
        SyncTask(id: ids[0], name: "Archives NAS → Drive", source: .local(path: "/Volumes/NAS/archives"),
                 destination: .cloud(remote: "drive", path: "Sauvegardes"), mode: .mirror, schedule: .daily(hour: 3, minute: 0)),
        SyncTask(id: ids[1], name: "Photos", source: .local(path: "/Users/moi/Photos"),
                 destination: .local(path: "/Volumes/Disque/Photos"), mode: .copy, schedule: .everyMinutes(60)),
        SyncTask(id: ids[2], name: "Documents du travail avec un nom vraiment très très long pour tester la troncature",
                 source: .local(path: "/a"), destination: .local(path: "/b"), mode: .bidirectional, schedule: .whenAvailable),
        SyncTask(id: ids[3], name: "Projets vidéo", source: .local(path: "/c"), destination: .local(path: "/d"),
                 mode: .versioned, schedule: .weekdays(days: [2, 6], hour: 8, minute: 30)),
        SyncTask(id: ids[4], name: "Téléchargements", source: .local(path: "/e"), destination: .local(path: "/f"),
                 mode: .move, schedule: .manual),
        SyncTask(id: ids[5], name: "Ancienne sauvegarde", source: .local(path: "/g"), destination: .local(path: "/h"),
                 mode: .copy, schedule: .manual, isEnabled: false),
    ]

    static func record(
        _ index: Int, _ status: RunStatus, hoursAgo: Double, files: Int = 120, bytes: Int64 = 3_221_225_472,
        errors: Int = 0, message: String? = nil
    ) -> RunRecord {
        let start = now.addingTimeInterval(-hoursAgo * 3_600)
        return RunRecord(
            taskID: ids[index], taskName: tasks[index].name, engine: .rsync, mode: tasks[index].mode,
            startedAt: start, finishedAt: status == .running ? nil : start.addingTimeInterval(754), status: status,
            summary: RunSummary(
                filesTransferred: files, bytesTransferred: bytes, errors: errors, durationSeconds: 754, message: message
            )
        )
    }

    static func progress(done: Int64 = 1_288_490_188, total: Int64 = 3_221_225_472, percent: Int = 40) -> ProgressInfo {
        var snapshot = TransferSnapshot()
        snapshot.doneBytes = done
        snapshot.totalBytes = total
        snapshot.overallPercent = percent
        snapshot.currentName = "Vacances 2025/IMG_0042.mov"
        snapshot.currentSpeed = 47_185_920
        snapshot.totalETA = 41
        return ProgressInfo(snapshot)
    }

    static let infos: [AgentTaskInfo] = [
        AgentTaskInfo(id: ids[0], name: tasks[0].name, state: .awaitingApproval, nextDue: at(13, 3),
                      lastRun: record(0, .blocked, hoursAgo: 7, message: "Bloqué : 412 suppression(s) sur 1 200 fichier(s) (34 %), au-dessus du seuil de 25 %.")),
        AgentTaskInfo(id: ids[1], name: tasks[1].name, state: .running, nextDue: at(12, 11),
                      lastRun: record(1, .succeeded, hoursAgo: 2), progress: progress()),
        AgentTaskInfo(id: ids[2], name: tasks[2].name, state: .waiting(reason: "destination inaccessible"),
                      lastRun: record(2, .failed, hoursAgo: 30, errors: 3)),
        AgentTaskInfo(id: ids[3], name: tasks[3].name, state: .paused, nextDue: at(16, 8, 30),
                      lastRun: record(3, .succeeded, hoursAgo: 50), progress: progress(done: 500_000_000, percent: 15)),
        AgentTaskInfo(id: ids[4], name: tasks[4].name, state: .idle, lastRun: nil),
        AgentTaskInfo(id: ids[5], name: tasks[5].name, state: .disabled, lastRun: record(5, .stopped, hoursAgo: 400)),
    ]

    static func status(paused: Bool = false, recovered: Bool = false, taskLoadError: String? = nil) -> AgentStatus {
        AgentStatus(globalPause: paused, stateRecovered: recovered, taskLoadError: taskLoadError, tasks: infos)
    }

    @MainActor
    static func model(
        connection: ConnectionState = .connected, paused: Bool = false, recovered: Bool = false,
        empty: Bool = false
    ) -> AgentModel {
        let value = empty
            ? AgentStatus(globalPause: paused, stateRecovered: false, taskLoadError: nil, tasks: [])
            : status(paused: paused, recovered: recovered)
        return AgentModel.preview(
            connection: connection, status: value, tasks: empty ? [] : tasks,
            progress: [ids[1]: progress(), ids[3]: progress(done: 500_000_000, percent: 15)],
            history: history()
        )
    }

    static func history() -> [RunRecord] {
        let statuses: [RunStatus] = [.succeeded, .succeeded, .failed, .succeeded, .blocked, .quotaReached, .interrupted, .stopped]
        return (0..<30).map { index in
            record(index % 5, statuses[index % statuses.count], hoursAgo: Double(index) * 5.5 + 1,
                   files: 40 + index * 13, bytes: Int64(index + 1) * 98_765_432,
                   errors: statuses[index % statuses.count] == .failed ? 3 : 0,
                   message: statuses[index % statuses.count] == .failed ? "rsync : disque plein (code 11)" : nil)
        }
    }
}
