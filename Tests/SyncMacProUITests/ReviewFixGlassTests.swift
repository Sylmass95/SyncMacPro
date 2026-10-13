import SwiftUI
import XCTest
@testable import SyncMacProUI

/// Corrections issues de la relecture finale du thème verre.
@MainActor
final class ReviewFixGlassTests: XCTestCase {
    // I4 : les boutons de verre suivent la taille demandée (petits dans les cartes, grand à l'accueil).
    func testButtonMetricsFollowTheControlSize() {
        let small = GlassButtonMetrics(.small), regular = GlassButtonMetrics(.regular), large = GlassButtonMetrics(.large)
        XCTAssertLessThan(small.vertical, regular.vertical)
        XCTAssertLessThan(regular.vertical, large.vertical)
        XCTAssertLessThan(small.horizontal, regular.horizontal)
        XCTAssertLessThan(regular.horizontal, large.horizontal)
        XCTAssertEqual(GlassButtonMetrics(.mini).vertical, small.vertical, "mini comme petit")
    }
}
