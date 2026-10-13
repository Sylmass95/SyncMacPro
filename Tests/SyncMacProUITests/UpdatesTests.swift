import XCTest
@testable import SyncMacProUI

final class UpdatesTests: XCTestCase {
    func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "github_release_latest", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

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

    func testNewerReleaseIsOffered() throws {
        let result = UpdateChecker.parse(try fixture(), status: 200, current: SemanticVersion("1.0.0"))
        XCTAssertEqual(result, .available(ReleaseInfo(
            version: try XCTUnwrap(SemanticVersion("1.2.0")),
            url: try XCTUnwrap(URL(string: "https://github.com/Sylmass95/SyncMacPro/releases/tag/v1.2.0"))
        )))
        XCTAssertEqual(UpdateChecker.parse(try fixture(), status: 200, current: SemanticVersion("1.2.0")), .upToDate)
        XCTAssertEqual(UpdateChecker.parse(try fixture(), status: 200, current: SemanticVersion("1.3.0")), .upToDate)
    }

    func testDevBuildsAreNeverNagged() throws {
        XCTAssertEqual(UpdateChecker.parse(try fixture(), status: 200, current: nil), .upToDate)
    }

    func testUnusableAnswers() throws {
        XCTAssertEqual(UpdateChecker.parse(Data(), status: 404, current: SemanticVersion("1.0.0")), .upToDate, "aucune publication")
        guard case .failed = UpdateChecker.parse(Data(#"{"message":"API rate limit exceeded"}"#.utf8), status: 403, current: SemanticVersion("1.0.0")) else {
            return XCTFail()
        }
        guard case .failed = UpdateChecker.parse(Data("<html>".utf8), status: 200, current: SemanticVersion("1.0.0")) else { return XCTFail() }
        let draft = Data(#"{"tag_name":"v9.0.0","html_url":"https://x","draft":true,"prerelease":false}"#.utf8)
        XCTAssertEqual(UpdateChecker.parse(draft, status: 200, current: SemanticVersion("1.0.0")), .upToDate)
        let beta = Data(#"{"tag_name":"v9.0.0-beta","html_url":"https://x","draft":false,"prerelease":true}"#.utf8)
        XCTAssertEqual(UpdateChecker.parse(beta, status: 200, current: SemanticVersion("1.0.0")), .upToDate)
    }

    func testCheckUsesTheFetcher() async throws {
        let data = try fixture()
        let checker = UpdateChecker(current: "1.0.0 (12)") { url in
            XCTAssertEqual(url, UpdateChecker.latestURL)
            return (data, 200)
        }
        let result = await checker.check()
        guard case .available(let release) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(release.version.description, "1.2.0")
        let offline = UpdateChecker(current: "1.0.0") { _ in throw URLError(.notConnectedToInternet) }
        guard case .failed = await offline.check() else { return XCTFail() }
    }

    func testOncePerDay() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-90_000), now: now))
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(3_600), now: now), "horloge reculée : on vérifie")
    }

    func testInstallLocation() {
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Applications/SyncMacPro.app"))
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Users/moi/Applications/SyncMacPro.app"))
        XCTAssertEqual(InstallLocation.problem(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/SyncMacPro.app"), .translocated)
        XCTAssertEqual(InstallLocation.problem(bundlePath: "/Volumes/SyncMacPro 1.0.0/SyncMacPro.app"), .diskImage)
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Users/moi/Desktop/PROJET/.build/debug/SyncMacPro"), "développement : pas un bundle")
    }
}
