import XCTest
@testable import SyncKit

final class AgentSimulationTests: XCTestCase {
    func testSimulationRunsADryRunAndLeavesNoTrace() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let draft = makeTask("", schedule: .manual)   // un brouillon sans nom peut être simulé
        let result = try await core.simulate(draft)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.filesToTransfer, 1)
        XCTAssertEqual(h.factory.runners.get().first?.dryRuns.get(), [true])
        XCTAssertTrue(try h.history.list().isEmpty, "une simulation n'entre pas dans l'historique")
        XCTAssertTrue(try h.taskStore.load().isEmpty, "ni dans tasks.json")
    }

    func testInvalidDraftIsRefused() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let nested = SyncTask(name: "", source: .local(path: "/a"), destination: .local(path: "/a/b"))
        do { _ = try await core.simulate(nested); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .invalidTask(TaskProblem.nestedFolders.message))
        }
    }

    func testSimulationCanBeCancelled() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let draft = makeTask(schedule: .manual)
        let pending = Task { try await core.simulate(draft) }
        _ = await eventually { h.factory.runners.get().count == 1 }
        await core.cancelSimulation(draft.id)
        let result = try await pending.value
        XCTAssertEqual(result.status, .stopped)
    }

    func testSimulationGoesThroughXPC() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let delegate = AgentListenerDelegate(core: core)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        let client = AgentClient(timeout: 5) { NSXPCConnection(listenerEndpoint: endpoint) }
        let result = try await client.simulate(makeTask(schedule: .manual))
        XCTAssertEqual(result.status, .succeeded)
        withExtendedLifetime((listener, delegate)) {}
    }
}
