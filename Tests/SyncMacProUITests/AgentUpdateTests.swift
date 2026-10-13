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
        init(_ state: AgentInstallState) { current = state }
        func status() -> AgentInstallState { lock.withLock { current } }
        func register() throws { lock.withLock { calls.append("register"); current = .enabled } }
        func unregister() throws { lock.withLock { calls.append("unregister"); current = .notRegistered } }
        func openSystemSettings() {}
    }

    func defaults() -> UserDefaults {
        let name = "maj-agent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAnUpdatedAppReRegistersItsAgent() {
        let service = RecordingService(.enabled)
        let store = defaults()
        store.set("1.0.0 (113)", forKey: AgentInstaller.registeredBuildKey)
        let installer = AgentInstaller(service: service)
        installer.reRegisterAfterUpdate(currentBuild: "1.1.0 (121)", defaults: store)
        XCTAssertEqual(service.calls, ["unregister", "register"])
        XCTAssertEqual(store.string(forKey: AgentInstaller.registeredBuildKey), "1.1.0 (121)")
        XCTAssertEqual(installer.state, .enabled)
        installer.reRegisterAfterUpdate(currentBuild: "1.1.0 (121)", defaults: store)
        XCTAssertEqual(service.calls.count, 2, "même version : rien à refaire")
    }

    func testNothingHappensWhenTheAgentIsNotInstalledOrInDevelopment() {
        let service = RecordingService(.notRegistered)
        let installer = AgentInstaller(service: service)
        installer.reRegisterAfterUpdate(currentBuild: "1.1.0 (121)", defaults: defaults())
        XCTAssertTrue(service.calls.isEmpty, "l'utilisateur n'a pas installé l'agent : on ne l'installe pas à sa place")
        let enabled = RecordingService(.enabled)
        AgentInstaller(service: enabled).reRegisterAfterUpdate(currentBuild: "dev", defaults: defaults())
        XCTAssertTrue(enabled.calls.isEmpty, "construction de développement : pas de bundle à réenregistrer")
    }

    func testInstallRemembersTheBuild() {
        let store = defaults()
        let installer = AgentInstaller(service: RecordingService(.notRegistered))
        installer.install(currentBuild: "1.1.0 (121)", defaults: store)
        XCTAssertEqual(store.string(forKey: AgentInstaller.registeredBuildKey), "1.1.0 (121)")
    }
}
