import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class Check184UITests: XCTestCase {
    func testTheRowSaysWhichFileIsBeingChecked() {
        var snap = TransferSnapshot()
        snap.checkingName = "EVENTS/VIDEOS/C2263.MP4"
        snap.checkingSize = 79_862_671_232
        let lines = TaskRow.progressLines(ProgressInfo(snap), text: UIFixtures.french)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Vérification de « EVENTS/VIDEOS/C2263.MP4 » (") && $0.hasSuffix("déjà à la destination") }, "\(lines)")
    }

    func testNoCheckLineWhileAFileIsCopied() {
        var snap = TransferSnapshot()
        snap.currentName = "a.mov"
        snap.checkingName = "b.mov"
        XCTAssertFalse(TaskRow.progressLines(ProgressInfo(snap), text: UIFixtures.french).contains { $0.contains("Vérification") })
    }
}
