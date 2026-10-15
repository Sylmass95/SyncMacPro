import XCTest
@testable import SyncKit

/// Corrections mineures de la 1.3.0, côté agent.
final class Fix140AgentTests: XCTestCase {
    func testDisablingATaskRemovesItFromTheQueue() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        var a = makeTask("A", schedule: .manual)
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        a.isEnabled = false
        try await core.saveTask(a)
        let items = await core.queueInfo.items
        XCTAssertEqual(items, [])
    }

    func testDisabledTaskCannotBeQueued() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        var a = makeTask("A", schedule: .manual)
        a.isEnabled = false
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        do { try await core.enqueue(a.id); XCTFail("désactivée") } catch {
            guard case .invalidTask? = error as? AgentError else { return XCTFail("\(error)") }
        }
    }

    func testQueuedTaskStartedOutsideTheQueueLeavesIt() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let a = makeTask("A", schedule: .manual)
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        try await core.runNow(a.id)
        let items = await core.queueInfo.items
        XCTAssertEqual(items, [], "lancée à la main : elle quitte la file")
        h.factory.runners.get()[0].release()
        await core.waitForIdle()
    }

    func testUnknownQueueItemHasItsOwnError() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        do { try await core.dequeue(UUID()); XCTFail("absent") } catch {
            XCTAssertEqual(error as? AgentError, .notInQueue)
            XCTAssertEqual((error as? AgentError)?.errorDescription, "Cette tâche n'est pas dans la file.")
        }
    }

    func testQueueWaitsForRemoteTypesBeforeStarting() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = makeTask("A", schedule: .manual)
        try h.save([a])
        var state = SchedulerState()
        state.userQueue = [a.id]
        state.userQueueRunning = true
        try h.stateStore.save(state)
        let core = h.makeCore(remotes: FakeRemotes())
        await core.start()
        XCTAssertEqual(h.factory.created, 0, "les plafonds dépendent des types de connexion")
        await core.refreshRemoteTypes()
        let started = await eventually { h.factory.created == 1 }
        XCTAssertTrue(started)
        await core.waitForIdle()
    }
}
