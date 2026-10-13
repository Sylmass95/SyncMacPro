import XCTest
import SyncKit
@testable import SyncMacProUI

final class OneOffPlannerTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func testSelectionFromOneFolderIsOneCopy() {
        let tasks = OneOffPlanner.copyTasks(
            items: [URL(fileURLWithPath: "/Users/moi/Photos/a.jpg"), URL(fileURLWithPath: "/Users/moi/Photos/2024")],
            to: URL(fileURLWithPath: "/Volumes/NAS/Photos"), resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].source, .local(path: "/Users/moi/Photos"))
        XCTAssertEqual(tasks[0].destination, .local(path: "/Volumes/NAS/Photos"))
        XCTAssertEqual(tasks[0].sourceItems, ["2024", "a.jpg"])
        XCTAssertEqual(tasks[0].mode, .copy)
        XCTAssertEqual(tasks[0].schedule, .manual)
        XCTAssertEqual(tasks[0].name, "Copie de 2 éléments vers Photos")
        XCTAssertEqual(TaskValidator.problems(in: tasks[0]), [])
    }

    func testItemsFromSeveralFoldersGiveOneCopyPerFolder() {
        let tasks = OneOffPlanner.copyTasks(
            items: [URL(fileURLWithPath: "/a/x.txt"), URL(fileURLWithPath: "/b/y.txt"), URL(fileURLWithPath: "/a/z.txt")],
            to: URL(fileURLWithPath: "/dest"), resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(tasks.map(\.source), [.local(path: "/a"), .local(path: "/b")])
        XCTAssertEqual(tasks.map(\.sourceItems), [["x.txt", "z.txt"], ["y.txt"]])
        XCTAssertEqual(tasks[1].name, "Copie de y.txt vers dest")
        XCTAssertNotEqual(tasks[0].id, tasks[1].id)
    }

    func testCopyingAFolderIntoItselfIsRefused() {
        let tasks = OneOffPlanner.copyTasks(
            items: [URL(fileURLWithPath: "/a/photos")], to: URL(fileURLWithPath: "/a/photos/copie"),
            resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(TaskValidator.problems(in: tasks[0]), [.nestedFolders])
    }

    func testSyncIsAMirrorOfTheWholeFolder() {
        let task = OneOffPlanner.syncTask(
            from: URL(fileURLWithPath: "/Users/moi/Photos"), to: URL(fileURLWithPath: "/Volumes/NAS/Photos"),
            acceptDeletions: false, resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(task.mode, .mirror)
        XCTAssertEqual(task.sourceItems, [])
        XCTAssertEqual(task.options.deleteThresholdPercent, TaskOptions().deleteThresholdPercent)
        XCTAssertEqual(task.name, "Synchronisation de Photos vers Photos")
        let accepted = OneOffPlanner.syncTask(
            from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b"), acceptDeletions: true,
            resolver: .localOnly, localizer: fr
        )
        XCTAssertEqual(accepted.options.deleteThresholdPercent, 100)
    }

    func testDroppableKeepsOnlyWhatCanBeCopiedThere() {
        let folder = URL(fileURLWithPath: "/dest/photos")
        let dropped = [
            URL(fileURLWithPath: "/a/x.txt"),
            URL(fileURLWithPath: "/dest/photos/deja.txt"),
            URL(fileURLWithPath: "/dest/photos"),
            URL(fileURLWithPath: "/dest"),
            URL(string: "https://exemple.fr/page")!,
        ]
        XCTAssertEqual(OneOffPlanner.droppable(dropped, into: folder).map(\.path), ["/a/x.txt"])
    }

    func testSimulationsAreSummed() {
        let a = SimulationResult(status: .succeeded, filesToTransfer: 2, bytesToTransfer: 100, deletions: 0, message: nil)
        let b = SimulationResult(status: .succeeded, filesToTransfer: 3, bytesToTransfer: 50, deletions: 1, message: nil)
        XCTAssertEqual(OneOffPlanner.combine([.finished(a), .finished(b)]),
                       .finished(SimulationResult(status: .succeeded, filesToTransfer: 5, bytesToTransfer: 150, deletions: 1, message: nil)))
        XCTAssertEqual(OneOffPlanner.combine([.finished(a), .failed("source introuvable")]), .failed("source introuvable"))
        let blocked = SimulationResult(status: .blocked, filesToTransfer: 0, bytesToTransfer: 0, deletions: 9, message: "seuil")
        XCTAssertEqual(OneOffPlanner.combine([.finished(a), .finished(blocked)]).status, .blocked)
    }

    func testRequestsBecomeTasks() {
        let copy = CopyRequest.copy(items: [URL(fileURLWithPath: "/a/x.txt")], to: URL(fileURLWithPath: "/b"))
        XCTAssertEqual(OneOffPlanner.tasks(for: copy, acceptDeletions: false, resolver: .localOnly, localizer: fr).map(\.sourceItems), [["x.txt"]])
        let sync = CopyRequest.sync(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b"))
        let tasks = OneOffPlanner.tasks(for: sync, acceptDeletions: true, resolver: .localOnly, localizer: fr)
        XCTAssertEqual(tasks.map(\.mode), [.mirror])
        XCTAssertEqual(tasks.first?.options.deleteThresholdPercent, 100)
    }
}

private extension SimulationOutcome {
    var status: RunStatus? {
        if case .finished(let result) = self { return result.status }
        return nil
    }
}
