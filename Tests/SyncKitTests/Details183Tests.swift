import XCTest
@testable import SyncKit

/// 1.8.3 : détails lisibles — un fichier par ligne, la taille des fichiers archivés, et d'où vient chaque fichier.
final class Details183Tests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("details183-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func json(_ msg: String, _ object: String, type: String, size: Int? = nil) -> String {
        #"{"level":"info","msg":"\#(msg)",\#(size.map { "\"size\":\($0)," } ?? "")"object":"\#(object)","objectType":"\#(type)"}"#
    }

    func testRcloneSaysOnWhichSideItHappened() {
        XCTAssertEqual(RunDetailParser.parse(json("Moved (server-side)", "a.mp4", type: "*drive.Object"))?.origin, .cloud)
        XCTAssertEqual(RunDetailParser.parse(json("Copied (new)", "b.docx", type: "*local.Object", size: 3))?.origin, .local)
        XCTAssertEqual(RunDetailParser.parse(">f+++++++++|5|c.txt")?.origin, .source)
        XCTAssertEqual(RunDetailParser.parse("*deleting  |0|d.txt")?.origin, .destination)
    }

    func details(_ lines: [String], extra: [RunDetailRow] = []) throws -> RunDetails {
        let url = folder.appendingPathComponent("r.log")
        let writer = RunLogWriter(url: url)
        lines.forEach { writer.append($0) }
        extra.forEach { writer.appendDetail($0) }
        writer.close()
        return try RunDetails.read(url: RunLogWriter.detailsURL(for: url), maxRows: 1_000)
    }

    /// Essai réel BTS du 23/10 : rclone écrit deux fois chaque déplacement vers _ARCHIVE (106 lignes pour 52 fichiers).
    func testAMoveWrittenTwiceCountsOnce() throws {
        let d = try details([json("Moved (server-side)", "a.mp4", type: "*drive.Object"), json("Moved (server-side)", "a.mp4", type: "*drive.Object")])
        XCTAssertEqual(d.rows.count, 1)
        XCTAssertEqual(d.totals[.archived]?.count, 1)
    }

    func testArchivedThenCopiedIsAnUpdate() throws {
        let d = try details([json("Moved (server-side)", "script.docx", type: "*drive.Object"),
                             json("Copied (new)", "script.docx", type: "*local.Object", size: 28_882)])
        XCTAssertEqual(d.rows.map(\.action), [.archived, .updated])
        XCTAssertEqual(d.totals[.added]?.count ?? 0, 0)
    }

    func testArchivedFilesGetTheirSizeFromTheArchive() throws {
        let d = try details([json("Moved (server-side)", "rush.mp4", type: "*drive.Object")],
                            extra: [RunDetailRow(action: .archived, size: 700_477_181, path: "rush.mp4", origin: .cloud)])
        XCTAssertEqual(d.rows, [RunDetailRow(action: .archived, size: 700_477_181, path: "rush.mp4", origin: .cloud)])
        XCTAssertEqual(d.totals[.archived]?.bytes, 700_477_181)
    }

    func testADeletedFileKeptInTheArchiveIsArchived() throws {
        let d = try details(["*deleting  |0|vieux.txt"], extra: [RunDetailRow(action: .archived, size: 12, path: "vieux.txt", origin: .destination)])
        XCTAssertEqual(d.rows, [RunDetailRow(action: .archived, size: 12, path: "vieux.txt", origin: .destination)])
    }

    func testDetailsFrom182StillRead() throws {
        let url = folder.appendingPathComponent("vieux.details.tsv")
        try "A\t5\tdossier/photo.jpg\nR\t\tarchive.txt\n".write(to: url, atomically: true, encoding: .utf8)
        let d = try RunDetails.read(url: url, maxRows: 10)
        XCTAssertEqual(d.rows, [RunDetailRow(action: .added, size: 5, path: "dossier/photo.jpg"), RunDetailRow(action: .archived, size: nil, path: "archive.txt")])
    }

    /// Les versions mises de côté par cette exécution (et ses relances « -r2 »…) donnent la taille des fichiers archivés.
    func testTheArchiveIsListedForSizes() throws {
        let root = folder.appendingPathComponent("dest/_ARCHIVE")
        let first = root.appendingPathComponent("2026-10-23_23-47-11"), retry = root.appendingPathComponent("2026-10-23_23-47-11-r2")
        let other = root.appendingPathComponent("2026-10-01_05-00-00")
        for dir in [first.appendingPathComponent("sous"), retry, other] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data(count: 7).write(to: first.appendingPathComponent("sous/a.mp4"))
        try Data(count: 3).write(to: retry.appendingPathComponent("b.txt"))
        try Data(count: 9).write(to: other.appendingPathComponent("ancien.txt"))
        let sizes = TaskRunner.localArchiveSizes(root: root.path, stamp: "2026-10-23_23-47-11")
        XCTAssertEqual(sizes, ["sous/a.mp4": 7, "b.txt": 3])
    }
}
