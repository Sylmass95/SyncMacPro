import XCTest
import SyncKit
@testable import SyncMacProUI

final class TaskSummaryTextTests: XCTestCase {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    func text(_ language: String) -> TaskSummaryText {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10))!
        return TaskSummaryText(localizer: Localizer(language: language), calendar: calendar, now: now)
    }

    func task(_ mode: SyncMode, schedule: Schedule = .daily(hour: 3, minute: 0)) -> SyncTask {
        SyncTask(name: "n", source: .local(path: "/Users/moi/Photos"), destination: .network(url: "smb://nas/p", mountPath: "/Volumes/NAS/Archives"),
                 mode: mode, schedule: schedule)
    }

    func testSentences() {
        XCTAssertEqual(text("fr").sentence(for: task(.copy)),
                       "Copie les nouveautés de « Photos » vers « Archives », tous les jours à 03:00. Rien n’est supprimé.")
        XCTAssertEqual(text("fr").sentence(for: task(.mirror, schedule: .manual)),
                       "Rend « Archives » identique à « Photos », à la demande.")
        XCTAssertEqual(text("en").sentence(for: task(.copy)),
                       "Copies what is new or changed from “Photos” to “Archives”, every day at 03:00. Nothing is deleted.")
        XCTAssertTrue(text("fr").sentence(for: task(.verify)).hasSuffix("Rien n’est modifié."))
    }

    func testWarningsForDestructiveModesAndDisabledTasks() {
        XCTAssertEqual(text("fr").warnings(for: task(.copy)), [])
        XCTAssertEqual(text("fr").warnings(for: task(.mirror)).count, 1)
        XCTAssertTrue(text("fr").warnings(for: task(.mirror))[0].contains("_ARCHIVE"))
        var disabled = task(.move)
        disabled.isEnabled = false
        XCTAssertEqual(text("fr").warnings(for: disabled).count, 2)
    }

    func testEndpointLabels() {
        XCTAssertEqual(text("fr").endpointLabel(.local(path: "/")), "/")
        XCTAssertEqual(text("fr").endpointLabel(.cloud(remote: "drive", path: "")), "drive:")
        XCTAssertEqual(text("fr").endpointLabel(.cloud(remote: "drive", path: "a/b")), "drive:a/b")
    }

    func testNextRun() {
        XCTAssertEqual(text("fr").nextRun(for: task(.copy)), "demain à 03:00")
        XCTAssertEqual(text("fr").nextRun(for: task(.copy, schedule: .manual)), "Sans échéance")
        XCTAssertEqual(text("fr").nextRun(for: task(.copy, schedule: .whenAvailable)), "Dès que disponible")
    }

    func testSimulationTexts() {
        let ok = SimulationResult(status: .succeeded, filesToTransfer: 12, bytesToTransfer: 5_242_880, deletions: 3, message: nil)
        XCTAssertEqual(text("fr").simulation(ok), "12 fichier(s) à transférer (5,0 Mo), 3 suppression(s).")
        XCTAssertEqual(text("fr").deletionsWarning(ok), "Attention : 3 fichier(s) seraient supprimés.")
        XCTAssertNil(text("fr").deletionsWarning(SimulationResult(status: .succeeded, filesToTransfer: 1, bytesToTransfer: 1, deletions: 0, message: nil)))
        let failed = SimulationResult(status: .failed, filesToTransfer: 0, bytesToTransfer: 0, deletions: 0, message: "source introuvable")
        XCTAssertEqual(text("fr").simulation(failed), "La simulation a échoué : source introuvable")
        let stopped = SimulationResult(status: .stopped, filesToTransfer: 0, bytesToTransfer: 0, deletions: 0, message: nil)
        XCTAssertEqual(text("en").simulation(stopped), "Simulation cancelled.")
    }

    func testEveryProblemModeTemplateAndStepHasAText() {
        for language in ["fr", "en"] {
            let t = text(language)
            for problem in TaskProblem.allCases { XCTAssertFalse(t.problem(problem).hasPrefix("⚠︎"), problem.rawValue) }
            for mode in SyncMode.allCases {
                XCTAssertFalse(t.modeDescription(mode).hasPrefix("⚠︎"))
                XCTAssertFalse(t.modeTitle(mode).hasPrefix("⚠︎"))
            }
            for template in TaskTemplate.allCases {
                XCTAssertFalse(t.templateTitle(template).hasPrefix("⚠︎"))
                XCTAssertFalse(t.templateDescription(template).hasPrefix("⚠︎"))
            }
            for step in EditorStep.allCases { XCTAssertFalse(t.stepTitle(step).hasPrefix("⚠︎")) }
            for kind in ScheduleKind.allCases { XCTAssertFalse(t.scheduleKind(kind).hasPrefix("⚠︎")) }
            for policy in NotificationPolicy.allCases { XCTAssertFalse(t.notification(policy).hasPrefix("⚠︎")) }
        }
        XCTAssertNotNil(text("fr").modeWarning(.mirror))
        XCTAssertNil(text("fr").modeWarning(.copy))
        XCTAssertNotNil(text("fr").modeNote(.versioned))
        XCTAssertNil(text("fr").modeNote(.mirror))
    }

    func testFoldersWithTheSameNameAreShownWithTheirParent() {
        let same = SyncTask(name: "n", source: .local(path: "/Users/moi/Photos"), destination: .local(path: "/Volumes/NAS/Photos"),
                            mode: .mirror, schedule: .manual)
        XCTAssertEqual(text("fr").sentence(for: same), "Rend « NAS/Photos » identique à « moi/Photos », à la demande.")
    }
}
