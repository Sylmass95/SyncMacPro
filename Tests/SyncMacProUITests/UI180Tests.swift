import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.8.0 : l'écran Tâches rejoint le tableau de bord. Nouvelle tâche et Modèles en haut, à côté de Pause globale ;
/// Modifier, Dupliquer et Supprimer au clic droit et dans la fiche (double-clic).
@MainActor
final class UI180Tests: XCTestCase {
    func testTheTasksScreenIsGoneFromTheSidebar() {
        XCTAssertEqual(SidebarItem.allCases, [.dashboard, .copy, .connections, .settings])
    }

    func testManagingActionsForOneTask() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(TaskListView.manageActions([a], tasks: [a, b]), [.edit, .duplicate, .delete])
    }

    func testNoManagingActionsForSeveralTasksNorForOtherRuns() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(TaskListView.manageActions([a, b], tasks: [a, b]), [])
        XCTAssertEqual(TaskListView.manageActions([TaskListView.otherRunsID], tasks: [a, b]), [])
    }

    func testAOneOffCopyCannotBeEditedNorDuplicated() {
        let copy = UUID()
        XCTAssertEqual(TaskListView.manageActions([copy], tasks: []), [], "une copie ponctuelle n'est pas une tâche enregistrée")
    }

    func testEditingFromTheMenuOpensTheConfigurationTab() {
        XCTAssertEqual(DashboardBody.sheetTab(for: .edit), .configuration)
        XCTAssertEqual(DashboardBody.sheetTab(for: nil), .settings)
    }

    func testTheHeaderOffersCreationNextToTheGlobalPause() throws {
        let body = DashboardBody(model: UIFixtures.model(), installState: .enabled, text: UIFixtures.french, onInstall: {}, onCreate: { _ in })
        assertNotBlank(try render(body, name: "dashboard-180", size: CGSize(width: 1000, height: 300), scheme: .light))
    }
}
