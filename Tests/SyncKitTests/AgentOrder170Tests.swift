import XCTest
@testable import SyncKit

/// 1.7.0 : une seule liste ; l'ordre des tâches, enregistré par l'agent, est l'ordre de départ.
final class AgentOrder170Tests: XCTestCase {
    func task(_ name: String, schedule: Schedule = .manual) -> SyncTask {
        SyncTask(name: name, source: .local(path: "/s/\(name)"), destination: .local(path: "/d/\(name)"), schedule: schedule)
    }

    func names(_ core: AgentCore) async -> [String] { await core.status().tasks.map(\.name) }

    func testNewTasksGoToTheEndAndDeletedOnesLeave() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = task("A"), b = task("B"), c = task("C")
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        let ranks = await core.status().tasks.map(\.rank)
        XCTAssertEqual(ranks, [1, 2, 3])
        try await core.saveTask(task("D"))
        let afterAdd = await names(core)
        XCTAssertEqual(afterAdd, ["A", "B", "C", "D"])
        try await core.removeTask(b.id)
        let afterRemove = await core.status().tasks.map { "\($0.name)\($0.rank ?? 0)" }
        XCTAssertEqual(afterRemove, ["A1", "C2", "D3"])
    }

    func testReorderIsPersistedAndSurvivesARestart() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = task("A"), b = task("B"), c = task("C")
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        await core.reorder([c.id, a.id, b.id])
        let restarted = h.makeCore()
        await restarted.start()
        let order = await names(restarted)
        XCTAssertEqual(order, ["C", "A", "B"])
        let ranks = await restarted.status().tasks.map(\.rank)
        XCTAssertEqual(ranks, [1, 2, 3])
    }

    func testAStaleOrderKeepsUnknownTasksAtTheEnd() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = task("A"), b = task("B"), c = task("C")
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        await core.reorder([b.id, UUID()])
        let order = await names(core)
        XCTAssertEqual(order, ["B", "A", "C"])
    }

    func testReorderingARunningTaskDoesNotTouchIt() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let a = task("A"), b = task("B")
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        await core.reorder([b.id, a.id])
        let runner = h.factory.runners.get()[0]
        XCTAssertFalse(runner.calls.get().contains("pause"))
        XCTAssertFalse(runner.calls.get().contains("stop"))
        let state = await core.status().tasks.first { $0.id == a.id }?.state
        XCTAssertEqual(state, .running)
        runner.release()
        await core.waitForIdle()
    }

    func testARunningOldQueueBecomesRunRequestsOnTop() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = task("A"), b = task("B"), c = task("C"), d = task("D")
        try h.save([d, a, b, c])
        var old = SchedulerState()
        old.userQueue = [b.id, c.id]
        old.userQueueRunning = true
        old.userQueueCurrent = a.id
        var entry = TaskScheduleState(firstSeen: Date(timeIntervalSince1970: 0))
        entry.runningSince = Date(timeIntervalSince1970: 0)   // A tournait quand l'agent s'est arrêté
        old.tasks[a.id.uuidString] = entry
        try h.stateStore.save(old)
        let core = h.makeCore()
        await core.start()
        let order = await names(core)
        XCTAssertEqual(order, ["A", "B", "C", "D"])
        await core.tick()
        await core.waitForIdle()
        await core.tick()
        await core.waitForIdle()
        let ran = h.factory.runners.get().compactMap { $0.ranTasks.get().first?.name }.sorted()
        XCTAssertEqual(ran, ["A", "B", "C"], "chacune une fois, D n'était pas dans la file")
        let saved = h.stateStore.load().state
        XCTAssertEqual(saved.userQueue, [])
        XCTAssertFalse(saved.userQueueRunning)
        XCTAssertNil(saved.userQueueCurrent)
    }

    func testAStoppedOldQueueIsForgotten() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = task("A"), b = task("B")
        try h.save([a, b])
        var old = SchedulerState()
        old.userQueue = [b.id]
        old.userQueueRunning = false
        try h.stateStore.save(old)
        let core = h.makeCore()
        await core.start()
        await core.tick()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.created, 0)
        XCTAssertEqual(h.stateStore.load().state.userQueue, [])
    }
}
