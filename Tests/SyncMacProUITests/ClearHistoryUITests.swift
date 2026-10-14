import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class ClearHistoryUITests: XCTestCase {
    func testClearingAsksTheAgentThenReloadsTheHistory() async {
        let agent = FakeAgent()
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let task = UUID()
        let before = agent.historyCalls
        await model.clearHistory(taskID: task)
        XCTAssertEqual(agent.performed, [.clearHistory(taskID: task)])
        XCTAssertEqual(agent.historyCalls, before + 1, "l'historique affiché est relu")
        XCTAssertNil(model.alertMessage)
        model.shutdown()
    }

    func testARefusalIsShown() async {
        let agent = FakeAgent()
        agent.setPerformError(AgentError.internalFailure("disque"))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.clearHistory(taskID: nil)
        XCTAssertNotNil(model.alertMessage)
        model.shutdown()
    }

    func testConfirmationTextsExistInBothLanguages() {
        for localizer in [Localizer(language: "fr"), Localizer(language: "en")] {
            for key in ["history.clear", "history.clear.all", "history.clear.task", "history.clear.confirm.all",
                        "history.clear.confirm.task", "history.clear.message"] {
                XCTAssertNotEqual(localizer.text(key), key, "\(key) manque")
            }
        }
    }
}
