import XCTest
@testable import SyncKit

final class SchedulerStateTests: XCTestCase {
    var directory: URL!
    var url: URL { directory.appendingPathComponent("scheduler-state.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testMissingFileGivesAFreshStateThatIsNotPaused() {
        let loaded = SchedulerStateStore(url: url).load()
        XCTAssertFalse(loaded.state.paused)
        XCTAssertFalse(loaded.recovered)
        XCTAssertTrue(loaded.state.tasks.isEmpty)
    }

    func testStateRoundTrips() throws {
        var state = SchedulerState()
        state.paused = true
        var entry = TaskScheduleState(firstSeen: Date(timeIntervalSince1970: 1_000_000))
        entry.attempts = 2
        entry.retryAt = Date(timeIntervalSince1970: 2_000_000)
        entry.awaitingApproval = true
        state.tasks["A"] = entry
        let store = SchedulerStateStore(url: url)
        try store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded.state, state)
        XCTAssertFalse(loaded.recovered)
    }

    func testCorruptFileIsSetAsideAndTheAgentStartsPaused() throws {
        try "{ pas du json".write(to: url, atomically: true, encoding: .utf8)
        let store = SchedulerStateStore(url: url)
        let loaded = store.load()
        XCTAssertTrue(loaded.state.paused)
        XCTAssertTrue(loaded.recovered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
        // La pause est déjà enregistrée : un redémarrage ne relance rien.
        let again = store.load()
        XCTAssertTrue(again.state.paused)
        XCTAssertFalse(again.recovered)
    }

    func testSaveCreatesTheFolder() throws {
        let nested = directory.appendingPathComponent("a/b/state.json")
        try SchedulerStateStore(url: nested).save(SchedulerState())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}
