import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class DistributionRenderTests: XCTestCase {
    func testUpdateBannerRenders() throws {
        let agent = FakeAgent()
        agent.setStatus(.success(makeStatus()))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let release = ReleaseInfo(version: try XCTUnwrap(SemanticVersion("1.2.0")), url: try XCTUnwrap(URL(string: "https://example.org")))
        let view = DashboardBody(model: model, installState: .enabled, text: UIFixtures.french, onInstall: {}, update: release)
        assertNotBlank(try render(view, name: "dashboard-update", size: CGSize(width: 760, height: 300), scheme: .light))
    }

    func testOnboardingExplainsTheLocation() throws {
        for (index, problem) in [InstallLocationProblem.diskImage, .translocated].enumerated() {
            let installer = AgentInstaller(service: LocationStubService())
            let view = OnboardingView(installer: installer, localizer: Localizer(language: "fr"), location: problem, onInstall: {})
            assertNotBlank(try render(view, name: "onboarding-location-\(index)", size: CGSize(width: 640, height: 480), scheme: .light))
        }
    }
}

private struct LocationStubService: ServiceControlling {
    func status() -> AgentInstallState { .notRegistered }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}
