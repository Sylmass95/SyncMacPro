import XCTest
@testable import SyncKit

/// File d'attente explicite (1.3.0) : un élément à la fois, dans l'ordre choisi, après « Lancer la file ».
final class AgentQueueTests: XCTestCase {
    private func ran(_ h: AgentHarness) -> [String] {
        h.factory.runners.get().flatMap { $0.ranTasks.get().map(\.name) }
    }

    func testQueueRunsOneAtATimeInOrderAndSurvivesAFailure() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let a = makeTask("A", schedule: .manual), b = makeTask("B", schedule: .manual), c = makeTask("C", schedule: .manual)
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        for task in [a, b, c] { try await core.enqueue(task.id) }
        try await core.moveInQueue(c.id, to: 0)
        XCTAssertEqual(h.factory.created, 0, "la file ne part qu'avec « Lancer la file »")
        await core.setQueueRunning(true)
        XCTAssertEqual(h.factory.created, 1, "un seul élément à la fois")
        let first = h.factory.runners.get()[0]
        first.status.set(.failed)
        first.release()
        let second = await eventually { h.factory.created == 2 }
        XCTAssertTrue(second, "un échec n'arrête pas la file")
        h.factory.runners.get()[1].release()
        let third = await eventually { h.factory.created == 3 }
        XCTAssertTrue(third)
        h.factory.runners.get()[2].release()
        await core.waitForIdle()
        XCTAssertEqual(ran(h), ["C", "A", "B"])
        let info = await core.queueInfo
        XCTAssertEqual(info.items, [])
        XCTAssertNil(info.current)
        XCTAssertFalse(info.running, "vide, la file s'arrête")
    }

    func testSuspendLetsTheCurrentItemFinishAndStartsNothingElse() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let a = makeTask("A", schedule: .manual), b = makeTask("B", schedule: .manual)
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        try await core.enqueue(b.id)
        await core.setQueueRunning(true)
        await core.setQueueRunning(false)
        h.factory.runners.get()[0].release()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.created, 1)
        let items = await core.queueInfo.items
        XCTAssertEqual(items, [b.id])
    }

    func testQueueIsSavedAndRemovedTasksAreSkipped() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = makeTask("A", schedule: .manual), b = makeTask("B", schedule: .manual)
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        try await core.enqueue(b.id)
        try h.save([b])
        let again = h.makeCore()
        await again.start()
        let items = await again.queueInfo.items
        XCTAssertEqual(items, [b.id])
    }

    func testRunningOrQueuedTasksCannotBeAddedTwice() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = makeTask("A", schedule: .manual)
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        do { try await core.enqueue(a.id); XCTFail("déjà en file") } catch {
            XCTAssertEqual(error as? AgentError, .alreadyRunning)
        }
    }

    func testOneOffCopiesCanBeQueuedButAreNotSaved() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let copy = makeTask("Copie de 2 élément(s)", schedule: .manual)
        try await core.enqueueOnce(copy)
        let items = await core.queueInfo.items
        XCTAssertEqual(items, [copy.id])
        let again = h.makeCore()
        await again.start()
        let after = await again.queueInfo.items
        XCTAssertEqual(after, [])
    }

    func testStatusShowsQueuePositions() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = makeTask("A", schedule: .manual), b = makeTask("B", schedule: .manual)
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(b.id)
        try await core.enqueue(a.id)
        let status = await core.status()
        XCTAssertEqual(status.queue?.items, [b.id, a.id])
        XCTAssertEqual(status.tasks.first { $0.id == a.id }?.queuePosition, 2)
        XCTAssertEqual(status.tasks.first { $0.id == b.id }?.queuePosition, 1)
    }

    // Arrêter l'élément en cours : la file passe au suivant.
    func testStoppingTheCurrentItemMovesOn() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let a = makeTask("A", schedule: .manual), b = makeTask("B", schedule: .manual)
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        try await core.enqueue(b.id)
        await core.setQueueRunning(true)
        try await core.stop(a.id)
        let next = await eventually { h.factory.created == 2 }
        XCTAssertTrue(next)
        h.factory.runners.get()[1].release()
        await core.waitForIdle()
    }
}
