import SwiftUI
import XCTest
@testable import SyncMacProUI

@MainActor
final class DashboardRenderTests: XCTestCase {
    func content(_ model: AgentModel, install: AgentInstallState = .enabled, text: CardText = UIFixtures.french) -> some View {
        DashboardBody(model: model, installState: install, text: text, onInstall: {})
    }

    func testDashboardRendersInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(content(UIFixtures.model()), name: "dashboard", size: CGSize(width: 900, height: 760), scheme: scheme)
            assertNotBlank(image)
        }
    }

    func testDashboardRendersInEnglish() throws {
        let image = try render(
            content(UIFixtures.model(), text: UIFixtures.english), name: "dashboard-en",
            size: CGSize(width: 900, height: 760), scheme: .light
        )
        assertNotBlank(image)
    }

    func testGlobalPauseAndRecoveredBannerRender() throws {
        let model = UIFixtures.model(paused: true, recovered: true)
        let image = try render(content(model), name: "dashboard-paused", size: CGSize(width: 900, height: 760), scheme: .light)
        assertNotBlank(image)
    }

    func testConnectionBannersRender() throws {
        let cases: [(String, ConnectionState, AgentInstallState)] = [
            ("unreachable", .unreachable, .notRegistered),
            ("reconnecting", .reconnecting(attempt: 3), .enabled),
            ("version", .versionMismatch(agent: 7), .enabled),
            ("connecting", .connecting, .enabled),
        ]
        for (name, connection, install) in cases {
            let model = AgentModel.preview(connection: connection, status: nil)
            let image = try render(
                content(model, install: install), name: "banner-\(name)",
                size: CGSize(width: 700, height: 220), scheme: .light
            )
            assertNotBlank(image)
        }
    }

    func testEmptyStateRenders() throws {
        let image = try render(
            content(UIFixtures.model(empty: true)), name: "dashboard-empty",
            size: CGSize(width: 700, height: 360), scheme: .dark
        )
        assertNotBlank(image)
    }

    func testCardForAnUnknownTaskDoesNotCrash() throws {
        // `listTasks` en retard : la carte existe mais le modèle ne connaît pas encore la tâche.
        let info = UIFixtures.infos[1]
        let card = TaskCard(
            info: info, task: nil, progress: nil, busy: true, text: UIFixtures.french, actions: TaskCardActions()
        )
        let image = try render(card, name: "card-unknown", size: CGSize(width: 360, height: 260), scheme: .light)
        assertNotBlank(image)
    }
}
