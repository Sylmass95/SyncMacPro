import XCTest
@testable import SyncMacProUI

/// 1.7.9 : comme dans le Finder, un séparateur tire le bord droit de la colonne à sa gauche ; les colonnes suivantes
/// se décalent sans changer de largeur, la place libre reste à droite (avant Actions).
final class Columns177Tests: XCTestCase {
    func testEachSeparatorResizesTheColumnOnItsLeft() {
        XCTAssertNil(ListColumns.separatorTarget(after: .rank))
        XCTAssertEqual(ListColumns.separatorTarget(after: .task), .task)
        XCTAssertEqual(ListColumns.separatorTarget(after: .state), .state)
        XCTAssertEqual(ListColumns.separatorTarget(after: .last), .last)
    }

    func testDraggingRightWidensTheColumnOnTheLeft() {
        var columns = ListColumns()
        let start = columns.width(.last)
        columns.drag(.last, from: start, translation: 30, available: 3000)
        XCTAssertEqual(columns.width(.last), start + 30)
        columns.drag(.last, from: start, translation: -30, available: 3000)
        XCTAssertEqual(columns.width(.last), start - 30, "réduire Dernière exécution ne touche pas à État")
        XCTAssertEqual(columns.width(.state), ListColumn.state.standard)
    }

    func testColumnsNeverOverflowTheList() {
        var columns = ListColumns()
        let available: CGFloat = 1100
        columns.drag(.state, from: columns.width(.state), translation: 5000, available: available)
        let used = ListColumn.allCases.reduce(0) { $0 + columns.width($1) } + CGFloat(ListColumn.allCases.count - 1) * ListColumns.spacing
        XCTAssertEqual(used, available, accuracy: 0.5)
    }

    func testTheTaskColumnCanBeResized() {
        var columns = ListColumns()
        columns.drag(.task, from: columns.width(.task), translation: 80, available: 3000)
        XCTAssertEqual(columns.width(.task), ListColumn.task.standard + 80)
        XCTAssertTrue(ListColumn.task.resizable)
    }
}
