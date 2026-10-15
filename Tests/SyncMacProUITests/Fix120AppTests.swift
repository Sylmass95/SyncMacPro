import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class Fix120AppTests: XCTestCase {
    // C2 : rouvrir l'app (Dock, Finder, `open`) sans fenêtre visible rouvre la fenêtre principale.
    func testReopenOpensTheMainWindowOnlyWhenNoneIsVisible() {
        let reopener = WindowReopener()
        var opened = 0
        reopener.register { opened += 1 }
        XCTAssertFalse(reopener.handleReopen(hasVisibleWindows: true))
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(reopener.handleReopen(hasVisibleWindows: false))
        XCTAssertEqual(opened, 1)
    }

    // Glisser un élément sélectionné emporte toute la sélection du panneau d'origine.
    func testDraggingASelectedItemCarriesTheWholeSelection() {
        let a = URL(fileURLWithPath: "/src/a"), b = URL(fileURLWithPath: "/src/b"), c = URL(fileURLWithPath: "/src/c")
        XCTAssertEqual(OneOffPlanner.expandDrop([b], selection: [a, b]).map(\.path), ["/src/a", "/src/b"])
        XCTAssertEqual(OneOffPlanner.expandDrop([c], selection: [a, b]), [c], "élément non sélectionné : lui seul")
        XCTAssertEqual(OneOffPlanner.expandDrop([a, c], selection: [a, b]), [a, c], "dépôt du Finder : tel quel")
    }

    // Un dépôt dont rien ne peut être copié est expliqué au lieu d'être ignoré en silence.
    func testRefusedDropIsReported() {
        let folder = URL(fileURLWithPath: "/dest/photos")
        XCTAssertTrue(OneOffPlanner.isRefusedDrop([URL(fileURLWithPath: "/dest/photos")], into: folder))
        XCTAssertTrue(OneOffPlanner.isRefusedDrop([URL(fileURLWithPath: "/dest/photos/x.txt")], into: folder))
        XCTAssertFalse(OneOffPlanner.isRefusedDrop([URL(fileURLWithPath: "/a/x.txt")], into: folder))
        XCTAssertFalse(OneOffPlanner.isRefusedDrop([], into: folder))
    }

    // L'assistant ne boucle pas sans fin si rclone repose une question à réponse automatique.
    func testAutomaticAnswersAreCapped() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([]))
        let loop = RemoteQuestion(state: "s", option: "config_change_team_drive")
        agent.setConfigOutcomes(Array(repeating: .success(.question(loop)), count: 60))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let wizard = WizardModel(model: model, localizer: Localizer(language: "fr"))
        wizard.choose(.dropbox); wizard.next(); wizard.next()
        await wizard.connect()
        XCTAssertNotNil(wizard.error)
        XCTAssertLessThanOrEqual(agent.configured.count, 25)
    }

    // « Corriger » qui ne peut pas supprimer la connexion le dit, au lieu de revenir aux réglages en silence.
    func testFixReportsAFailedDeletion() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([]))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let wizard = WizardModel(model: model, localizer: Localizer(language: "fr"))
        wizard.choose(.s3); wizard.accessKey = "A"; wizard.secretKey = "S"; wizard.next(); wizard.next()
        agent.setConfigOutcomes([.success(.done)])
        agent.setRemoteTest(RemoteTestResult(ok: false, message: "refus"))
        await wizard.connect()
        agent.setPerformError(AgentClientError.unreachable)
        await wizard.fix()
        XCTAssertEqual(wizard.step, .test)
        XCTAssertNotNil(wizard.error)
    }

    func testTranslocationLookupOfANormalApp() {
        XCTAssertNil(InstallLocation.originalURL(ofTranslocated: URL(fileURLWithPath: "/Applications/SyncMacPro.app")))
    }
}
