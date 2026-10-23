import XCTest
@testable import SyncKit

/// 1.8.2 : détails de chaque exécution (fichier par fichier : action, taille, chemin), lus depuis l'historique.
final class Details182Tests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("details-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testRsyncLinesWithTheirSize() {
        XCTAssertEqual(RunDetailParser.parse(">f+++++++++|1234|dossier/photo.jpg"), RunDetailRow(action: .added, size: 1234, path: "dossier/photo.jpg"))
        XCTAssertEqual(RunDetailParser.parse("<f.st......|99|a|b.txt"), RunDetailRow(action: .updated, size: 99, path: "a|b.txt"))
        XCTAssertEqual(RunDetailParser.parse(".f..t......|5|seule-la-date.txt"), RunDetailRow(action: .touched, size: 5, path: "seule-la-date.txt"))
        XCTAssertEqual(RunDetailParser.parse("*deleting  |0|vieux.txt"), RunDetailRow(action: .deleted, size: nil, path: "vieux.txt"))
        XCTAssertEqual(RunDetailParser.parse("deleting vieux.txt"), RunDetailRow(action: .deleted, size: nil, path: "vieux.txt"))
        XCTAssertNil(RunDetailParser.parse("cd+++++++++|4096|nouveau-dossier/"), "les dossiers ne comptent pas")
        XCTAssertNil(RunDetailParser.parse("sending incremental file list"))
    }

    func testRcloneJSONLines() {
        func json(_ msg: String, _ object: String, size: Int? = 42) -> String {
            #"{"time":"t","level":"info","msg":"\#(msg)",\#(size.map { "\"size\":\($0)," } ?? "")"object":"\#(object)","objectType":"*local.Object"}"#
        }
        XCTAssertEqual(RunDetailParser.parse(json("Copied (new)", "a/b.mov")), RunDetailRow(action: .added, size: 42, path: "a/b.mov"))
        XCTAssertEqual(RunDetailParser.parse(json("Copied (replaced existing)", "c.docx")), RunDetailRow(action: .updated, size: 42, path: "c.docx"))
        XCTAssertEqual(RunDetailParser.parse(json("Deleted", "d.txt", size: nil)), RunDetailRow(action: .deleted, size: nil, path: "d.txt"))
        XCTAssertEqual(RunDetailParser.parse(json("Moved (server-side) to: _ARCHIVE/2026/e.txt", "e.txt")), RunDetailRow(action: .archived, size: 42, path: "e.txt"))
        XCTAssertEqual(RunDetailParser.parse(json("Updated modification time in destination", "f.txt")), RunDetailRow(action: .touched, size: 42, path: "f.txt"))
        XCTAssertNil(RunDetailParser.parse(#"{"level":"notice","msg":"Transferred: 1 / 1"}"#))
    }

    func testTheRsyncOutputParserStillFollowsFilesWithTheSize() {
        XCTAssertEqual(RsyncOutputParser.parse(line: ">f+++++++++|1234|dossier/photo.jpg"), .fileStarted(name: "dossier/photo.jpg", isNew: true))
        XCTAssertEqual(RsyncOutputParser.parse(line: "*deleting  |0|vieux.txt"), .deleting(name: "vieux.txt"))
        XCTAssertEqual(RsyncOutputParser.parse(line: ">f+++++++++|dossier/photo.jpg"), .fileStarted(name: "dossier/photo.jpg", isNew: true), "ancien format")
    }

    func testTheCopyPrintsSizes() throws {
        let task = SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))
        XCTAssertTrue(try RsyncCommandBuilder.command(for: task, run: RunOptions(archiveStamp: "x")).arguments.contains("--out-format=%i|%l|%n"))
    }

    func testTheLogWriterKeepsDetailsEvenPastTheLogLimit() throws {
        let url = folder.appendingPathComponent("run.log")
        let writer = RunLogWriter(url: url, limit: 80)
        for i in 1...50 { writer.append(">f+++++++++|\(i)|fichier-\(i).txt") }
        writer.append("*deleting  |0|vieux.txt")
        writer.close()
        let details = try RunDetails.read(url: RunLogWriter.detailsURL(for: url), maxRows: 10)
        XCTAssertEqual(details.rows.count, 10)
        XCTAssertTrue(details.truncated)
        XCTAssertEqual(details.totals[.added]?.count, 50)
        XCTAssertEqual(details.totals[.added]?.bytes, Int64((1...50).reduce(0, +)))
        XCTAssertEqual(details.totals[.deleted]?.count, 1)
    }

    func testDetailsSurviveAResumedRun() throws {
        let url = folder.appendingPathComponent("run.log")
        let first = RunLogWriter(url: url); first.append(">f+++++++++|1|a.txt"); first.close()
        let again = RunLogWriter(url: url, append: true); again.append(">f+++++++++|2|b.txt"); again.close()
        XCTAssertEqual(try RunDetails.read(url: RunLogWriter.detailsURL(for: url), maxRows: 100).rows.map(\.path), ["a.txt", "b.txt"])
    }

    func testRunDetailsTravelBetweenAgentAndApp() throws {
        let details = RunDetails(rows: [RunDetailRow(action: .added, size: 3, path: "é.txt")], totals: [.added: .init(count: 1, bytes: 3)], truncated: false)
        let reply = AgentResponse.details(details)
        XCTAssertEqual(try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(reply)), reply)
        let request = AgentRequest.runDetails(runID: UUID(), maxRows: 100)
        XCTAssertEqual(try JSONDecoder().decode(AgentRequest.self, from: JSONEncoder().encode(request)), request)
    }
}
