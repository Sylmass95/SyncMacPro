import XCTest
@testable import SyncMacProUI

/// Relecture 3c : la lecture d'un dossier se faisait sur le fil principal — un NAS qui ne répond plus figeait l'app.
@MainActor
final class Fix120PaneTests: XCTestCase {
    func testSlowFolderDoesNotBlockTheInterface() async {
        let slow: PaneModel.Lister = { _, _ in
            Thread.sleep(forTimeInterval: 1)
            return [DirectoryItem(url: URL(fileURLWithPath: "/nas/a"), name: "a", isDirectory: false, size: 1, modified: nil, isHidden: false)]
        }
        let started = Date()
        let pane = PaneModel(folder: URL(fileURLWithPath: "/nas"), lister: slow, exists: { _ in true })
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3, "la création ne doit pas attendre la lecture")
        XCTAssertTrue(pane.isLoading)
        await pane.settled()
        XCTAssertFalse(pane.isLoading)
        XCTAssertEqual(pane.items.map(\.name), ["a"])
    }

    func testAnOlderSlowListingNeverReplacesANewerOne() async {
        let lister: PaneModel.Lister = { url, _ in
            if url.path == "/lent" { Thread.sleep(forTimeInterval: 0.6) }
            return [DirectoryItem(url: url.appendingPathComponent("x"), name: url.lastPathComponent, isDirectory: false, size: nil, modified: nil, isHidden: false)]
        }
        let pane = PaneModel(folder: URL(fileURLWithPath: "/lent"), lister: lister, exists: { _ in true })
        pane.open(URL(fileURLWithPath: "/rapide"))
        await pane.settled()
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(pane.folder.path, "/rapide")
        XCTAssertEqual(pane.items.map(\.name), ["rapide"], "la lecture lente de l'ancien dossier arrive après et doit être ignorée")
    }
}
