import XCTest
import SyncKit
@testable import SyncMacProUI

final class TaskDraftTests: XCTestCase {
    let nas = EndpointResolver { url in
        url.path.hasPrefix("/Volumes/NAS")
            ? .init(isLocal: false, remountURL: URL(string: "smb://nas/partage"))
            : .init(isLocal: true, remountURL: nil)
    }

    func fullTask() -> SyncTask {
        var options = TaskOptions(excludes: ["*.tmp", ".DS_Store"], bandwidthLimitKBps: 500, verifyAfterCopy: true,
                                  deleteThresholdPercent: 40, archiveFolder: "_OLD", retentionDays: 30, maxTransferGB: 750)
        options.extraArguments = ["--checksum"]
        return SyncTask(name: "Photos", source: .local(path: "/Users/moi/Photos"),
                        destination: .cloud(remote: "drive", path: "Sauvegardes"), sourceItems: ["2024"],
                        mode: .mirror, options: options, schedule: .weekdays(days: [2, 6], hour: 8, minute: 30),
                        notifications: .errorsOnly,
                        conditions: TaskConditions(requiresACPower: true, requiresNetwork: true, allowedHours: HourRange(start: 22, end: 6)),
                        isEnabled: false)
    }

    func testRoundTripKeepsEveryField() {
        let task = fullTask()
        XCTAssertEqual(TaskDraft(task: task).task(resolver: .localOnly), task)
    }

    func testFolderOnANetworkVolumeBecomesANetworkEndpoint() {
        var draft = TaskDraft()
        draft.source.path = "/Users/moi/Photos"
        draft.destination.path = "/Volumes/NAS/Photos"
        let task = draft.task(resolver: nas)
        XCTAssertEqual(task.source, .local(path: "/Users/moi/Photos"))
        XCTAssertEqual(task.destination, .network(url: "smb://nas/partage", mountPath: "/Volumes/NAS/Photos"))
        XCTAssertEqual(TaskDraft(task: task).destination, SideDraft(kind: .folder, path: "/Volumes/NAS/Photos"))
    }

    func testDuplicateGetsANewIdentityAndName() {
        let task = fullTask()
        let copy = TaskDraft.duplicate(of: task, suffix: "(copie)")
        XCTAssertNotEqual(copy.id, task.id)
        XCTAssertEqual(copy.name, "Photos (copie)")
        XCTAssertEqual(copy.mode, task.mode)
        XCTAssertEqual(copy.options, task.options)
    }

    func testTemplates() {
        let nasCopy = TaskDraft.template(.copyToNAS)
        XCTAssertEqual(nasCopy.mode, .copy)
        XCTAssertEqual(nasCopy.scheduleDraft.schedule, .daily(hour: 3, minute: 0))
        XCTAssertTrue(nasCopy.conditions.requiresNetwork)
        let sync = TaskDraft.template(.syncTwoFolders)
        XCTAssertEqual(sync.mode, .bidirectional)
        XCTAssertEqual(sync.scheduleDraft.schedule, .everyMinutes(60))
        let drive = TaskDraft.template(.backupToDrive)
        XCTAssertEqual(drive.destination, SideDraft(kind: .cloud, path: "SyncMacPro", remote: "drive"))
        XCTAssertEqual(drive.options.maxTransferGB, 750)
        XCTAssertEqual(TaskTemplate.allCases.count, 3)
    }

    func testScheduleDraftRoundTrips() {
        let schedules: [Schedule] = [.manual, .whenAvailable, .everyMinutes(15), .daily(hour: 3, minute: 5),
                                     .weekdays(days: [1, 7], hour: 22, minute: 0)]
        for schedule in schedules { XCTAssertEqual(ScheduleDraft(schedule).schedule, schedule) }
        var draft = ScheduleDraft(.manual)
        draft.kind = .daily
        XCTAssertEqual(draft.schedule, .daily(hour: 3, minute: 0), "valeurs par défaut sensées")
    }

    func testProblemsAreSortedByStep() {
        var draft = TaskDraft()
        XCTAssertEqual(draft.problems(for: .endpoints, resolver: .localOnly), [.missingSource, .missingDestination])
        XCTAssertEqual(draft.problems(for: .mode, resolver: .localOnly), [])
        XCTAssertEqual(draft.problems(for: .summary, resolver: .localOnly), [.emptyName])
        draft.source.path = "/a"
        draft.destination.path = "/a/b"
        XCTAssertEqual(draft.problems(for: .endpoints, resolver: .localOnly), [.nestedFolders])
        draft.destination.path = "/b"
        draft.scheduleDraft.kind = .weekdays
        draft.scheduleDraft.days = []
        XCTAssertEqual(draft.problems(for: .schedule, resolver: .localOnly), [.invalidSchedule])
    }

    func testTextFields() {
        var draft = TaskDraft()
        draft.excludesText = "*.tmp\n\n  cache/  \n"
        XCTAssertEqual(draft.options.excludes, ["*.tmp", "cache/"])
        draft.bandwidthText = "200"
        XCTAssertEqual(draft.options.bandwidthLimitKBps, 200)
        draft.bandwidthText = "abc"
        XCTAssertNil(draft.options.bandwidthLimitKBps)
        draft.bandwidthText = "0"
        XCTAssertNil(draft.options.bandwidthLimitKBps)
        draft.maxTransferText = "750"
        XCTAssertEqual(draft.options.maxTransferGB, 750)
        draft.retentionText = "30"
        XCTAssertEqual(draft.retentionText, "30")
    }

    func testNameIsSuggestedOnlyWhenEmpty() {
        var draft = TaskDraft()
        draft.source.path = "/Users/moi/Photos"
        draft.destination = SideDraft(kind: .cloud, path: "Sauvegardes", remote: "drive")
        draft.fillNameIfNeeded()
        XCTAssertEqual(draft.name, "Photos → drive:Sauvegardes")
        draft.name = "Mon nom"
        draft.fillNameIfNeeded()
        XCTAssertEqual(draft.name, "Mon nom")
    }
}
