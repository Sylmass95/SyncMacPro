import XCTest
@testable import SyncKit

final class AgentDetails182Tests: XCTestCase {
    func testARunKeepsItsDetailsAndTheAgentReturnsThem() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.lines.set(["sending incremental file list", ">f+++++++++|5|photo.jpg", "*deleting  |0|vieux.txt"])
        let task = makeTask("Photos", schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        let record = try XCTUnwrap(try h.history.list(taskID: task.id).first)
        let details = try await core.runDetails(runID: record.id, maxRows: 100)
        XCTAssertEqual(details.rows, [RunDetailRow(action: .added, size: 5, path: "photo.jpg"), RunDetailRow(action: .deleted, size: nil, path: "vieux.txt")])
        _ = try await core.clearHistory(taskID: task.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RunLogWriter.detailsURL(for: URL(fileURLWithPath: try XCTUnwrap(record.logPath))).path),
                       "vider l'historique efface aussi les détails")
    }
}
