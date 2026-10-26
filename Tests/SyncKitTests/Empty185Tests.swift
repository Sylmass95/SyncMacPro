import XCTest
@testable import SyncKit

/// 1.8.5 : essai réel du 26/10 — 4 151 fichiers vides (presque tous des « Icon » de dossier du Mac) vérifiés un par un sur
/// le Drive : 25 min avant chaque reprise de la copie. Les icônes ne comptent plus, et au-delà de quelques centaines de
/// fichiers la destination est lue en une fois.
final class Empty185Tests: IntegrationTestCase {
    func testMacFolderIconsAreNotProtected() {
        XCTAssertTrue(EmptySourceGuard.isFolderIcon("COMMONS/04.FONTS/Icon\r"))
        XCTAssertTrue(EmptySourceGuard.isFolderIcon("COMMONS/04.FONTS/Icon\u{240D}"), "nom codé par rclone")
        XCTAssertTrue(EmptySourceGuard.isFolderIcon("Icon\u{240D}"))
        XCTAssertFalse(EmptySourceGuard.isFolderIcon("COMMONS/Icon.png"))
        XCTAssertFalse(EmptySourceGuard.isFolderIcon("COMMONS/Icon"))
    }

    func testManyEmptyFilesAreLookedUpInOnePass() {
        let task = SyncTask(name: "t", source: .local(path: "/Volumes/NAS"), destination: .cloud(remote: "drive", path: "x"))
        let few = RcloneCommandBuilder.destinationSizesCommand(for: task, file: "/tmp/l", run: RunOptions(archiveStamp: "s"), count: 10).arguments
        XCTAssertTrue(few.contains("--no-traverse"))
        let many = RcloneCommandBuilder.destinationSizesCommand(for: task, file: "/tmp/l", run: RunOptions(archiveStamp: "s"), count: 4_151).arguments
        XCTAssertFalse(many.contains("--no-traverse"))
        XCTAssertTrue(many.contains("--fast-list"))
    }

    func testTheProtectionStillHoldsWithManyEmptyFiles() async throws {
        let source = try folder("s"), destination = try folder("d")
        for index in 1...300 { try write("\(source)/vides/f\(index).txt", "") }
        try write("\(destination)/vides/f7.txt", "contenu précieux")
        try write("\(source)/dossier/Icon\r", "")
        let runner = try makeRunner(rclone: true)
        var copy = SyncTask(name: "t", source: .local(path: source), destination: .cloud(remote: ":local", path: destination))
        copy.options.excludes = []
        let result = try await runner.run(copy)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read("\(destination)/vides/f7.txt"), "contenu précieux")
        XCTAssertTrue(exists("\(destination)/vides/f8.txt"))
        XCTAssertEqual(result.summary.message, EmptySourceGuard.message(count: 1))
    }
}
