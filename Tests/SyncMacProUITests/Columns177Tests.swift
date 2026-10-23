import XCTest
@testable import SyncMacProUI

/// 1.7.7 : les colonnes à droite de Tâche sont collées au bord droit ; un séparateur agit donc sur la colonne à sa
/// droite, et le glisser vers la droite la rétrécit (le séparateur suit la souris). Tâche garde sa largeur minimale.
final class Columns177Tests: XCTestCase {
    func testEachSeparatorResizesTheColumnOnItsRight() {
        XCTAssertNil(ListColumns.separatorTarget(after: .rank))
        XCTAssertEqual(ListColumns.separatorTarget(after: .task), .state)
        XCTAssertEqual(ListColumns.separatorTarget(after: .state), .last)
        XCTAssertNil(ListColumns.separatorTarget(after: .last), "Actions ne se redimensionne pas")
    }

    func testDraggingRightMovesTheSeparatorRight() {
        var columns = ListColumns()
        let start = columns.width(.last)
        columns.drag(.last, from: start, translation: 30, available: 2000)
        XCTAssertEqual(columns.width(.last), start - 30, "glisser vers la droite rétrécit la colonne de droite")
        columns.drag(.last, from: start, translation: -30, available: 2000)
        XCTAssertEqual(columns.width(.last), start + 30)
    }

    func testTheTaskColumnKeepsItsMinimumWidth() {
        var columns = ListColumns()
        let available: CGFloat = 900
        columns.drag(.state, from: columns.width(.state), translation: -5000, available: available)
        let used = ListColumn.allCases.filter { $0 != .task }.reduce(0) { $0 + columns.width($1) }
            + CGFloat(ListColumn.allCases.count - 1) * ListColumns.spacing
        XCTAssertEqual(available - used, ListColumn.task.minimum, accuracy: 0.5)
    }

    func testWideWindowsAllowWiderColumns() {
        var columns = ListColumns()
        columns.drag(.state, from: columns.width(.state), translation: -500, available: 3000)
        XCTAssertEqual(columns.width(.state), ListColumn.state.standard + 500)
    }
}
