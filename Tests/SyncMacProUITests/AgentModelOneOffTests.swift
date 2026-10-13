import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class AgentModelOneOffTests: XCTestCase {
    func testEveryTaskIsSentThenStateIsRefreshed() async {
        let agent = FakeAgent()
        agent.setStatus(.success(makeStatus()))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let a = SyncTask(name: "a", source: .local(path: "/a"), destination: .local(path: "/c"))
        let b = SyncTask(name: "b", source: .local(path: "/b"), destination: .local(path: "/c"))
        let message = await model.runOnce([a, b])
        XCTAssertNil(message)
        XCTAssertEqual(agent.performed, [.runOnce(a), .runOnce(b)])
        XCTAssertEqual(agent.statusCalls, 1)
    }

    func testRefusalStopsAndIsReturned() async {
        let agent = FakeAgent()
        agent.setPerformError(AgentClientError.agent(.invalidTask("La destination ne peut pas être dans la source.")))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let a = SyncTask(name: "a", source: .local(path: "/a"), destination: .local(path: "/a/b"))
        let message = await model.runOnce([a, a])
        XCTAssertEqual(message, "La destination ne peut pas être dans la source.")
        XCTAssertEqual(agent.performed.count, 1, "on s'arrête au premier refus")
    }
}
