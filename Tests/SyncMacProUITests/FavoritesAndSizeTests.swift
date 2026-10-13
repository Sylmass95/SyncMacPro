import XCTest
@testable import SyncMacProUI

final class FavoritesAndSizeTests: XCTestCase {
    func defaults() -> UserDefaults {
        let name = "favoris-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testFavoritesKeepOrderWithoutDuplicates() {
        let store = FavoritesStore(defaults: defaults())
        store.add(URL(fileURLWithPath: "/Volumes/NAS/Photos"))
        store.add(URL(fileURLWithPath: "/Users/moi/Documents"))
        store.add(URL(fileURLWithPath: "/Volumes/NAS/Photos/"))
        XCTAssertEqual(store.list().map(\.path), ["/Volumes/NAS/Photos", "/Users/moi/Documents"])
        XCTAssertTrue(store.contains(URL(fileURLWithPath: "/Users/moi/Documents")))
        store.remove(URL(fileURLWithPath: "/Volumes/NAS/Photos"))
        XCTAssertEqual(store.list().map(\.path), ["/Users/moi/Documents"])
    }

    @MainActor
    func testFavoritesModelPublishesChanges() {
        let model = FavoritesModel(store: FavoritesStore(defaults: defaults()))
        model.add(URL(fileURLWithPath: "/a"))
        XCTAssertEqual(model.favorites.map(\.path), ["/a"])
        model.remove(URL(fileURLWithPath: "/a"))
        XCTAssertTrue(model.favorites.isEmpty)
    }

    func testSizeCountsFilesAndFoldersButNotLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("photos/2024"), withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: root.appendingPathComponent("photos/a.jpg"))
        try Data(count: 500).write(to: root.appendingPathComponent("photos/2024/b.jpg"))
        try Data(count: 7).write(to: root.appendingPathComponent("note.txt"))
        let big = root.appendingPathComponent("gros.bin")
        try Data(count: 50_000).write(to: big)
        try fm.createSymbolicLink(at: root.appendingPathComponent("photos/lien.bin"), withDestinationURL: big)

        let total = try FolderSizer.total(of: [root.appendingPathComponent("photos"), root.appendingPathComponent("note.txt")])
        XCTAssertEqual(total.bytes, 1_507)
        XCTAssertEqual(total.files, 3)
        XCTAssertEqual(total.folders, 2)
    }

    func testSizeStopsWhenCancelled() async {
        let task = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try FolderSizer.total(of: [URL(fileURLWithPath: NSHomeDirectory())]); return nil } catch { return error }
        }
        let error = await task.value
        XCTAssertTrue(error is CancellationError)
    }
}
