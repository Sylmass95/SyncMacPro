import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.7.3 : la ligne d'une copie n'affichait qu'une barre (51 Go copiés sur 539 paraissaient « 0 octet ») : elle donne
/// maintenant le pourcentage, le volume, le débit, le temps restant et le fichier en cours.
@MainActor
final class Progress173Tests: XCTestCase {
    func progress() -> ProgressInfo {
        var p = ProgressInfo(TransferSnapshot())
        p.doneBytes = 1_073_741_824
        p.totalBytes = 3_221_225_472
        p.currentSpeed = 47_185_920
        p.totalETA = 12
        p.overallPercent = 33
        p.currentName = "BEHIND_THE_STREAMS/C0070.MP4"
        return p
    }

    func testTheRowShowsPercentVolumeSpeedAndFile() {
        let lines = TaskRow.progressLines(progress(), text: UIFixtures.french)
        XCTAssertEqual(lines.first, "33 % · 1,00 Go sur 3,00 Go · 45,0 Mo/s · reste 0:12")
        XCTAssertEqual(lines.last, "BEHIND_THE_STREAMS/C0070.MP4")
    }

    func testWithoutATotalItSaysWhatIsCopied() {
        var p = progress()
        p.totalBytes = nil
        p.overallPercent = nil
        p.currentName = nil
        XCTAssertEqual(TaskRow.progressLines(p, text: UIFixtures.french), ["1,00 Go copiés"])
    }

    func testARowWithProgressRenders() throws {
        var info = AgentTaskInfo(id: UUID(), name: "NAS 01_PROJETS_ACTIFS → Drive", state: .running)
        info.rank = 1
        let row = TaskRow(info: info, task: nil, progress: progress(), busy: false, text: UIFixtures.french, actions: TaskCardActions())
        assertNotBlank(try render(row, name: "row-progress", size: CGSize(width: 900, height: 80), scheme: .light))
    }
}
