import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class TasksRenderTests: XCTestCase {
    func testTaskListRendersInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let list = TasksListBody(
                tasks: UIFixtures.tasks, selection: UIFixtures.ids[1], text: UIFixtures.french,
                onToggle: { _, _ in }, onEdit: { _ in }, onDuplicate: { _ in }, onDelete: { _ in }, onSelect: { _ in }
            )
            let image = try render(list, name: "tasks", size: CGSize(width: 820, height: 520), scheme: scheme)
            assertNotBlank(image)
        }
    }

    func testDashboardEmptyStateOffersCreation() throws {
        let body = DashboardBody(model: UIFixtures.model(empty: true), installState: .enabled, text: UIFixtures.french,
                                 onInstall: {}, onCreate: { _ in })
        let image = try render(body, name: "dashboard-empty-create", size: CGSize(width: 820, height: 380), scheme: .light)
        assertNotBlank(image)
    }
}
