import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.7.6 : liste compacte — seuls les boutons utiles (icônes), Lecture/Pause en un seul bouton, Abandonner à la place
/// d'Arrêter pour une sauvegarde de disque en pause, dernière exécution en couleur, vrai état partout.
@MainActor
final class UI176Tests: XCTestCase {
    func info(_ state: TaskRunState, oneOff: Bool = false) -> AgentTaskInfo {
        var i = AgentTaskInfo(id: UUID(), name: "A", state: state, isOneOff: oneOff); i.rank = oneOff ? nil : 1; return i
    }

    func testOnlyUsefulActionsInAFixedOrder() {
        XCTAssertEqual(TaskRow.rowActions(info(.idle), task: nil), [.run, .force, .disable])
        XCTAssertEqual(TaskRow.rowActions(info(.running), task: nil), [.pause, .stop, .disable])
        XCTAssertEqual(TaskRow.rowActions(info(.paused), task: nil), [.resume, .force, .stop, .disable])
        var pending = info(.paused); pending.resumePending = true
        XCTAssertEqual(TaskRow.rowActions(pending, task: nil), [.force, .stop, .disable])
        XCTAssertEqual(TaskRow.rowActions(info(.queued), task: nil), [.force, .stop, .disable])
        XCTAssertEqual(TaskRow.rowActions(info(.disabled), task: nil), [.enable])
        XCTAssertEqual(TaskRow.rowActions(info(.awaitingApproval), task: nil), [.approve, .run, .disable])
        XCTAssertEqual(TaskRow.rowActions(info(.queued, oneOff: true), task: nil), [.force, .stop])
        XCTAssertEqual(TaskRow.rowActions(info(.idle, oneOff: true), task: nil), [])
    }

    func testAbandonReplacesStopForASuspendedDriveBackup() {
        var suspended = info(.waiting(reason: "disque débranché"))
        suspended.driveSuspendedSince = Date(timeIntervalSince1970: 0)
        suspended.driveMounted = false
        XCTAssertEqual(TaskRow.rowActions(suspended, task: nil), [.run, .force, .abandon, .disable])
    }

    func testEjectWhenTheDriveCanBeEjected() {
        var task = SyncTask(name: "A", source: .local(path: "/a"), destination: .local(path: "/Volumes/X/a"))
        task.removableDrive = RemovableDrive(volumeUUID: "U", volumeName: "X", relativePath: "a", trigger: .everyConnection, resumeWindowDays: 3, eject: .button)
        var idle = info(.idle); idle.driveMounted = true
        XCTAssertEqual(TaskRow.rowActions(idle, task: task), [.run, .force, .eject, .disable])
    }

    func testPlayAndPauseShareOneButton() {
        XCTAssertEqual(RowAction.run.slot, RowAction.pause.slot)
        XCTAssertEqual(RowAction.resume.slot, RowAction.pause.slot)
        XCTAssertEqual(RowAction.stop.slot, RowAction.abandon.slot)
    }

    func testLastRunIsColoured() {
        let text = UIFixtures.french
        func run(_ status: RunStatus) -> AgentTaskInfo {
            var i = info(.idle)
            i.lastRun = RunRecord(taskID: i.id, taskName: "A", engine: .rsync, mode: .copy, startedAt: text.now.addingTimeInterval(-3600 * 21), status: status)
            return i
        }
        XCTAssertEqual(RowText(localizer: text.localizer).lastRun(run(.succeeded), text: text).tone, .success)
        XCTAssertEqual(RowText(localizer: text.localizer).lastRun(run(.failed), text: text).tone, .failure)
        XCTAssertEqual(RowText(localizer: text.localizer).lastRun(run(.blocked), text: text).tone, .failure)
        XCTAssertEqual(RowText(localizer: text.localizer).lastRun(run(.interrupted), text: text).tone, .warning)
        XCTAssertEqual(RowText(localizer: text.localizer).lastRun(info(.idle), text: text).tone, .neutral)
        XCTAssertTrue(RowText(localizer: text.localizer).lastRun(run(.succeeded), text: text).label.hasPrefix("Réussie"))
    }

    /// La mini-fenêtre et la barre de menus disaient « En cours » pendant la préparation.
    func testTheRealStateIsShownInTheMiniWindowAndMenuBar() {
        var preparing = info(.running); preparing.phase = "planning"
        XCTAssertEqual(TaskCard.stateLabel(preparing, text: UIFixtures.french), "Préparation : comparaison avec la destination…")
        XCTAssertEqual(MenuBarPanel.stateLine(preparing, text: UIFixtures.french), "Préparation : comparaison avec la destination…")
    }

    func testDoubleClickOpensTheFirstSelectedTask() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(TaskListView.taskToOpen([b, a, TaskListView.otherRunsID], order: [a, b]), a)
        XCTAssertNil(TaskListView.taskToOpen([TaskListView.otherRunsID], order: [a, b]))
    }

    func testTheScheduleColumnIsGone() {
        XCTAssertEqual(ListColumn.allCases, [.rank, .task, .state, .last, .actions])
    }

    func testRowsRender() throws {
        let rows = VStack(spacing: 0) {
            ForEach(UIFixtures.infos) { info in
                TaskRow(info: info, task: UIFixtures.tasks.first { $0.id == info.id }, progress: nil, busy: false,
                        text: UIFixtures.french, actions: TaskCardActions())
            }
        }
        assertNotBlank(try render(rows, name: "rows-176", size: CGSize(width: 1000, height: 420), scheme: .dark))
    }
}
