import XCTest
@testable import SyncKit

/// 1.8.2 : la synchronisation bidirectionnelle liste ses fichiers dans le journal, et un fichier vide n'y écrase jamais
/// une version non vide de l'autre côté ; 1.8.3 : la copie vide est réparée (essai réel BTS du 23/10 : un .MP4 de 700 Mo remplacé par sa copie vide du Drive).
final class Bisync182Tests: IntegrationTestCase {
    func testBisyncListsItsFiles() throws {
        let sync = SyncTask(name: "b", source: .local(path: "/a"), destination: .cloud(remote: "drive", path: "x"), mode: .bidirectional)
        XCTAssertTrue(try RcloneCommandBuilder.command(for: sync, run: RunOptions(archiveStamp: "s")).arguments.contains("-v"))
    }

    func testAnEmptyFileNeverReplacesAFullOneInEitherDirection() async throws {
        let one = try folder("one"), two = try folder("two")
        for index in 1...8 { try write("\(one)/common\(index).txt", "x") }
        try write("\(two)/gros.mp4", "contenu précieux")
        try write("\(one)/gros.mp4", "")                       // vide et plus récent : « newer » le choisirait
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: "\(two)/gros.mp4")
        try write("\(one)/autre.mov", "plein aussi")
        try write("\(two)/autre.mov", "")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: "\(one)/autre.mov")
        let runner = try makeRunner(rclone: true)
        var sync = SyncTask(name: "b", source: .local(path: one), destination: .cloud(remote: ":local", path: two), mode: .bidirectional)
        sync.options.excludes = []
        let result = try await runner.run(sync)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        // 1.8.3 : la copie vide est réparée avec la version pleine de l'autre côté (essai réel : MAXIME NONY.MP4).
        for side in [one, two] {
            XCTAssertEqual(read("\(side)/gros.mp4"), "contenu précieux", side)
            XCTAssertEqual(read("\(side)/autre.mov"), "plein aussi", side)
        }
        XCTAssertEqual(result.summary.message, EmptySourceGuard.repairedMessage(count: 2))
        // Passage suivant : les deux côtés sont identiques, rien ne bouge.
        let again = try await runner.run(sync)
        XCTAssertEqual(again.status, .succeeded, again.summary.message ?? "")
        for side in [one, two] {
            XCTAssertEqual(read("\(side)/gros.mp4"), "contenu précieux", side)
            XCTAssertEqual(read("\(side)/autre.mov"), "plein aussi", side)
        }
        XCTAssertEqual(again.summary.deletions, 0)
    }
}
