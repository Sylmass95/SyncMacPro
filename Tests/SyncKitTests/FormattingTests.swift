import XCTest
@testable import SyncKit

final class FormattingTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Formatting.bytes(0), "0 o")
        XCTAssertEqual(Formatting.bytes(1_023), "1023 o")
        XCTAssertEqual(Formatting.bytes(2_048), "2 Ko")
        XCTAssertEqual(Formatting.bytes(5_242_880), "5,0 Mo")
        XCTAssertEqual(Formatting.bytes(1_073_741_824), "1,00 Go")
        XCTAssertEqual(Formatting.bytes(139_100_000_000), "129,55 Go")
    }

    func testSpeed() { XCTAssertEqual(Formatting.speed(10 * 1_048_576), "10,0 Mo/s") }

    func testClock() {
        XCTAssertEqual(Formatting.clock(0), "0:00")
        XCTAssertEqual(Formatting.clock(65), "1:05")
        XCTAssertEqual(Formatting.clock(3_725), "1:02:05")
        XCTAssertEqual(Formatting.clock(-3), "0:00")
    }

    func testEta() {
        XCTAssertEqual(Formatting.eta(0.2), "1 s")
        XCTAssertEqual(Formatting.eta(45), "45 s")
        XCTAssertEqual(Formatting.eta(150), "~3 min")
        XCTAssertEqual(Formatting.eta(3_900), "~1 h 05")
    }

    func testLineForSnapshot() {
        var snap = TransferSnapshot()
        snap.currentName = "clip.mov"
        snap.currentPercent = 42
        snap.currentBytes = 5_242_880
        snap.currentSize = 12_582_912
        snap.currentSpeed = 10 * 1_048_576
        snap.currentETA = 3
        snap.totalFiles = 10
        snap.filesDone = 3
        snap.overallPercent = 25
        snap.totalBytes = 4_294_967_296
        snap.doneBytes = 1_073_741_824
        snap.averageSpeed = 20 * 1_048_576
        snap.totalETA = 150
        XCTAssertEqual(
            Formatting.line(for: snap),
            "clip.mov 42 %  5,0 Mo / 12,0 Mo  10,0 Mo/s  restant 0:03  |  total 3/10 fichiers 25 %  1,00 Go / 4,00 Go  moy. 20,0 Mo/s  ~3 min"
        )
    }

    func testLineOfAnEmptySnapshotIsEmpty() { XCTAssertEqual(Formatting.line(for: TransferSnapshot()), "") }
}
