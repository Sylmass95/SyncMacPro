import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.7.0 : le détail de la tâche sélectionnée, sous la liste (historique, réglages essentiels, journal).
@MainActor
final class TaskDetail170Tests: XCTestCase {
    func task(drive: Bool = false) -> SyncTask {
        var task = SyncTask(name: "Mac PERSO-FILES → QNAP", source: .local(path: "/Users/moi/Desktop/PERSO-FILES"),
                            destination: .network(url: "smb://admin@qnap/Documents", mountPath: "/Volumes/Documents/PERSO-FILES"),
                            options: TaskOptions(excludes: [".DS_Store", ".tmp.driveupload/"]), schedule: .daily(hour: 2, minute: 0))
        if drive {
            task.removableDrive = RemovableDrive(volumeUUID: "U", volumeName: "HDDExtBRSM", relativePath: "x", trigger: .everyConnection,
                                                 resumeWindowDays: 3, eject: .never)
        }
        return task
    }

    func testQuickSettingsChangeOnlyTheEssentials() {
        let original = task()
        var settings = QuickSettings(task: original)
        XCTAssertEqual(settings.schedule, .daily(hour: 2, minute: 0))
        settings.schedule = .daily(hour: 21, minute: 30)
        settings.allowedHours = HourRange(start: 10, end: 22)
        settings.requiresACPower = true
        settings.isEnabled = false
        let saved = settings.apply(to: original)
        XCTAssertEqual(saved.schedule, .daily(hour: 21, minute: 30))
        XCTAssertEqual(saved.conditions.allowedHours, HourRange(start: 10, end: 22))
        XCTAssertTrue(saved.conditions.requiresACPower)
        XCTAssertFalse(saved.isEnabled)
        XCTAssertEqual(saved.source, original.source)
        XCTAssertEqual(saved.destination, original.destination)
        XCTAssertEqual(saved.options, original.options)
        XCTAssertEqual(saved.id, original.id)
    }

    func testDriveTriggerOnlyForLinkedTasks() {
        XCTAssertNil(QuickSettings(task: task()).driveTrigger)
        var settings = QuickSettings(task: task(drive: true))
        XCTAssertEqual(settings.driveTrigger, .everyConnection)
        settings.driveTrigger = .atMostEveryDays(7)
        XCTAssertEqual(settings.apply(to: task(drive: true)).removableDrive?.trigger, .atMostEveryDays(7))
        var plain = QuickSettings(task: task())
        plain.driveTrigger = .atMostEveryDays(7)
        XCTAssertNil(plain.apply(to: task()).removableDrive, "lier un disque reste dans l'éditeur complet")
    }

    func testDetailWithNothingSelectedInvitesToClick() {
        XCTAssertEqual(TaskDetailView.mode(for: []), .empty)
    }

    func testDetailWithTwoSelectedShowsTheCount() {
        XCTAssertEqual(TaskDetailView.mode(for: [UUID(), UUID()]), .several(2))
        let a = UUID()
        XCTAssertEqual(TaskDetailView.mode(for: [a, TaskListView.otherRunsID]), .task(a), "la ligne « Autres exécutions » ne compte pas avec une tâche")
    }

    func testHistoryTabLoadsTheSelectedTaskOnly() {
        let a = UUID()
        XCTAssertEqual(TaskDetailView.mode(for: [a]), .task(a))
        XCTAssertEqual(TaskDetailView.mode(for: [a]).historyTarget, .some(a))
    }

    func testOtherRunsRowShowsRunsOfUnknownTasks() {
        let mode = TaskDetailView.mode(for: [TaskListView.otherRunsID])
        XCTAssertEqual(mode, .otherRuns)
        XCTAssertEqual(mode.historyTarget, .some(nil))
    }

    func testEditButtonOpensTheFullEditor() {
        var opened: SyncTask?
        let original = task()
        let tab = TaskSettingsTab(model: AgentModel.preview(status: nil), task: original, localizer: Localizer(language: "fr"),
                                  onEdit: { opened = $0 })
        tab.openEditor()
        XCTAssertEqual(opened?.id, original.id)
    }

    func testDetailRenders() throws {
        let model = UIFixtures.model()
        let id = UIFixtures.infos[0].id
        let view = TaskDetailView(model: model, selection: [id], text: UIFixtures.french, onEdit: { _ in })
        for scheme in [ColorScheme.light, .dark] {
            assertNotBlank(try render(view, name: "detail", size: CGSize(width: 900, height: 300), scheme: scheme))
        }
        assertNotBlank(try render(TaskDetailView(model: model, selection: [], text: UIFixtures.french, onEdit: { _ in }),
                                  name: "detail-empty", size: CGSize(width: 900, height: 200), scheme: .light))
    }
}
