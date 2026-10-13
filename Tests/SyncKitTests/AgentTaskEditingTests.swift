import XCTest
@testable import SyncKit

final class AgentTaskEditingTests: XCTestCase {
    func testSaveCreatesTheTaskOnDiskAndTheAgentSeesIt() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let events = Locked<[AgentEvent]>([])
        _ = await core.addObserver { events.set(events.get() + [$0]) }
        let task = makeTask("Nouvelle", schedule: .manual)
        try await core.saveTask(task)
        let listed = await core.listTasks()
        XCTAssertEqual(listed.map(\.name), ["Nouvelle"])
        XCTAssertEqual(try h.taskStore.load().map(\.id), [task.id])
        XCTAssertTrue(events.get().contains(.stateChanged))
    }

    func testSaveReplacesAnExistingTask() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        var task = makeTask("Avant", schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        task.name = "Après"
        try await core.saveTask(task)
        XCTAssertEqual(try h.taskStore.load().map(\.name), ["Après"])
    }

    func testInvalidTaskIsRefusedWithTheReason() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let bad = SyncTask(name: "", source: .local(path: "/a"), destination: .local(path: "/a/b"))
        do {
            try await core.saveTask(bad)
            XCTFail("un refus était attendu")
        } catch {
            XCTAssertEqual(error as? AgentError, .invalidTask(TaskProblem.emptyName.message))
        }
        XCTAssertTrue(try h.taskStore.load().isEmpty, "rien n'est écrit")
    }

    func testEditingARunningTaskDoesNotDisturbTheRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        var task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        task.name = "Renommée"
        try await core.saveTask(task)
        let state = await core.status().tasks.first?.state
        XCTAssertEqual(state, .running)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .succeeded)
    }

    func testRemoveDeletesButRefusesARunningTask() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let busy = makeTask("Occupée", schedule: .manual), idle = makeTask("Libre", schedule: .manual)
        try h.save([busy, idle])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(busy.id)
        do { try await core.removeTask(busy.id); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .alreadyRunning) }
        do { try await core.removeTask(UUID()); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .unknownTask) }
        try await core.removeTask(idle.id)
        XCTAssertEqual(try h.taskStore.load().map(\.name), ["Occupée"])
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testRouterSavesAndRefusesOldProtocolVersions() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let task = makeTask("Par XPC", schedule: .manual)
        let saved = try JSONDecoder().decode(
            AgentResponseEnvelope.self,
            from: await AgentRouter.handle(JSONEncoder().encode(AgentRequestEnvelope(request: .saveTask(task))), core: core)
        )
        XCTAssertEqual(saved.response, .ok)
        XCTAssertEqual(saved.version, 2)
        let old = Data(#"{"version":1,"request":"status"}"#.utf8)
        let refused = try JSONDecoder().decode(AgentResponseEnvelope.self, from: await AgentRouter.handle(old, core: core))
        XCTAssertEqual(refused.response, .error(.versionMismatch(agent: 2, client: 1)))
    }
}
