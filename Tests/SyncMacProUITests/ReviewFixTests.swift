import XCTest
import SyncKit
@testable import SyncMacProUI

/// Corrections issues de la relecture finale de la branche 3a.
@MainActor
final class ReviewFixTests: XCTestCase {
    var agent: FakeAgent!
    var sleeper: ManualSleeper!
    var model: AgentModel!

    override func setUp() async throws {
        agent = FakeAgent()
        sleeper = ManualSleeper()
        model = AgentModel(agent: agent, sleeper: sleeper)
    }

    override func tearDown() async throws { model.shutdown() }

    // I1 : dans l'app, les chaînes viennent de Contents/Resources, jamais du dossier .build.
    func testStringsComeFromTheAppBundleResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FakeApp-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: root) }
        let lproj = root.appendingPathComponent("Contents/Resources/SyncMacPro_SyncMacProUI.bundle/fr.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try #""sidebar.dashboard" = "MARQUEUR";"#.write(
            to: lproj.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8
        )
        let info = ["CFBundleIdentifier": "com.test.fakeapp", "CFBundlePackageType": "APPL"] as NSDictionary
        try info.write(to: root.appendingPathComponent("Contents/Info.plist"))
        let app = try XCTUnwrap(Bundle(url: root))
        let localizer = Localizer(language: "fr", resourcesURL: Localizer.resourcesURL(in: app))
        XCTAssertEqual(localizer.text("sidebar.dashboard"), "MARQUEUR")
    }

    func testOutsideTheAppTheModuleBundleIsUsed() {
        // (Dans les tests, `Bundle.module` désigne le bundle de ressources des tests : on compare au bundle de l'interface.)
        XCTAssertEqual(Localizer.resourcesURL(in: .main).lastPathComponent, "SyncMacPro_SyncMacProUI.bundle")
    }

    // I2 : une tentative ancienne qui aboutit après « Réessayer » ne doit rien écraser.
    func testStaleFailureAfterRestartDoesNotOverwriteTheNewSession() async {
        let gate = TestGate()
        agent.setStatus(.failure(AgentClientError.unreachable))
        agent.holdNextStatus(gate)
        model.start()
        _ = await eventually { self.agent.statusCalls == 1 }
        agent.setStatus(.success(makeStatus()))
        model.restart()
        let connected = await eventually { self.model.connection == .connected }
        XCTAssertTrue(connected)
        gate.release()   // l'ancien appel échoue maintenant
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.connection, .connected, "l'ancienne boucle ne doit pas afficher « reconnexion »")
    }

    func testStaleSuccessAfterRestartDoesNotOpenASecondSession() async {
        let gate = TestGate()
        agent.setStatus(.success(makeStatus()))
        agent.holdNextStatus(gate)
        model.start()
        _ = await eventually { self.agent.statusCalls == 1 }
        model.restart()
        let connected = await eventually { self.model.connection == .connected && self.agent.watchStarts == 1 }
        XCTAssertTrue(connected)
        gate.release()   // l'ancien appel réussit maintenant
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(agent.watchStarts, 1, "une seule session doit écouter l'agent")
    }

    // I3 : un agent parti pour de bon finit en « injoignable », avec Installer et Réessayer.
    func testAgentGoneForGoodEndsUnreachableAfterTheBackoffCeiling() async {
        agent.setStatus(.success(makeStatus()))
        model.start()
        _ = await eventually { self.model.connection == .connected && self.agent.watchStarts == 1 }
        agent.setStatus(.failure(AgentClientError.unreachable))
        agent.endWatch()
        var seen = sleeper.requests.count
        for _ in 0..<10 where model.connection != .unreachable {
            _ = await eventually { self.sleeper.requests.count > seen || self.model.connection == .unreachable }
            seen = sleeper.requests.count
            sleeper.releaseAll()
        }
        XCTAssertEqual(model.connection, .unreachable)
    }
}
