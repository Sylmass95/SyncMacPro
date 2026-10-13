import XCTest
import SyncKit
@testable import SyncMacProUI

/// Corrections issues de la relecture finale de la branche 4 (app).
@MainActor
final class ReviewFix4UITests: XCTestCase {
    // I2 : « Corriger » pendant une reconnexion ne supprime pas la connexion existante.
    func testFixDuringReconnectKeepsTheRemote() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([RemoteInfo(name: "Dropbox", type: "dropbox")]))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let wizard = WizardModel(reconnecting: RemoteInfo(name: "Dropbox", type: "dropbox"), model: model, localizer: Localizer(language: "fr"))
        agent.setConfigOutcomes([.success(.done)])
        agent.setRemoteTest(RemoteTestResult(ok: false, message: "réseau"))
        await wizard.connect()
        XCTAssertEqual(wizard.step, .test)
        await wizard.fix()
        XCTAssertFalse(agent.performed.contains(.deleteRemote("Dropbox")))
        XCTAssertEqual(wizard.step, .connect)
    }
}
