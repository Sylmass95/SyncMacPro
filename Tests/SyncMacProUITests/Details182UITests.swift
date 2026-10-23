import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.8.2 : fenêtre « Détails » d'une exécution : tableau Action / Taille / Chemin, recherche, filtre, totaux, CSV.
@MainActor
final class Details182UITests: XCTestCase {
    let rows = [
        RunDetailRow(action: .added, size: 1_000, path: "2026/Été/rush.mp4"),
        RunDetailRow(action: .updated, size: 20, path: "script.docx"),
        RunDetailRow(action: .deleted, size: nil, path: "vieux; \"cité\".txt"),
        RunDetailRow(action: .touched, size: 5, path: "date.txt"),
    ]

    func testFilterAndSearch() {
        XCTAssertEqual(RunDetailsView.filtered(rows, filter: .all, query: "").count, 4)
        XCTAssertEqual(RunDetailsView.filtered(rows, filter: .copied, query: "").map(\.path), ["2026/Été/rush.mp4", "script.docx"])
        XCTAssertEqual(RunDetailsView.filtered(rows, filter: .deleted, query: "").map(\.path), ["vieux; \"cité\".txt"])
        XCTAssertEqual(RunDetailsView.filtered(rows, filter: .all, query: "ete").map(\.path), ["2026/Été/rush.mp4"], "sans accents ni majuscules")
    }

    func testTotalsLine() {
        let details = RunDetails(rows: rows, totals: [.added: .init(count: 1, bytes: 1_000), .updated: .init(count: 1, bytes: 20), .deleted: .init(count: 1, bytes: 0)], truncated: false)
        let line = RunDetailsView.totalsLine(details, localizer: UIFixtures.french.localizer)
        XCTAssertTrue(line.contains("1 nouveau"), line)
        XCTAssertTrue(line.contains("1 mis à jour"), line)
        XCTAssertTrue(line.contains("1 supprimé"), line)
    }

    func testCSVExport() {
        let csv = RunDetailsView.csv(rows, localizer: UIFixtures.french.localizer)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Action;Taille (octets);Chemin")
        XCTAssertEqual(lines[1], "Nouveau;1000;2026/Été/rush.mp4")
        XCTAssertEqual(lines[3], "Supprimé;;\"vieux; \"\"cité\"\".txt\"", "point-virgule et guillemets protégés")
    }

    func testRenders() throws {
        let details = RunDetails(rows: rows, totals: [.added: .init(count: 1, bytes: 1_000)], truncated: true)
        let view = RunDetailsContent(details: details, filter: .all, query: "", localizer: UIFixtures.french.localizer)
        assertNotBlank(try render(view, name: "details-182", size: CGSize(width: 760, height: 360), scheme: .light))
    }
}
