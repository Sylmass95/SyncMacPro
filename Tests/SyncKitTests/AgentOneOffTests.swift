import XCTest
@testable import SyncKit

final class AgentOneOffTests: XCTestCase {
    func testOneOffRunsShowsInTheStatusThenLeaves() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let copy = makeTask("Copie de 3 éléments", schedule: .manual)
        try await core.runOnce(copy)
        let running = await core.status().tasks
        XCTAssertEqual(running.map(\.name), ["Copie de 3 éléments"])
        XCTAssertEqual(running.first?.isOneOff, true)
        XCTAssertEqual(running.first?.state, .running)
        XCTAssertTrue(try h.taskStore.load().isEmpty, "une copie ponctuelle n'est pas enregistrée")
        let listed = await core.listTasks()
        XCTAssertTrue(listed.isEmpty)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        let after = await core.status().tasks
        XCTAssertTrue(after.isEmpty, "elle disparaît de l'état une fois terminée")
        XCTAssertEqual(try h.history.list(taskID: copy.id).first?.status, .succeeded)
    }

    func testOneOffCanBeStopped() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let copy = makeTask(schedule: .manual)
        try await core.runOnce(copy)
        try await core.stop(copy.id)
        await core.waitForIdle()
        XCTAssertEqual(try h.history.list(taskID: copy.id).first?.status, .stopped)
    }

    func testQueuedOneOffStoppedLeavesTheState() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let copies = (0..<3).map { makeTask("c\($0)", schedule: .manual) }
        for copy in copies { try await core.runOnce(copy) }
        let queued = await core.status().tasks.first { $0.id == copies[2].id }?.state
        XCTAssertEqual(queued, .queued)
        try await core.stop(copies[2].id)
        let names = await core.status().tasks.map(\.name)
        XCTAssertEqual(names, ["c0", "c1"], "retirée de la file, elle n'existe plus")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testRefusals() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let saved = makeTask("Enregistrée", schedule: .manual)
        try h.save([saved])
        let core = h.makeCore()
        await core.start()
        do { try await core.runOnce(saved); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .alreadyRunning) }
        let copy = makeTask(schedule: .manual)
        try await core.runOnce(copy)
        do { try await core.runOnce(copy); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .alreadyRunning) }
        let nested = SyncTask(name: "n", source: .local(path: "/a"), destination: .local(path: "/a/b"))
        do { try await core.runOnce(nested); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .invalidTask(TaskProblem.nestedFolders.message))
        }
        await core.setGlobalPause(true)
        do { try await core.runOnce(makeTask(schedule: .manual)); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .globallyPaused)
        }
        await core.setGlobalPause(false)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testInterruptedOneOffIsNeverCaughtUp() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let copy = makeTask(schedule: .manual)
        try await core.runOnce(copy)
        await core.shutdown()
        XCTAssertEqual(try h.history.list(taskID: copy.id).first?.status, .interrupted)
        let next = h.makeCore()
        await next.start()
        await next.tick()
        XCTAssertEqual(h.factory.created, 1, "une copie ponctuelle n'est pas rattrapée")
        let status = await next.status().tasks
        XCTAssertTrue(status.isEmpty)
    }

    func testRunOnceThroughTheRouter() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let request = try JSONEncoder().encode(AgentRequestEnvelope(request: .runOnce(makeTask(schedule: .manual))))
        let data = await AgentRouter.handle(request, core: core)
        let reply = try JSONDecoder().decode(AgentResponseEnvelope.self, from: data)
        XCTAssertEqual(reply.response, .ok)
        XCTAssertEqual(reply.version, agentProtocolVersion)
        await core.waitForIdle()
    }
}
