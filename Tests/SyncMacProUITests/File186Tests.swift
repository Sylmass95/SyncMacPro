import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.8.6 : la colonne État montre aussi l'avancement du fichier en cours (barre, volume, pourcentage, débit, reste).
@MainActor
final class File186Tests: XCTestCase {
    func progress() -> ProgressInfo {
        var p = ProgressInfo(TransferSnapshot())
        p.doneBytes = 85_000_000_000
        p.totalBytes = 200_000_000_000
        p.overallPercent = 42
        p.currentName = "SOFTS/Virtual Machines.localized/UTM/disque.img"
        p.currentSize = 55_283_023_872
        p.currentBytes = 11_056_604_774
        p.currentSpeed = 11_534_336
        return p
    }

    func testTheCurrentFileHasItsOwnProgress() throws {
        let file = try XCTUnwrap(TaskRow.currentFile(progress(), text: UIFixtures.french))
        XCTAssertEqual(file.name, "SOFTS/Virtual Machines.localized/UTM/disque.img")
        XCTAssertEqual(file.fraction, 0.2, accuracy: 0.001)
        XCTAssertTrue(file.line.hasPrefix("10,30 Go sur 51,49 Go · 20 % · 11,0 Mo/s · reste "), file.line)
    }

    func testTheNameIsNotRepeatedInTheOverallLines() {
        XCTAssertFalse(TaskRow.progressLines(progress(), text: UIFixtures.french).contains { $0.contains("disque.img") })
    }

    func testWithoutItsSizeOnlyTheNameIsShown() {
        var p = progress(); p.currentSize = 0
        XCTAssertNil(TaskRow.currentFile(p, text: UIFixtures.french))
        XCTAssertTrue(TaskRow.progressLines(p, text: UIFixtures.french).contains("SOFTS/Virtual Machines.localized/UTM/disque.img"))
    }

    func testRenders() throws {
        var info = AgentTaskInfo(id: UUID(), name: "NAS 03_ARCHIVES → Drive", state: .running); info.rank = 1
        let row = TaskRow(info: info, task: nil, progress: progress(), busy: false, text: UIFixtures.french, actions: TaskCardActions())
        assertNotBlank(try render(row, name: "row-file-186", size: CGSize(width: 1000, height: 150), scheme: .light))
    }
}
