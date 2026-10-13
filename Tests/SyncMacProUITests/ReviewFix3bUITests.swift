import XCTest
import SyncKit
@testable import SyncMacProUI

/// Corrections issues de la relecture finale de la branche 3b (côté app).
@MainActor
final class ReviewFix3bUITests: XCTestCase {
    // I3 : « ~ » saisi à la main devient le dossier personnel.
    func testTildeIsExpanded() {
        var draft = TaskDraft()
        draft.source.path = "~/Photos"
        draft.destination.path = "/Volumes/NAS"
        XCTAssertEqual(draft.task(resolver: .localOnly).source, .local(path: NSHomeDirectory() + "/Photos"))
    }

    // I7 : un résultat de simulation ne vaut que pour la version simulée (le nom ne compte pas).
    func testSimulationKeyIgnoresTheNameOnly() {
        var draft = TaskDraft()
        draft.source.path = "/a"
        draft.destination.path = "/b"
        let before = draft.simulationKey(resolver: .localOnly)
        draft.name = "Renommée"
        XCTAssertEqual(draft.simulationKey(resolver: .localOnly), before)
        draft.mode = .mirror
        XCTAssertNotEqual(draft.simulationKey(resolver: .localOnly), before)
    }

    // I8 : si l'agent ne répond plus pendant une simulation, on lui demande de l'arrêter.
    func testUnreachableSimulationIsCancelledOnTheAgent() async {
        let agent = FakeAgent()
        agent.setSimulation(.failure(AgentClientError.unreachable))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let task = SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))
        _ = await model.simulate(task)
        XCTAssertEqual(agent.performed.last, .cancelSimulation(task.id))
    }

    func testNewProblemsHaveTexts() {
        for language in ["fr", "en"] {
            let text = TaskSummaryText(localizer: Localizer(language: language))
            XCTAssertFalse(text.problem(.relativePath).hasPrefix("⚠︎"))
            XCTAssertFalse(text.problem(.invalidArchiveFolder).hasPrefix("⚠︎"))
        }
        XCTAssertEqual(TaskProblem.relativePath.step, .endpoints)
        XCTAssertEqual(TaskProblem.invalidArchiveFolder.step, .options)
    }
}
