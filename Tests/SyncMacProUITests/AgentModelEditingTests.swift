import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class AgentModelEditingTests: XCTestCase {
    var agent: FakeAgent!
    var model: AgentModel!
    let task = SyncTask(name: "Photos", source: .local(path: "/a"), destination: .local(path: "/b"))

    override func setUp() async throws {
        agent = FakeAgent()
        agent.setTasks([task])
        agent.setStatus(.success(makeStatus([AgentTaskInfo(id: task.id, name: "Photos", state: .idle)])))
        model = AgentModel(agent: agent, sleeper: ManualSleeper())
        model.start()
        _ = await eventually { self.model.connection == .connected && self.model.tasks[self.task.id] != nil }
    }

    override func tearDown() async throws { model.shutdown() }

    func testSaveSendsTheTaskThenRefreshes() async {
        let before = agent.statusCalls
        let message = await model.saveTask(task)
        XCTAssertNil(message)
        XCTAssertEqual(agent.performed.last, .saveTask(task))
        XCTAssertEqual(agent.statusCalls, before + 1)
    }

    func testRefusalIsReturnedToTheEditorNotAlerted() async {
        agent.setPerformError(AgentClientError.agent(.invalidTask("Donnez un nom à la tâche.")))
        let message = await model.saveTask(task)
        XCTAssertEqual(message, "Donnez un nom à la tâche.")
        XCTAssertNil(model.alertMessage)
    }

    func testToggleSavesACopyWithTheNewFlag() async {
        await model.setEnabled(task.id, false)
        guard case .saveTask(let saved)? = agent.performed.last else { return XCTFail("saveTask attendu") }
        XCTAssertFalse(saved.isEnabled)
        XCTAssertEqual(saved.id, task.id)
    }

    func testRemoveFailureShowsAnAlert() async {
        agent.setPerformError(AgentClientError.agent(.alreadyRunning))
        await model.removeTask(task.id)
        XCTAssertEqual(agent.performed.last, .removeTask(task.id))
        XCTAssertEqual(model.alertMessage, AgentError.alreadyRunning.errorDescription)
    }

    func testSimulationOutcomes() async {
        let ok = await model.simulate(task)
        XCTAssertEqual(ok, .finished(SimulationResult(status: .succeeded, filesToTransfer: 3, bytesToTransfer: 1_000, deletions: 0, message: nil)))
        agent.setSimulation(.failure(AgentClientError.unreachable))
        let failed = await model.simulate(task)
        guard case .failed = failed else { return XCTFail("échec attendu") }
        await model.cancelSimulation(task.id)
        XCTAssertEqual(agent.performed.last, .cancelSimulation(task.id))
    }

    func testRunLogOutcomes() async {
        let id = UUID()
        let loaded = await model.runLog(id)
        XCTAssertEqual(loaded, .loaded(RunLogText(text: "ligne\n", truncated: false)))
        agent.setLog(.failure(AgentClientError.agent(.unknownRun)))
        let missing = await model.runLog(id)
        XCTAssertEqual(missing, .missing)
        agent.setLog(.failure(AgentClientError.badReply))
        let failed = await model.runLog(id)
        guard case .failed = failed else { return XCTFail("échec attendu") }
        XCTAssertEqual(agent.logRequests, [id, id, id])
    }
}
