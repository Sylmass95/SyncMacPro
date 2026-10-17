import XCTest
@testable import SyncMacProUI

final class LocalizerTests: XCTestCase {
    let fr = Localizer(language: "fr")
    let en = Localizer(language: "en")

    func testTextInBothLanguages() {
        XCTAssertEqual(fr.text("sidebar.dashboard"), "Tableau de bord")
        XCTAssertEqual(en.text("sidebar.dashboard"), "Dashboard")
    }

    func testUnknownKeyIsVisible() {
        XCTAssertEqual(fr.text("cle.inexistante"), "⚠︎cle.inexistante")
    }

    func testFormatInsertsArguments() {
        XCTAssertEqual(fr.format("relative.hours", 2), "il y a 2 h")
        XCTAssertEqual(en.format("relative.hours", 2), "2 h ago")
        XCTAssertEqual(fr.format("state.waiting", "réseau"), "En attente : réseau")
    }

    func testBytesUseTheLanguageUnitsAndSeparator() {
        XCTAssertEqual(fr.bytes(512), "512 o")
        XCTAssertEqual(en.bytes(512), "512 B")
        XCTAssertEqual(fr.bytes(5_242_880), "5,0 Mo")
        XCTAssertEqual(en.bytes(5_242_880), "5.0 MB")
        XCTAssertEqual(fr.bytes(3_221_225_472), "3,00 Go")
    }

    func testSpeedAndDuration() {
        XCTAssertEqual(en.speed(2_097_152), "2.0 MB/s")
        XCTAssertEqual(fr.duration(65), "1:05")
        XCTAssertEqual(fr.duration(3725), "1:02:05")
        XCTAssertEqual(fr.duration(0), "0:00")
        // 1.6.5 : un débit presque nul donnait une durée restante énorme ou infinie, et l'app plantait (essai réel).
        XCTAssertEqual(fr.duration(.infinity), "—")
        XCTAssertEqual(fr.duration(.nan), "—")
        XCTAssertEqual(fr.duration(1e300), "—")
        XCTAssertEqual(fr.longDuration(.infinity), "—")
    }
}
