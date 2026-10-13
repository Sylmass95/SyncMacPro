import XCTest
@testable import SyncKit

final class AgentRunLogTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testWriterTimestampsLinesAndStopsAtTheLimit() throws {
        let url = folder.appendingPathComponent("a.log")
        let writer = RunLogWriter(url: url, limit: 60, now: { Date(timeIntervalSince1970: 0) })
        writer.append("première ligne")
        writer.append("deuxième ligne qui dépasse le plafond de soixante octets")
        writer.append("jamais écrite")
        writer.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("] première ligne"))
        XCTAssertTrue(text.contains("journal tronqué"))
        XCTAssertFalse(text.contains("jamais écrite"))
    }

    func testReadTailKeepsWholeLinesAndSaysItWasCut() throws {
        let url = folder.appendingPathComponent("b.log")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let body = (1...200).map { "ligne \($0)" }.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        let tail = try RunLogWriter.readTail(url: url, maxBytes: 100)
        XCTAssertTrue(tail.truncated)
        XCTAssertTrue(tail.text.hasPrefix("ligne "), "pas de ligne coupée au début")
        XCTAssertTrue(tail.text.hasSuffix("ligne 200\n"))
        let whole = try RunLogWriter.readTail(url: url, maxBytes: 1_000_000)
        XCTAssertFalse(whole.truncated)
        XCTAssertEqual(whole.text, body)
    }

    func testEachRunGetsItsOwnLog() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.lines.set(["sending incremental file list", "photo.jpg"])
        let task = makeTask("Photos", schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        let record = try XCTUnwrap(try h.history.list(taskID: task.id).first)
        let path = try XCTUnwrap(record.logPath)
        XCTAssertTrue(path.hasPrefix(h.logs.path))
        let log = try await core.runLog(runID: record.id, maxBytes: 262_144)
        XCTAssertTrue(log.text.contains("Photos"))
        XCTAssertTrue(log.text.contains("photo.jpg"))
        XCTAssertTrue(log.text.contains("succeeded"))
        XCTAssertFalse(log.truncated)
    }

    func testMissingLogIsReportedAsUnknownRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let old = RunRecord(taskID: UUID(), taskName: "avant 3b", engine: .rsync, mode: .copy,
                            startedAt: Date(timeIntervalSince1970: 0), status: .succeeded)
        try h.history.save(old)
        do { _ = try await core.runLog(runID: old.id, maxBytes: 1_000); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .unknownRun)
        }
        do { _ = try await core.runLog(runID: UUID(), maxBytes: 1_000); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .unknownRun)
        }
    }

    func testOldLogsArePurgedWithTheHistory() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(Date(timeIntervalSince1970: 2_000_000_000))
        try FileManager.default.createDirectory(at: h.logs, withIntermediateDirectories: true)
        let old = h.logs.appendingPathComponent("ancien.log"), fresh = h.logs.appendingPathComponent("recent.log")
        try "x".write(to: old, atomically: true, encoding: .utf8)
        try "y".write(to: fresh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: h.clock.now().addingTimeInterval(-100 * 86_400)], ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes([.modificationDate: h.clock.now()], ofItemAtPath: fresh.path)
        let core = h.makeCore()
        await core.start()
        await core.tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
