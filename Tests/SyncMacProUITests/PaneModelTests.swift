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

    func testOpensAndGoesUp() {
        let pane = PaneModel(folder: root)
        XCTAssertEqual(pane.items.map(\.name), ["Sub", "a.txt", "b.txt", "c.txt", "d.txt"])
        pane.open(url("Sub"))
        XCTAssertEqual(pane.items.map(\.name), ["Deep"])
        pane.goUp()
        XCTAssertEqual(pane.folder.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertNil(pane.problem)
    }

    func testHiddenFilesToggle() {
        let pane = PaneModel(folder: root)
        pane.showHidden = true
        XCTAssertTrue(pane.items.contains { $0.name == ".hidden" })
        pane.showHidden = false
        XCTAssertFalse(pane.items.contains { $0.name == ".hidden" })
    }

    func testClickSelectionWithCommandAndShift() {
        let pane = PaneModel(folder: root)
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

    func testOpeningAFolderClearsTheSelection() {
        let pane = PaneModel(folder: root)
        pane.click(url("a.txt"), command: false, shift: false)
        pane.open(url("Sub"))
        XCTAssertTrue(pane.selection.isEmpty)
    }

    func testSelectionKeepsOnlyExistingItemsAfterReload() throws {
        let pane = PaneModel(folder: root)
        pane.click(url("a.txt"), command: false, shift: false)
        pane.click(url("b.txt"), command: true, shift: false)
        try FileManager.default.removeItem(at: url("a.txt"))
        pane.reload()
        XCTAssertEqual(pane.selection, [url("b.txt")])
    }

    func testUnreadableFolder() throws {
        let locked = url("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let pane = PaneModel(folder: root)
        pane.open(locked)
        XCTAssertEqual(pane.problem, .unreadable)
        XCTAssertTrue(pane.items.isEmpty)
    }

    func testVanishedFolderClimbsToTheFirstExistingParent() throws {
        let pane = PaneModel(folder: root)
        pane.open(url("Sub/Deep"))
        try FileManager.default.removeItem(at: url("Sub"))
        pane.reload()
        XCTAssertEqual(pane.problem, .vanished)
        XCTAssertEqual(pane.folder.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertFalse(pane.items.isEmpty)
    }
}
