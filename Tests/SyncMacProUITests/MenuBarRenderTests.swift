import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class MenuBarRenderTests: XCTestCase {
    func testPanelRendersWithActiveCopiesAndUpcomingRuns() throws {
        for scheme in [ColorScheme.light, .dark] {
            let panel = MenuBarPanel(model: UIFixtures.model(), text: UIFixtures.french, onOpen: {}, onQuit: {})
            let image = try render(panel, name: "menubar-panel", size: CGSize(width: 320, height: 420), scheme: scheme)
            assertNotBlank(image)
        }
    }

    func testPanelRendersWhenNothingRunsAndWhenDisconnected() throws {
        let idle = AgentModel.preview(status: AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: []))
        let image1 = try render(
            MenuBarPanel(model: idle, text: UIFixtures.english, onOpen: {}, onQuit: {}),
            name: "menubar-idle", size: CGSize(width: 320, height: 260), scheme: .light
        )
        assertNotBlank(image1)
        let down = AgentModel.preview(connection: .unreachable, status: nil)
        let image2 = try render(
            MenuBarPanel(model: down, text: UIFixtures.french, onOpen: {}, onQuit: {}),
            name: "menubar-down", size: CGSize(width: 320, height: 300), scheme: .dark
        )
        assertNotBlank(image2)
    }

    func testLabelsRenderForEveryState() throws {
        let states: [MenuBarState] = [
            .idle, .copying(percent: 42, count: 1), .copying(percent: nil, count: 3), .paused, .error, .disconnected,
        ]
        for (index, state) in states.enumerated() {
            let label = MenuBarLabel(state: state, localizer: Localizer(language: "fr")).padding(8)
            let image = try render(label, name: "menubar-label-\(index)", size: CGSize(width: 90, height: 28), scheme: .light)
            XCTAssertGreaterThan(image.width, 0)
        }
    }
}
