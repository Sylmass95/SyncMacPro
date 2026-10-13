import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class CopyRenderTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func items() -> [DirectoryItem] {
        let base = URL(fileURLWithPath: "/Users/moi/Photos")
        return [
            DirectoryItem(url: base.appendingPathComponent("2024"), name: "2024", isDirectory: true, size: nil,
                          modified: Date(timeIntervalSince1970: 1_700_000_000), isHidden: false),
            DirectoryItem(url: base.appendingPathComponent("plage.jpg"), name: "plage.jpg", isDirectory: false,
                          size: 3_400_000, modified: Date(timeIntervalSince1970: 1_700_000_000), isHidden: false),
        ]
    }

    func noMenu(_ item: DirectoryItem) -> PaneMenu {
        PaneMenu(copyToOther: {}, simulate: {}, open: nil, addFavorite: nil, reveal: {})
    }

    func testFileListRenders() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = FileListBody(
                items: items(), selection: [items()[1].url], problem: nil, localizer: fr,
                onClick: { _, _, _ in }, onOpen: { _ in }, menu: noMenu
            )
            assertNotBlank(try render(view, name: "copy-list", size: CGSize(width: 420, height: 200), scheme: scheme))
        }
    }

    func testProblemsRender() throws {
        for problem in [PaneProblem.unreadable, .vanished] {
            let view = FileListBody(items: [], selection: [], problem: problem, localizer: fr,
                                    onClick: { _, _, _ in }, onOpen: { _ in }, menu: noMenu)
            assertNotBlank(try render(view, name: "copy-problem-\(problem)", size: CGSize(width: 420, height: 160), scheme: .light))
        }
    }

    func testPathBarRenders() throws {
        let crumbs = PathCrumbs.crumbs(for: URL(fileURLWithPath: "/Volumes/NAS/Photos/2024"))
        let view = PathBar(crumbs: crumbs, onOpen: { _ in })
        assertNotBlank(try render(view, name: "copy-path", size: CGSize(width: 420, height: 32), scheme: .light))
    }

    func testStatusBarRendersEveryState() throws {
        let states: [SizeState] = [.none, .computing, .done(SizeTotal(bytes: 3_400_000, files: 12, folders: 2)), .failed]
        for (index, state) in states.enumerated() {
            let view = CopyStatusBar(count: index == 0 ? 0 : 3, size: state, free: 120_000_000_000, localizer: fr)
            assertNotBlank(try render(view, name: "copy-status-\(index)", size: CGSize(width: 700, height: 32), scheme: .light))
        }
    }

    func testStatusBarSentences() {
        XCTAssertEqual(CopyStatusBar.sizeText(.done(SizeTotal(bytes: 2_000, files: 3, folders: 1)), localizer: fr),
                       "3 fichiers, \(fr.bytes(2_000))")
        XCTAssertEqual(CopyStatusBar.sizeText(.computing, localizer: fr), "Calcul de la taille…")
        XCTAssertNil(CopyStatusBar.sizeText(.none, localizer: fr))
    }

    func testFreeSpaceOfTheHomeFolder() {
        XCTAssertGreaterThan(FreeSpace.available(at: URL(fileURLWithPath: NSHomeDirectory())) ?? 0, 0)
        XCTAssertNil(FreeSpace.available(at: URL(fileURLWithPath: "/n-existe-pas-\(UUID().uuidString)")))
    }
}
