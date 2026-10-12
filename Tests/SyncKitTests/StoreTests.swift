import XCTest
@testable import SyncKit

final class StoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(task: UUID = UUID(), name: String = "t", at seconds: TimeInterval, status: RunStatus = .succeeded) -> RunRecord {
        RunRecord(
            taskID: task, taskName: name, engine: .rsync, mode: .mirror,
            startedAt: Date(timeIntervalSince1970: seconds),
            finishedAt: status == .running ? nil : Date(timeIntervalSince1970: seconds + 60),
            status: status,
            summary: RunSummary(filesTransferred: 3, bytesTransferred: 1234, deletions: 1, errors: 0, durationSeconds: 60, message: "ok")
        )
    }

    func testHistoryRoundTripKeepsEveryField() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        var original = record(at: 1_000)
        original.logPath = "/tmp/run.log"
        original.dryRun = true
        try store.save(original)
        XCTAssertEqual(try store.record(id: original.id), original)
    }

    func testListIsNewestFirstAndFilteredByTask() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        let taskA = UUID(), taskB = UUID()
        let old = record(task: taskA, at: 100), recent = record(task: taskA, at: 300), other = record(task: taskB, at: 200)
        for item in [old, recent, other] { try store.save(item) }

        XCTAssertEqual(try store.list().map(\.id), [recent.id, other.id, old.id])
        XCTAssertEqual(try store.list(taskID: taskA).map(\.id), [recent.id, old.id])
        XCTAssertEqual(try store.list(limit: 1).count, 1)
    }

    func testSavingTheSameIDUpdatesTheRecord() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        var run = record(at: 100, status: .running)
        try store.save(run)
        run.status = .failed
        run.finishedAt = Date(timeIntervalSince1970: 160)
        try store.save(run)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.record(id: run.id)?.status, .failed)
    }

    func testRunningRecordsBecomeInterruptedAtStartup() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        let running = record(at: 100, status: .running), done = record(at: 200)
        try store.save(running)
        try store.save(done)

        XCTAssertEqual(try store.markRunningAsInterrupted(at: Date(timeIntervalSince1970: 500)), 1)
        let reloaded = try XCTUnwrap(try store.record(id: running.id))
        XCTAssertEqual(reloaded.status, .interrupted)
        XCTAssertEqual(reloaded.finishedAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(try store.record(id: done.id)?.status, .succeeded)
    }

    func testPurgeRemovesOnlyOldFinishedRuns() throws {
        let store = try HistoryStore(path: directory.appendingPathComponent("h.sqlite").path)
        let old = record(at: 100), recent = record(at: 10_000), running = record(at: 50, status: .running)
        for item in [old, recent, running] { try store.save(item) }

        XCTAssertEqual(try store.purge(finishedBefore: Date(timeIntervalSince1970: 5_000)), 1)
        XCTAssertEqual(Set(try store.list().map(\.id)), [recent.id, running.id])
    }

    func testHistorySurvivesReopening() throws {
        let path = directory.appendingPathComponent("h.sqlite").path
        let run = record(at: 100)
        try HistoryStore(path: path).save(run)
        XCTAssertEqual(try HistoryStore(path: path).list(), [run])
    }

    func testHistoryRejectsAnUnwritablePath() {
        XCTAssertThrowsError(try HistoryStore(path: "/nonexistent-dir/h.sqlite")) {
            guard case HistoryError.openFailed = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: tâches

    func testTaskStoreRoundTripAndUpsert() throws {
        let store = TaskStore(url: directory.appendingPathComponent("sub/tasks.json"))
        XCTAssertEqual(try store.load(), [])                    // fichier absent

        var task = SyncTask(name: "A", source: .local(path: "/a"), destination: .local(path: "/b"))
        try store.upsert(task)
        task.name = "A renommée"
        try store.upsert(task)
        let other = SyncTask(name: "B", source: .local(path: "/c"), destination: .local(path: "/d"))
        try store.upsert(other)

        XCTAssertEqual(try store.load(), [task, other])
        try store.remove(id: task.id)
        XCTAssertEqual(try store.load(), [other])
    }

    func testCorruptTaskFileIsReportedNotOverwritten() throws {
        let url = directory.appendingPathComponent("tasks.json")
        try "{ pas du json".write(to: url, atomically: true, encoding: .utf8)
        let store = TaskStore(url: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.upsert(SyncTask(name: "x", source: .local(path: "/a"), destination: .local(path: "/b"))))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ pas du json")
    }
}
