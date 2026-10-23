import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class MenuBarRenderTests: XCTestCase {
    func testPanelRendersWithActiveCopiesAndUpcomingRuns() throws {
        for scheme in [ColorScheme.light, .dark] {
            let panel = MenuBarPanel(model: UIFixtures.model(), text: UIFixtures.french, onOpen: {}, onQuit: {})
            let image = try render(panel, name: "menubar-panel", size: CGSize(width: 340, height: 460), scheme: scheme)
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

    /// 1.7.0 : « à venir » suit l'ordre de la liste (en attente et programmées), trois au plus.
    func testMenuBarUpcomingFollowsTheList() {
        let ids = (0..<5).map { _ in UUID() }
        let infos = [
            AgentTaskInfo(id: ids[0], name: "A", state: .idle, nextDue: Date(timeIntervalSince1970: 9_000)),
            AgentTaskInfo(id: ids[1], name: "B", state: .queued),
            AgentTaskInfo(id: ids[2], name: "C", state: .idle),
            AgentTaskInfo(id: ids[3], name: "D", state: .idle, nextDue: Date(timeIntervalSince1970: 1_000)),
            AgentTaskInfo(id: ids[4], name: "E", state: .idle, nextDue: Date(timeIntervalSince1970: 500)),
        ]
        let manual: Set<UUID> = [ids[2]]
        XCTAssertEqual(MenuBarPanel.upcoming(infos, isManual: { manual.contains($0) }).map(\.name), ["A", "B", "D"])
    }
}
