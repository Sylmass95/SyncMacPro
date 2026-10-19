import XCTest
@testable import SyncKit

/// 1.6.8 : dans un dossier synchronisé par Google Drive pour ordinateur, Drive range les fichiers en cours d'envoi dans
/// `.tmp.driveupload` (1 Go, 5 322 fichiers dans PERSO-PROJECT le 19/10) : la copie vers le QNAP y passait des heures.
final class DriveTempExcludeTests: IntegrationTestCase {
    func testGoogleDriveTemporaryFoldersAreExcludedByDefault() {
        XCTAssertTrue(TaskOptions().excludes.contains(".tmp.driveupload/"))
        XCTAssertTrue(TaskOptions().excludes.contains(".tmp.drivedownload/"))
    }

    func testACopyWithTheDefaultExclusionsSkipsThem() async throws {
        let source = try folder("PERSO")
        _ = try write(source + "/a.txt", "a")
        _ = try write(source + "/.tmp.driveupload/4028731", "morceau")
        _ = try write(source + "/.tmp.drivedownload/12", "morceau")
        let destination = sandbox.appendingPathComponent("QNAP").path
        let result = try await makeRunner(rsync: true).run(SyncTask(name: "t", source: .local(path: source), destination: .local(path: destination)))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertTrue(exists(destination + "/a.txt"))
        XCTAssertFalse(exists(destination + "/.tmp.driveupload"))
        XCTAssertFalse(exists(destination + "/.tmp.drivedownload"))
    }
}
