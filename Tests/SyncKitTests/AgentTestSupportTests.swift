import XCTest
@testable import SyncKit

final class AgentTestSupportTests: XCTestCase {
    func testGatedRunnerWaitsForReleaseThenReportsItsStatus() async throws {
        let runner = FakeRunner(status: .succeeded, gated: true)
        let task = SyncTask(name: "t", source: .local(path: "/s"), destination: .local(path: "/d"))
        let job = Task { try await runner.run(task, dryRun: false, onUpdate: { _ in }) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(runner.calls.get(), ["run"])
        runner.release()
        let result = try await job.value
        XCTAssertEqual(result.status, .succeeded)
    }

    func testStopReleasesTheGateAndReportsStopped() async throws {
        let runner = FakeRunner(gated: true)
        let task = SyncTask(name: "t", source: .local(path: "/s"), destination: .local(path: "/d"))
        let job = Task { try await runner.run(task, dryRun: false, onUpdate: { _ in }) }
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.stop()
        let result = try await job.value
        XCTAssertEqual(result.status, .stopped)
    }

    func testFakeClockMoves() {
        let clock = FakeClock(Date(timeIntervalSince1970: 1000))
        clock.advance(60)
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 1060))
    }
}
