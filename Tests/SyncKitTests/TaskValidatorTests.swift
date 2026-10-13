import XCTest
@testable import SyncKit

final class TaskValidatorTests: XCTestCase {
    func task(
        _ name: String = "t", source: Endpoint = .local(path: "/a"), destination: Endpoint = .local(path: "/b"),
        mode: SyncMode = .copy, schedule: Schedule = .manual
    ) -> SyncTask {
        SyncTask(name: name, source: source, destination: destination, mode: mode, schedule: schedule)
    }

    func testAValidTaskHasNoProblem() {
        XCTAssertEqual(TaskValidator.problems(in: task()), [])
        XCTAssertEqual(TaskValidator.problems(in: task(destination: .cloud(remote: "drive", path: "x"))), [])
    }

    func testNameAndEndpointsAreRequired() {
        XCTAssertEqual(TaskValidator.problems(in: task("  ")), [.emptyName])
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: ""))), [.missingSource])
        XCTAssertEqual(TaskValidator.problems(in: task(destination: .cloud(remote: " ", path: "x"))), [.missingDestination])
    }

    func testSameFolderIsRefusedEvenWrittenDifferently() {
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: "/a/b"), destination: .local(path: "/a/b/"))),
                       [.sameSourceAndDestination])
        XCTAssertEqual(TaskValidator.problems(in: task(source: .cloud(remote: "d", path: "x"), destination: .cloud(remote: "d", path: "x"))),
                       [.sameSourceAndDestination])
    }

    func testNestedFoldersAreRefusedInBothDirections() {
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: "/Users/moi/Photos"),
                                                       destination: .local(path: "/Users/moi/Photos/Sauvegarde"))), [.nestedFolders])
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: "/Volumes/NAS/a/b"),
                                                       destination: .network(url: "smb://nas/a", mountPath: "/Volumes/NAS/a"))), [.nestedFolders])
        XCTAssertEqual(TaskValidator.problems(in: task(source: .local(path: "/a/photos"), destination: .local(path: "/a/photos-old"))), [],
                       "un préfixe de nom n'est pas un dossier parent")
    }

    func testEngineMismatchIsReported() {
        var forced = task(mode: .bidirectional)
        forced.options.forcedEngine = .rsync
        XCTAssertEqual(TaskValidator.problems(in: forced), [.engineMismatch])
    }

    func testThresholdAndScheduleAreChecked() {
        var bad = task(schedule: .weekdays(days: [], hour: 8, minute: 0))
        bad.options.deleteThresholdPercent = 0
        XCTAssertEqual(TaskValidator.problems(in: bad), [.invalidThreshold, .invalidSchedule])
        XCTAssertEqual(TaskValidator.problems(in: task(schedule: .daily(hour: 24, minute: 0))), [.invalidSchedule])
        XCTAssertEqual(TaskValidator.problems(in: task(schedule: .everyMinutes(0))), [.invalidSchedule])
        XCTAssertEqual(TaskValidator.problems(in: task(schedule: .weekdays(days: [8], hour: 8, minute: 0))), [.invalidSchedule])
    }

    func testEveryProblemHasAFrenchMessage() {
        for problem in TaskProblem.allCases { XCTAssertFalse(problem.message.isEmpty, problem.rawValue) }
    }
}
