import XCTest
import SyncKit
@testable import SyncMacProUI

private let paris: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}()

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    paris.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func info(
    _ name: String, _ state: TaskRunState = .idle, next: Date? = nil, last: RunStatus? = nil
) -> AgentTaskInfo {
    let id = UUID()
    let record = last.map {
        RunRecord(taskID: id, taskName: name, engine: .rsync, mode: .copy, startedAt: at(12, 8), status: $0)
    }
    return AgentTaskInfo(id: id, name: name, state: state, nextDue: next, lastRun: record)
}

final class CardTextTests: XCTestCase {
    func text(_ language: String, now: Date = at(12, 10)) -> CardText {
        CardText(localizer: Localizer(language: language), calendar: paris, now: now)
    }

    func testRelativeTimes() {
        let now = at(12, 10)
        XCTAssertEqual(text("fr").relative(now.addingTimeInterval(-20)), "à l’instant")
        XCTAssertEqual(text("fr").relative(now.addingTimeInterval(-5 * 60)), "il y a 5 min")
        XCTAssertEqual(text("fr").relative(now.addingTimeInterval(-2 * 3_600)), "il y a 2 h")
        XCTAssertEqual(text("en").relative(now.addingTimeInterval(-3 * 86_400)), "3 d ago")
    }

    func testNextRunTodayTomorrowAndLater() {
        XCTAssertEqual(text("fr").nextRun(at(12, 23)), "aujourd’hui à 23:00")
        XCTAssertEqual(text("fr").nextRun(at(13, 3)), "demain à 03:00")
        XCTAssertTrue(text("en").nextRun(at(13, 3)).hasPrefix("tomorrow at"))
        let later = text("fr").nextRun(at(20, 3))
        XCTAssertTrue(later.contains("20"), later)
        XCTAssertEqual(text("fr").nextRun(nil), "Sans échéance")
    }

    func testLastRunSummary() {
        let record = RunRecord(
            taskID: UUID(), taskName: "n", engine: .rsync, mode: .copy, startedAt: at(12, 8),
            finishedAt: at(12, 9), status: .succeeded,
            summary: RunSummary(filesTransferred: 3, bytesTransferred: 5_242_880, errors: 0)
        )
        XCTAssertEqual(text("fr").lastRun(record), "Réussie il y a 2 h — 3 fichier(s), 5,0 Mo")
        XCTAssertEqual(text("fr").lastRun(nil), "Jamais lancée")
        var running = record
        running.status = .running
        running.summary = nil
        XCTAssertEqual(text("fr").lastRun(running), "En cours il y a 2 h")
    }

    func testSummaryLineMentionsErrors() {
        let summary = RunSummary(filesTransferred: 1, bytesTransferred: 10, errors: 2)
        XCTAssertEqual(text("fr").summaryLine(summary), "1 fichier(s), 10 o, 2 erreur(s)")
    }

    func testProgressLineVariants() {
        var info = ProgressInfo(TransferSnapshot())
        info.doneBytes = 1_073_741_824
        info.totalBytes = 3_221_225_472
        info.currentSpeed = 47_185_920
        info.totalETA = 12
        XCTAssertEqual(text("fr").progressLine(info), "1,00 Go sur 3,00 Go · 45,0 Mo/s · reste 0:12")
        info.totalETA = nil
        XCTAssertEqual(text("fr").progressLine(info), "1,00 Go sur 3,00 Go · 45,0 Mo/s")
        info.totalBytes = nil
        XCTAssertEqual(text("fr").progressLine(info), "1,00 Go copiés")
        info.totalBytes = 0
        XCTAssertEqual(text("fr").progressLine(info), "1,00 Go copiés")
    }

    func testScheduleAndModeNames() {
        XCTAssertEqual(text("fr").schedule(.manual), "Manuelle")
        XCTAssertEqual(text("fr").schedule(.daily(hour: 3, minute: 5)), "Tous les jours à 03:05")
        XCTAssertEqual(text("fr").schedule(.everyMinutes(15)), "Toutes les 15 min")
        XCTAssertEqual(text("fr").schedule(.weekdays(days: [6, 2], hour: 8, minute: 0)), "lun., ven. à 08:00")
        XCTAssertEqual(text("en").schedule(.whenAvailable), "When available")
        XCTAssertEqual(text("fr").mode(.mirror), "Miroir")
        XCTAssertEqual(text("en").mode(.bidirectional), "Two-way")
    }

    func testStateAndStatusLabels() {
        XCTAssertEqual(text("fr").state(.waiting(reason: "réseau")), "En attente : réseau")
        XCTAssertEqual(text("en").state(.awaitingApproval), "Approval needed")
        XCTAssertEqual(text("fr").status(.quotaReached), "Quota atteint")
    }
}

final class MenuBarStateTests: XCTestCase {
    func status(paused: Bool = false, _ tasks: [AgentTaskInfo]) -> AgentStatus {
        AgentStatus(globalPause: paused, stateRecovered: false, taskLoadError: nil, tasks: tasks)
    }

    func make(
        _ status: AgentStatus?, connection: ConnectionState = .connected, progress: [UUID: ProgressInfo] = [:]
    ) -> MenuBarState {
        MenuBarState.make(connection: connection, status: status, progress: progress)
    }

    func testDisconnectedWhenNotConnectedOrNoStatus() {
        XCTAssertEqual(make(nil), .disconnected)
        XCTAssertEqual(make(status([]), connection: .reconnecting(attempt: 2)), .disconnected)
        XCTAssertEqual(make(status([]), connection: .unreachable), .disconnected)
    }

    func testIdleWhenNothingHappens() {
        XCTAssertEqual(make(status([info("a")])), .idle)
        XCTAssertEqual(make(status([])), .idle)
    }

    func testOneCopyShowsItsPercentage() {
        let running = info("a", .running)
        var progress = ProgressInfo(TransferSnapshot())
        progress.overallPercent = 42
        XCTAssertEqual(make(status([running]), progress: [running.id: progress]), .copying(percent: 42, count: 1))
        XCTAssertEqual(make(status([running])), .copying(percent: nil, count: 1))
    }

    func testSeveralCopiesShowACount() {
        XCTAssertEqual(make(status([info("a", .running), info("b", .running)])), .copying(percent: nil, count: 2))
    }

    func testGlobalPauseWinsOverACopy() {
        XCTAssertEqual(make(status(paused: true, [info("a", .paused)])), .paused)
    }

    func testPausedTaskWhenNothingElseRuns() {
        XCTAssertEqual(make(status([info("a", .paused)])), .paused)
    }

    func testErrorsShowWhenNothingRuns() {
        XCTAssertEqual(make(status([info("a", last: .failed)])), .error)
        XCTAssertEqual(make(status([info("a", last: .blocked)])), .error)
        XCTAssertEqual(make(status([info("a", .awaitingApproval)])), .error)
        XCTAssertEqual(make(status([info("a", last: .succeeded)])), .idle)
    }

    func testACopyHidesAnErrorElsewhere() {
        XCTAssertEqual(
            make(status([info("a", .running), info("b", last: .failed)])), .copying(percent: nil, count: 1)
        )
    }

    func testIconsAndTitles() {
        let l = Localizer(language: "fr")
        XCTAssertEqual(MenuBarState.copying(percent: 42, count: 1).title(l), "42 %")
        XCTAssertEqual(MenuBarState.copying(percent: nil, count: 2).title(l), "2 copies")
        XCTAssertNil(MenuBarState.idle.title(l))
        XCTAssertEqual(MenuBarState.paused.systemImage, "pause.circle")
        XCTAssertEqual(MenuBarState.error.systemImage, "exclamationmark.triangle")
        XCTAssertEqual(MenuBarState.disconnected.systemImage, "bolt.slash")
    }
}

final class HistoryFilterTests: XCTestCase {
    let now = at(12, 12)

    func record(_ name: String, _ status: RunStatus, hoursAgo: Double, task: UUID = UUID()) -> RunRecord {
        RunRecord(
            taskID: task, taskName: name, engine: .rsync, mode: .copy,
            startedAt: now.addingTimeInterval(-hoursAgo * 3_600), status: status
        )
    }

    func testNoFilterKeepsEverything() {
        let records = [record("a", .succeeded, hoursAgo: 1), record("b", .failed, hoursAgo: 100)]
        XCTAssertEqual(HistoryFilter().apply(to: records, now: now).count, 2)
    }

    func testByTaskStatusAndSearch() {
        let nas = UUID()
        let records = [
            record("Archives NAS", .succeeded, hoursAgo: 1, task: nas),
            record("Archives NAS", .failed, hoursAgo: 2, task: nas),
            record("Photos", .failed, hoursAgo: 3),
        ]
        var filter = HistoryFilter()
        filter.taskID = nas
        XCTAssertEqual(filter.apply(to: records, now: now).count, 2)
        filter.statuses = [.failed]
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["Archives NAS"])
        filter = HistoryFilter()
        filter.search = "PHO"
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["Photos"])
    }

    func testPeriods() {
        let records = [
            record("a", .succeeded, hoursAgo: 2),
            record("b", .succeeded, hoursAgo: 48),
            record("c", .succeeded, hoursAgo: 24 * 10),
            record("d", .succeeded, hoursAgo: 24 * 40),
        ]
        var filter = HistoryFilter()
        filter.period = .day
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["a"])
        filter.period = .week
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["a", "b"])
        filter.period = .month
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.taskName), ["a", "b", "c"])
        filter.period = .all
        XCTAssertEqual(filter.apply(to: records, now: now).count, 4)
    }
}
