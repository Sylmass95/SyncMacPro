import XCTest
import SyncKit
@testable import SyncMacProUI

/// Revue finale de la 1.7.0, côté app.
@MainActor
final class Review170UITests: XCTestCase {
    /// L'onglet Réglages se recrée quand la tâche change ailleurs (éditeur, Désactiver) : il ne réécrit jamais d'anciennes valeurs.
    func testSettingsTabFollowsTheTaskWhenItChangesElsewhere() {
        var task = SyncTask(name: "A", source: .local(path: "/a"), destination: .local(path: "/b"), schedule: .daily(hour: 2, minute: 0))
        let before = TaskSettingsTab.identity(task)
        task.schedule = .daily(hour: 21, minute: 0)
        XCTAssertNotEqual(TaskSettingsTab.identity(task), before)
        task.isEnabled = false
        XCTAssertNotEqual(TaskSettingsTab.identity(task), before)
    }

    /// Les colonnes tiennent dans la liste à la taille minimale de la fenêtre (940 pt moins la barre latérale).
    func testRowFitsTheMinimumWindow() {
        XCTAssertLessThanOrEqual(TaskRow.minimumWidth, 680)
    }

    /// L'historique se recharge quand une exécution démarrée se termine (même identifiant d'exécution).
    func testHistoryReloadsWhenTheRunFinishes() {
        var info = AgentTaskInfo(id: UUID(), name: "A", state: .running)
        var record = RunRecord(taskID: info.id, taskName: "A", engine: .rsync, mode: .copy, startedAt: Date())
        info.lastRun = record
        let running = TaskDetailView.historyReloadKey(info)
        record.status = .succeeded
        record.finishedAt = Date()
        info.lastRun = record
        XCTAssertNotEqual(TaskDetailView.historyReloadKey(info), running)
    }

    /// Une copie ponctuelle n'a pas d'onglet Réglages : l'onglet affiché revient à l'historique.
    func testOneOffFallsBackToHistory() {
        XCTAssertEqual(TaskDetailView.effectiveTab(.settings, hasTask: false), .history)
        XCTAssertEqual(TaskDetailView.effectiveTab(.settings, hasTask: true), .settings)
        XCTAssertEqual(TaskDetailView.effectiveTab(.log, hasTask: false), .log)
    }
}
