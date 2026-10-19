import SwiftUI
import XCTest
@testable import SyncMacProUI

@MainActor
final class RootViewTests: XCTestCase {
    func testOnboardingOnlyWhenUnreachableAndNotInstalled() {
        let show = RootView.shouldShowOnboarding
        XCTAssertTrue(show(.unreachable, .notRegistered))
        XCTAssertTrue(show(.unreachable, .notFound))
        XCTAssertFalse(show(.unreachable, .enabled), "installé mais muet : bandeau « ne répond pas », pas d'accueil")
        XCTAssertFalse(show(.unreachable, .requiresApproval))
        XCTAssertFalse(show(.connected, .notRegistered), "un agent déjà connecté (développement) n'a pas besoin d'accueil")
        XCTAssertFalse(show(.connecting, .notRegistered))
        XCTAssertFalse(show(.reconnecting(attempt: 2), .notRegistered))
    }

    func testSidebarEntries() {
        // 1.7.0 : plus d'historique global (il est dans le détail de chaque tâche).
        XCTAssertEqual(SidebarItem.allCases, [.dashboard, .tasks, .copy, .connections, .settings])
    }

    func testOnboardingRendersForEveryInstallState() throws {
        for (index, state) in [AgentInstallState.notRegistered, .requiresApproval, .notFound].enumerated() {
            let installer = AgentInstaller(service: StubService(state))
            let view = OnboardingView(installer: installer, localizer: Localizer(language: "fr"), onInstall: {})
            let image = try render(view, name: "onboarding-\(index)", size: CGSize(width: 640, height: 420), scheme: .light)
            assertNotBlank(image)
        }
    }

    func testSettingsRenders() throws {
        let installer = AgentInstaller(service: StubService(.enabled))
        let view = SettingsView(installer: installer, loginItem: LoginItemModel(control: StubLogin()), localizer: Localizer(language: "fr"))
        // Un `Form` s'appuie sur AppKit : on vérifie seulement que le rendu ne plante pas.
        let image = try render(view, name: "settings", size: CGSize(width: 520, height: 520), scheme: .light)
        XCTAssertGreaterThan(image.width, 0)
    }
}

private struct StubService: ServiceControlling {
    let state: AgentInstallState
    init(_ state: AgentInstallState) { self.state = state }
    func status() -> AgentInstallState { state }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

private struct StubLogin: LoginItemControlling {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
}
