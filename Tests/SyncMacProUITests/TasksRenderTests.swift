import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class TasksRenderTests: XCTestCase {
    func testDashboardEmptyStateOffersCreation() throws {
        let body = DashboardBody(model: UIFixtures.model(empty: true), installState: .enabled, text: UIFixtures.french,
                                 onInstall: {}, onCreate: { _ in })
        let image = try render(body, name: "dashboard-empty-create", size: CGSize(width: 820, height: 380), scheme: .light)
        assertNotBlank(image)
    }
}
