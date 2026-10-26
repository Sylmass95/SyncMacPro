import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.8.7 : panneau de la barre de menus lisible (fond opaque, cartes nettes) ; l'orange ne sert qu'aux problèmes.
@MainActor
final class MenuBar187Tests: XCTestCase {
    func testAPluggedDriveIsNotAWarning() {
        var plugged = AgentTaskInfo(id: UUID(), name: "NAS 03_ARCHIVES → Extreme Pro", state: .running)
        plugged.driveMounted = true
        XCTAssertFalse(MenuBarPanel.driveNeedsAttention(plugged))
        var suspended = plugged
        suspended.driveMounted = false
        suspended.driveSuspendedSince = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(MenuBarPanel.driveNeedsAttention(suspended))
    }

    func testThePanelRendersInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let panel = MenuBarPanel(model: UIFixtures.model(), text: UIFixtures.french, onOpen: {}, onQuit: {})
            assertNotBlank(try render(panel, name: "menubar-187", size: CGSize(width: 340, height: 460), scheme: scheme))
        }
    }
}
