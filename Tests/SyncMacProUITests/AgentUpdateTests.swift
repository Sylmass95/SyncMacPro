import XCTest
@testable import SyncMacProUI

/// Essai réel 1.0.0 → 1.1.0 : l'app remplacée, l'agent enregistré avec l'ancienne signature ad hoc refuse de démarrer
/// (launchd : code 78) tant qu'il n'est pas désenregistré puis réenregistré.
@MainActor
final class AgentUpdateTests: XCTestCase {
    final class RecordingService: ServiceControlling, @unchecked Sendable {
        let lock = NSLock()
        var current: AgentInstallState
        var calls: [String] = []
        /// Après `unregister`, `status()` répond encore « activé » ce nombre de fois (macOS retire l'agent en différé).
        var lag = 0
        init(_ state: AgentInstallState, lag: Int = 0) { current = state; self.lag = lag }
        func status() -> AgentInstallState {
            lock.withLock {
                if lag > 0 && current == .notRegistered { lag -= 1; return .enabled }
                return current
            }
        }
        /// Après `unregister`, launchd connaît encore le job ce nombre de fois (essai réel 1.2.1 → 1.2.2 : SMAppService
        /// répondait « retiré » tout de suite, launchd gardait l'ancien job et sa contrainte de signature).
        var jobLag = 0
        /// Nombre d'enregistrements dont le lancement échoue encore (code 78).
        var failingRegistrations = 0
        private var launchFailedNow = false
        func register() throws {
            lock.withLock {
                calls.append("register"); current = .enabled
                launchFailedNow = failingRegistrations > 0
                if failingRegistrations > 0 { failingRegistrations -= 1 }
            }
        }
        func unregister() throws { lock.withLock { calls.append("unregister"); current = .notRegistered } }
        func isJobLoaded() -> Bool {
            lock.withLock {
                guard current == .notRegistered, jobLag > 0 else { return current == .enabled }
                jobLag -= 1
                calls.append("encore chargé")
                return true
            }
        }
        func isAgentRunning() -> Bool { lock.withLock { current == .enabled && !launchFailedNow } }
        func openSystemSettings() {}
    }

    func testReRegistrationWaitsUntilLaunchdHasDroppedTheOldJob() async {
        let service = RecordingService(.enabled)
        service.jobLag = 3
        let store = defaults()
        store.set("1.2.1 (137)", forKey: AgentInstaller.registeredBuildKey)
        let installer = AgentInstaller(service: service)
        await installer.reRegisterAfterUpdate(currentBuild: "1.2.2 (143)", defaults: store, pause: { _ in })
        XCTAssertEqual(service.calls, ["unregister", "encore chargé", "encore chargé", "encore chargé", "register"])
    }

    func testALaunchStillRefusedIsRetriedOnceWithALongerWait() async {
        let service = RecordingService(.enabled)
        service.failingRegistrations = 1
        let store = defaults()
        store.set("1.2.1 (137)", forKey: AgentInstaller.registeredBuildKey)
        let installer = AgentInstaller(service: service)
        await installer.reRegisterAfterUpdate(currentBuild: "1.2.2 (143)", defaults: store, pause: { _ in })
        XCTAssertEqual(service.calls, ["unregister", "register", "unregister", "register"])
        XCTAssertEqual(store.string(forKey: AgentInstaller.registeredBuildKey), "1.2.2 (143)")
    }

    func defaults() -> UserDefaults {
        let name = "maj-agent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAnUpdatedAppReRegistersItsAgent() async {
        let service = RecordingService(.enabled)
        let store = defaults()
        store.set("1.0.0 (113)", forKey: AgentInstaller.registeredBuildKey)
        let installer = AgentInstaller(service: service)
        await installer.reRegisterAfterUpdate(currentBuild: "1.1.0 (121)", defaults: store, pause: { _ in })
        XCTAssertEqual(service.calls, ["unregister", "register"])
        XCTAssertEqual(store.string(forKey: AgentInstaller.registeredBuildKey), "1.1.0 (121)")
        XCTAssertEqual(installer.state, .enabled)
        await installer.reRegisterAfterUpdate(currentBuild: "1.1.0 (121)", defaults: store, pause: { _ in })
        XCTAssertEqual(service.calls.count, 2, "même version : rien à refaire")
    }

    func testNothingHappensWhenTheAgentIsNotInstalledOrInDevelopment() async {
        let service = RecordingService(.notRegistered)
        let installer = AgentInstaller(service: service)
        await installer.reRegisterAfterUpdate(currentBuild: "1.1.0 (121)", defaults: defaults(), pause: { _ in })
        XCTAssertTrue(service.calls.isEmpty, "l'utilisateur n'a pas installé l'agent : on ne l'installe pas à sa place")
        let enabled = RecordingService(.enabled)
        await AgentInstaller(service: enabled).reRegisterAfterUpdate(currentBuild: "dev", defaults: defaults(), pause: { _ in })
        XCTAssertTrue(enabled.calls.isEmpty, "construction de développement : pas de bundle à réenregistrer")
    }

    func testInstallRemembersTheBuild() async {
        let store = defaults()
        let installer = AgentInstaller(service: RecordingService(.notRegistered))
        installer.install(currentBuild: "1.1.0 (121)", defaults: store)
        XCTAssertEqual(store.string(forKey: AgentInstaller.registeredBuildKey), "1.1.0 (121)")
    }

    // Essai réel 1.1.1 → 1.2.0 : réenregistrer aussitôt après le désenregistrement laissait l'ancien agent chargé
    // (launchd : OS_REASON_CODESIGNING). On attend que macOS l'ait retiré, puis on laisse une seconde à launchd.
    func testReRegistrationWaitsForTheOldAgentToBeGone() async {
        let service = RecordingService(.enabled, lag: 3)
        let store = defaults()
        store.set("1.1.1 (126)", forKey: AgentInstaller.registeredBuildKey)
        let installer = AgentInstaller(service: service)
        let pauses = Counter()
        await installer.reRegisterAfterUpdate(currentBuild: "1.2.1 (140)", defaults: store, pause: { _ in pauses.increment() })
        XCTAssertEqual(service.calls, ["unregister", "register"])
        XCTAssertGreaterThanOrEqual(pauses.value, 4, "trois sondages encore « activé », puis la pause pour launchd")
        XCTAssertEqual(installer.state, .enabled)
    }

    // Réparation : un agent déclaré installé qui ne répond jamais est réenregistré, une seule fois par lancement.
    func testRepairHappensOncePerLaunch() async {
        let service = RecordingService(.enabled)
        let installer = AgentInstaller(service: service)
        let first = await installer.repairIfStuck(currentBuild: "1.2.1 (140)", defaults: defaults(), pause: { _ in })
        let second = await installer.repairIfStuck(currentBuild: "1.2.1 (140)", defaults: defaults(), pause: { _ in })
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(service.calls, ["unregister", "register"])
        let absent = RecordingService(.notRegistered)
        let none = await AgentInstaller(service: absent).repairIfStuck(currentBuild: "1.2.1 (140)", defaults: defaults(), pause: { _ in })
        XCTAssertFalse(none, "agent non installé : rien à réparer")
    }
}
