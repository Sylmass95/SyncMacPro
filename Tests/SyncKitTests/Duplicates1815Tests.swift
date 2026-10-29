import XCTest
@testable import SyncKit

/// 1.8.15 : Google Drive accepte deux fichiers du même nom dans un dossier (import refait : essai réel, 102 photos de
/// « Back 2 Work - Cologne » importées deux fois le 13/10). rclone n'en copie qu'un ; c'est maintenant signalé, comme
/// les doublons d'un NAS.
final class Duplicates1815Tests: IntegrationTestCase {
    private func fakeRclone() throws -> String {
        let fake = sandbox.appendingPathComponent("fake-rclone").path
        let line = #"{"level":"notice","msg":"Duplicate object found in source - ignoring","object":"EVENTS/Cologne/00261.jpg","objectType":"*drive.Object"}"#
        try """
        #!/bin/sh
        for a in "$@"; do [ "$a" = "--dry-run" ] && exit 0; done
        [ "$1" = "copy" ] || exit 0
        echo '\(line)' >&2
        exit 0
        """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        return fake
    }

    func testDuplicatesOnTheOnlineServiceAreReported() async throws {
        let config = sandbox.appendingPathComponent("rclone.conf")
        try "[Drive]\ntype = drive\n".write(to: config, atomically: true, encoding: .utf8)
        let runner = TaskRunner(configuration: RunnerConfiguration(rclonePath: try fakeRclone(), rcloneConfigPath: config.path,
                                                                   workDirectory: sandbox.appendingPathComponent("w")))
        let task = SyncTask(name: "Drive → NAS", source: .cloud(remote: "Drive", path: ""), destination: .local(path: try folder("d")),
                            options: TaskOptions(excludes: [], forcedEngine: .rclone))
        let rows = Locked<[RunDetailRow]>([]), lines = Locked<[String]>([])
        let result = try await runner.run(task) { update in
            if case .detail(let row) = update { rows.update { $0.append(row) } }
            if case .line(let text) = update { lines.update { $0.append(text) } }
        }
        XCTAssertEqual(result.status, .succeeded)
        let message = result.summary.message ?? ""
        XCTAssertTrue(message.contains("1 nom en double sur le service en ligne"), message)
        XCTAssertFalse(message.contains("accents"), message)
        XCTAssertEqual(rows.get().filter { $0.action == .duplicate }.map(\.path), ["EVENTS/Cologne/00261.jpg"])
        XCTAssertTrue(lines.get().contains { $0.hasPrefix("Doublon sur le service en ligne") })
    }

    func testAMissingLocalFileIsNotTakenForABadlyStoredName() {
        // Hors NAS, « introuvable » est un vrai fichier disparu pendant la copie : pas de rattrapage.
        let names = SourceNameLog()
        let line = #"{"level":"error","msg":"Failed to copy: failed to open source object: open /Users/x/a.txt: no such file or directory","object":"a.txt"}"#
        names.note(SourceNameIssue.parse(rcloneLine: line), onlyDuplicates: true)
        XCTAssertEqual(names.unreadable, [])
    }
}
