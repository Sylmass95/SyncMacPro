import XCTest
import Sparkle
import SyncKit
@testable import SyncMacProUI

/// Sous-projet 8 : le pilote silencieux (aucune fenêtre de Sparkle) traduit Sparkle pour l'app.
@MainActor
final class SparkleDriverTests: XCTestCase {
    func driver() -> (SparkleUpdateDriver, () -> [UpdateEvent]) {
        let driver = SparkleUpdateDriver(bundle: .main)
        var events: [UpdateEvent] = []
        driver.onEvent = { events.append($0) }
        return (driver, { events })
    }

    func testFoundUpdateIsDownloadedWithoutAsking() {
        let (driver, events) = driver()
        var choice: SPUUserUpdateChoice?
        driver.updateFound(version: "1.6.1") { choice = $0 }
        XCTAssertEqual(choice, .install, "téléchargement sans fenêtre")
        XCTAssertEqual(events(), [.downloading("1.6.1")])
    }

    func testReadyUpdateWaitsForInstallNow() {
        let (driver, events) = driver()
        driver.updateFound(version: "1.6.1") { _ in }
        var replies: [SPUUserUpdateChoice] = []
        driver.readyToInstall { replies.append($0) }
        XCTAssertEqual(events().last, .ready("1.6.1"))
        XCTAssertTrue(replies.isEmpty, "rien tant que l'app ne décide pas")
        driver.installNow()
        driver.installNow()
        XCTAssertEqual(replies, [.install], "une seule réponse")
        XCTAssertEqual(events().last, .installing)
    }

    func testOtherAnswers() {
        let (driver, events) = driver()
        driver.checking()
        driver.notFound()
        driver.failed("Le flux est mal signé.")
        XCTAssertEqual(events(), [.checking, .upToDate, .failed("Le flux est mal signé.")])
        driver.automaticallyChecks = false
        XCTAssertFalse(driver.permissionResponse().automaticUpdateChecks)
    }

    func testOnlyAnInstalledAppGetsADriver() {
        XCTAssertNil(SparkleUpdateDriver.makeIfBundled(bundle: Bundle(for: Self.self)), "paquet de tests : pas d'app")
        XCTAssertNil(SparkleUpdateDriver.makeIfBundled(bundle: .main))
    }

    func testAgentIdlenessIsUnknownUntilTheAgentAnswers() {
        XCTAssertNil(UpdatePolicy.agentIdleness(connection: .connecting, status: nil), "au lancement : on attend")
        XCTAssertNil(UpdatePolicy.agentIdleness(connection: .reconnecting(attempt: 1), status: nil))
        XCTAssertEqual(UpdatePolicy.agentIdleness(connection: .unreachable, status: nil), true)
        let busy = AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil,
                               tasks: [AgentTaskInfo(id: UUID(), name: "t", state: .running)])
        XCTAssertEqual(UpdatePolicy.agentIdleness(connection: .connected, status: busy), false)
    }

    // Relecture finale : Sparkle reprend une installation déjà commencée par « mise à jour trouvée » au stade
    // « installation » ; répondre tout de suite installerait sans vérifier le repos de l'agent.
    func testResumedInstallationWaitsForTheApp() {
        let (driver, events) = driver()
        var replies: [SPUUserUpdateChoice] = []
        driver.updateFound(version: "1.6.1", resuming: true) { replies.append($0) }
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(events().last, .ready("1.6.1"))
        driver.installNow()
        XCTAssertEqual(replies, [.install])
    }
}
