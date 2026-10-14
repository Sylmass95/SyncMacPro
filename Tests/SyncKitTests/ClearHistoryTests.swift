import XCTest
@testable import SyncKit

/// 1.2.4 : vider l'historique (tout, ou celui d'une tâche) ; les journaux partent avec, une exécution en cours reste.
final class ClearHistoryTests: XCTestCase {
    private func record(_ task: UUID, _ name: String, status: RunStatus, log: URL?) -> RunRecord {
        RunRecord(
            taskID: task, taskName: name, engine: .rsync, mode: .copy, startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: status == .running ? nil : Date(timeIntervalSince1970: 200), status: status, logPath: log?.path
        )
    }

    private func log(_ h: AgentHarness, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: h.logs, withIntermediateDirectories: true)
        let url = h.logs.appendingPathComponent("\(name).log")
        try "journal".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testClearingEverythingKeepsOnlyTheRunningExecution() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = UUID(), b = UUID()
        let logA = try log(h, "a"), logB = try log(h, "b"), logRunning = try log(h, "c")
        try h.history.save(record(a, "A", status: .succeeded, log: logA))
        try h.history.save(record(b, "B", status: .failed, log: logB))
        try h.history.save(record(b, "B", status: .running, log: logRunning))
        let core = h.makeCore()
        await core.start()   // marque « en cours » comme interrompu : on réenregistre une exécution vraiment en cours
        try h.history.save(record(b, "B", status: .running, log: logRunning))

        let removed = try await core.clearHistory(taskID: nil)
        XCTAssertEqual(removed, 3, "deux terminées + celle marquée interrompue au démarrage")
        let left = try h.history.list(limit: 10)
        XCTAssertEqual(left.map(\.status), [.running])
        XCTAssertFalse(FileManager.default.fileExists(atPath: logA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logRunning.path), "le journal d'une exécution en cours reste")
    }

    func testClearingOneTaskLeavesTheOthers() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = UUID(), b = UUID()
        let logA = try log(h, "a"), logB = try log(h, "b")
        try h.history.save(record(a, "A", status: .succeeded, log: logA))
        try h.history.save(record(b, "B", status: .succeeded, log: logB))
        let core = h.makeCore()
        await core.start()
        let removed = try await core.clearHistory(taskID: a)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try h.history.list(limit: 10).map(\.taskName), ["B"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: logA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logB.path))
    }

    // Un chemin de journal hors du dossier des journaux (base modifiée à la main) n'est jamais supprimé.
    func testOnlyFilesInsideTheLogFolderAreDeleted() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let outside = h.directory.appendingPathComponent("ailleurs.log")
        try "à garder".write(to: outside, atomically: true, encoding: .utf8)
        try h.history.save(record(UUID(), "A", status: .succeeded, log: outside))
        let core = h.makeCore()
        await core.start()
        _ = try await core.clearHistory(taskID: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(try h.history.list(limit: 10).isEmpty)
    }

    func testTheRouterAnswersWithTheCount() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        try h.history.save(record(UUID(), "A", status: .succeeded, log: nil))
        let core = h.makeCore()
        await core.start()
        let request = try JSONEncoder().encode(AgentRequestEnvelope(request: .clearHistory(taskID: nil)))
        let reply = try JSONDecoder().decode(AgentResponseEnvelope.self, from: await AgentRouter.handle(request, core: core))
        XCTAssertEqual(reply.response, .cleared(1))
    }

    func testCtlParsesClear() throws {
        XCTAssertEqual(try CtlParser.parse(["history", "--clear"]).command, .clearHistory(nil))
        XCTAssertEqual(try CtlParser.parse(["historique", "Photos", "--clear"]).command, .clearHistory("Photos"))
    }
}
