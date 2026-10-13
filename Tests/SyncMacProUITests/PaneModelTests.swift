import XCTest
@testable import SyncMacProUI

@MainActor
final class PaneModelTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pane-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sub/Deep"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", ".hidden"] {
            try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Locked").path)
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func testOpensAndGoesUp() async {
        let pane = PaneModel(folder: root)
        await pane.settled()
        XCTAssertEqual(pane.items.map(\.name), ["Sub", "a.txt", "b.txt", "c.txt", "d.txt"])
        pane.open(url("Sub"))
        await pane.settled()
        XCTAssertEqual(pane.items.map(\.name), ["Deep"])
        pane.goUp()
        await pane.settled()
        XCTAssertEqual(pane.folder.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertNil(pane.problem)
    }

    func testHiddenFilesToggle() async {
        let pane = PaneModel(folder: root)
        await pane.settled()
        pane.showHidden = true
        await pane.settled()
        XCTAssertTrue(pane.items.contains { $0.name == ".hidden" })
        pane.showHidden = false
        await pane.settled()
        XCTAssertFalse(pane.items.contains { $0.name == ".hidden" })
    }

    func testClickSelectionWithCommandAndShift() async {
        let pane = PaneModel(folder: root)
        await pane.settled()
        pane.click(url("a.txt"), command: false, shift: false)
        XCTAssertEqual(pane.selection, [url("a.txt")])
        pane.click(url("c.txt"), command: true, shift: false)
        XCTAssertEqual(pane.selection, [url("a.txt"), url("c.txt")])
        pane.click(url("a.txt"), command: true, shift: false)
        XCTAssertEqual(pane.selection, [url("c.txt")])
        pane.click(url("b.txt"), command: false, shift: false)
        pane.click(url("d.txt"), command: false, shift: true)
        XCTAssertEqual(pane.selection, [url("b.txt"), url("c.txt"), url("d.txt")], "⇧ : plage depuis le dernier clic")
        pane.selectAll()
        XCTAssertEqual(pane.selection.count, 5)
        XCTAssertEqual(pane.selectedItems.map(\.name), ["Sub", "a.txt", "b.txt", "c.txt", "d.txt"])
    }

    func testOpeningAFolderClearsTheSelection() async {
        let pane = PaneModel(folder: root)
        await pane.settled()
        pane.click(url("a.txt"), command: false, shift: false)
        pane.open(url("Sub"))
        await pane.settled()
        XCTAssertTrue(pane.selection.isEmpty)
    }

    func testSelectionKeepsOnlyExistingItemsAfterReload() async throws {
        let pane = PaneModel(folder: root)
        await pane.settled()
        pane.click(url("a.txt"), command: false, shift: false)
        pane.click(url("b.txt"), command: true, shift: false)
        try FileManager.default.removeItem(at: url("a.txt"))
        pane.reload()
        await pane.settled()
        XCTAssertEqual(pane.selection, [url("b.txt")])
    }

    func testUnreadableFolder() async throws {
        let locked = url("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let pane = PaneModel(folder: root)
        await pane.settled()
        pane.open(locked)
        await pane.settled()
        XCTAssertEqual(pane.problem, .unreadable)
        XCTAssertTrue(pane.items.isEmpty)
    }

    func testVanishedFolderClimbsToTheFirstExistingParent() async throws {
        let pane = PaneModel(folder: root)
        await pane.settled()
        pane.open(url("Sub/Deep"))
        await pane.settled()
        try FileManager.default.removeItem(at: url("Sub"))
        pane.reload()
        await pane.settled()
        XCTAssertEqual(pane.problem, .vanished)
        XCTAssertEqual(pane.folder.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertFalse(pane.items.isEmpty)
    }
}
