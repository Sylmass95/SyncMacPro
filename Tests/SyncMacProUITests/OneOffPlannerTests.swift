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
}
