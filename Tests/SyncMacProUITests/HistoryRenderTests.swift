import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class HistoryRenderTests: XCTestCase {
    func view(
        _ model: AgentModel, text: CardText = UIFixtures.french, filter: HistoryFilter = HistoryFilter(),
        selection: UUID? = nil
    ) -> HistoryView {
        HistoryView(model: model, localizer: text.localizer, filter: filter, selection: selection, now: UIFixtures.now)
    }

    func testHistoryRendersInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let model = UIFixtures.model()
            let selected = model.history[2].id
            let image = try render(
                view(model, selection: selected), name: "history", size: CGSize(width: 980, height: 620), scheme: scheme
            )
            assertNotBlank(image)
        }
    }

    func testFilteredEmptyAndErrorStatesRender() throws {
        var filter = HistoryFilter()
        filter.search = "zzzz"
        let filtered = try render(
            view(UIFixtures.model(), filter: filter), name: "history-filtered",
            size: CGSize(width: 980, height: 300), scheme: .light
        )
        assertNotBlank(filtered)
        let empty = AgentModel.preview(status: nil, history: [])
        let emptyImage = try render(
            view(empty, text: UIFixtures.english), name: "history-empty",
            size: CGSize(width: 980, height: 300), scheme: .light
        )
        assertNotBlank(emptyImage)
        let failing = AgentModel.preview(status: nil, history: [], historyError: "base verrouillée")
        let errorImage = try render(
            view(failing), name: "history-error", size: CGSize(width: 980, height: 300), scheme: .dark
        )
        assertNotBlank(errorImage)
    }

    func test500RowsDoNotBreakTheView() throws {
        let many = (0..<500).map { UIFixtures.record($0 % 5, .succeeded, hoursAgo: Double($0)) }
        let model = AgentModel.preview(status: nil, history: many)
        let image = try render(view(model), name: "history-500", size: CGSize(width: 980, height: 620), scheme: .light)
        assertNotBlank(image)
    }

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
