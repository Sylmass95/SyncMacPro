import XCTest
@testable import SyncMacProUI

/// Corrections issues de la relecture finale de la branche 5.
final class ReviewFix5Tests: XCTestCase {
    // I1 : une app sur un disque externe (lecture-écriture) n'est pas une image disque.
    func testExternalDriveIsNotADiskImage() {
        let external = "/Volumes/Externe/Applications/SyncMacPro.app"
        XCTAssertNil(InstallLocation.problem(bundlePath: external, isReadOnlyVolume: { _ in false }))
        XCTAssertEqual(InstallLocation.problem(bundlePath: "/Volumes/SyncMacPro 1.0.0/SyncMacPro.app", isReadOnlyVolume: { _ in true }),
                       .diskImage)
    }

    // I3 : la quarantaine posée par le téléchargement bloque les programmes embarqués ; l'app la retire de son bundle.
    func testQuarantineIsRemovedFromTheWholeBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString)/SyncMacPro.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let bin = root.appendingPathComponent("Contents/Resources/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("rsync")
        try Data("x".utf8).write(to: tool)
        let value = Array("0081;6ace439d;Safari;".utf8)
        for path in [root.path, tool.path] {
            XCTAssertEqual(setxattr(path, Quarantine.attribute, value, value.count, 0, 0), 0)
        }
        XCTAssertTrue(Quarantine.isQuarantined(tool))
        let cleared = Quarantine.clear(bundle: root)
        XCTAssertEqual(cleared, 2)
        XCTAssertFalse(Quarantine.isQuarantined(tool))
        XCTAssertFalse(Quarantine.isQuarantined(root))
        XCTAssertEqual(Quarantine.clear(bundle: root), 0, "rien à faire la seconde fois")
    }
}
