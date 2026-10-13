import XCTest
@testable import SyncMacProUI

final class BrowsingTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("browse-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("App.app/Contents"), withIntermediateDirectories: true)
        try "abc".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "zz".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent(".cache"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Locked").path)
        try? FileManager.default.removeItem(at: root)
    }

    func testFoldersFirstThenFilesByName() throws {
        let items = try DirectoryLister.list(root, showHidden: false)
        XCTAssertEqual(items.map(\.name), ["Sub", "a.txt", "App.app", "b.txt"])
        XCTAssertEqual(items.first?.isDirectory, true)
        XCTAssertEqual(items.first { $0.name == "App.app" }?.isDirectory, false, "un paquet se comporte comme un fichier")
        XCTAssertEqual(items.first { $0.name == "a.txt" }?.size, 3)
        XCTAssertNil(items.first?.size, "pas de taille pour un dossier")
    }

    func testHiddenFilesOnDemand() throws {
        let items = try DirectoryLister.list(root, showHidden: true)
        XCTAssertTrue(items.contains { $0.name == ".cache" && $0.isHidden })
    }

    func testUnreadableFolderThrows() throws {
        let locked = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertThrowsError(try DirectoryLister.list(locked, showHidden: false))
    }

    func testCrumbsOnTheStartupDisk() {
        let crumbs = PathCrumbs.crumbs(for: URL(fileURLWithPath: "/Users/moi/Photos"), volumeName: { _ in "Macintosh HD" })
        XCTAssertEqual(crumbs.map(\.name), ["Macintosh HD", "Users", "moi", "Photos"])
        XCTAssertEqual(crumbs.last?.url.path, "/Users/moi/Photos")
        XCTAssertEqual(crumbs.first?.url.path, "/")
    }

    func testCrumbsOnAMountedVolume() {
        let crumbs = PathCrumbs.crumbs(for: URL(fileURLWithPath: "/Volumes/NAS/Photos/2024"), volumeName: { _ in "ignoré" })
        XCTAssertEqual(crumbs.map(\.name), ["NAS", "Photos", "2024"])
        XCTAssertEqual(crumbs.first?.url.path, "/Volumes/NAS")
    }

    func testCrumbsOfTheRoot() {
        XCTAssertEqual(PathCrumbs.crumbs(for: URL(fileURLWithPath: "/"), volumeName: { _ in "Disque" }).map(\.name), ["Disque"])
    }

    func testStandardLocationsExist() {
        let folders = StandardLocations.folders()
        XCTAssertFalse(folders.isEmpty)
        XCTAssertTrue(folders.allSatisfy { !$0.name.isEmpty })
        XCTAssertTrue(folders.contains { $0.url.path == NSHomeDirectory() })
        _ = StandardLocations.volumes()
    }
}
