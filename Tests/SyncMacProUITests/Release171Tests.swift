import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class Release171Tests: XCTestCase {
    /// La ligne dit ce que fait une copie qui n'a pas encore de progression.
    func testThePreparationStepIsShown() {
        let row = RowText(localizer: Localizer(language: "fr"))
        var info = AgentTaskInfo(id: UUID(), name: "A", state: .running)
        info.phase = "planning"
        XCTAssertEqual(row.state(info, text: UIFixtures.french), "Préparation : comparaison avec la destination…")
        info.phase = "verifying"
        XCTAssertEqual(row.state(info, text: UIFixtures.french), "Vérification après la copie…")
        info.phase = "running"
        XCTAssertEqual(row.state(info, text: UIFixtures.french), UIFixtures.french.state(.running))
    }

    /// Pendant une mise à jour, l'ancien agent ne comprend pas « réordonner » : message clair, et la liste reprend
    /// l'ordre réel.
    func testARefusedMoveDuringAnUpdateIsExplainedAndUndone() async {
        let a = UUID(), b = UUID()
        var first = AgentTaskInfo(id: a, name: "A", state: .idle); first.rank = 1
        var second = AgentTaskInfo(id: b, name: "B", state: .idle); second.rank = 2
        let agent = FakeAgent()
        agent.setStatus(.success(AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [first, second])))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.refreshNow()
        agent.setPerformError(AgentClientError.agent(.internalFailure("requête illisible")))
        await model.move([b], toOffset: 0)
        XCTAssertEqual(model.orderedTasks.map(\.name), ["A", "B"], "l'ordre réel revient")
        XCTAssertEqual(model.alertMessage, "SyncMacPro termine sa mise à jour : réessayez dans un instant.")
        model.shutdown()
    }
}
