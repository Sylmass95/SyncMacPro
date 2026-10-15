import XCTest
@testable import SyncMacProUI

final class UpdatesTests: XCTestCase {
    func testVersions() throws {
        let v = try XCTUnwrap(SemanticVersion("v1.2.3"))
        XCTAssertEqual(v.description, "1.2.3")
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.2.9")), try XCTUnwrap(SemanticVersion("1.10.0")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("2.0.0-beta")), try XCTUnwrap(SemanticVersion("2.0.0")))
        XCTAssertNil(SemanticVersion("dev"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertEqual(SemanticVersion("1.0.0 (321)"), SemanticVersion("1.0.0"), "le numéro de construction est ignoré")
    }

    func testInstallLocation() {
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Applications/SyncMacPro.app"))
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Users/moi/Applications/SyncMacPro.app"))
        XCTAssertEqual(InstallLocation.problem(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/SyncMacPro.app"), .translocated)
        XCTAssertEqual(InstallLocation.problem(bundlePath: "/Volumes/SyncMacPro 1.0.0/SyncMacPro.app", isReadOnlyVolume: { _ in true }), .diskImage)
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Users/moi/Desktop/PROJET/.build/debug/SyncMacPro"), "développement : pas un bundle")
    }
}
