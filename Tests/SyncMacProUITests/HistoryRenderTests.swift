import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class HistoryRenderTests: XCTestCase {
    func testTableBodyRendersRowsWithSelection() throws {
        let rows = UIFixtures.history()
        for scheme in [ColorScheme.light, .dark] {
            let table = HistoryTableBody(
                rows: Array(rows.prefix(14)), selection: rows[2].id, text: UIFixtures.french,
                localizer: UIFixtures.french.localizer, onSelect: { _ in }
            )
            let image = try render(table, name: "history-table", size: CGSize(width: 980, height: 520), scheme: scheme)
            assertNotBlank(image)
        }
    }
}
