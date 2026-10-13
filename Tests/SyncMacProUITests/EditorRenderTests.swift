import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class EditorRenderTests: XCTestCase {
    func filledDraft() -> TaskDraft {
        var draft = TaskDraft.template(.copyToNAS)
        draft.source.path = "/Users/moi/Photos"
        draft.destination.path = "/Volumes/NAS/Photos"
        draft.mode = .mirror
        draft.name = "Photos vers le NAS"
        return draft
    }

    func content(
        _ step: EditorStep, draft: TaskDraft, simulation: SimulationState = .idle, offline: Bool = false,
        language: String = "fr"
    ) -> some View {
        EditorStepContent(
            draft: .constant(draft), step: step,
            text: TaskSummaryText(localizer: Localizer(language: language), now: UIFixtures.now),
            resolver: .localOnly, simulation: simulation, saveError: nil, offline: offline,
            onSimulate: {}, onCancelSimulation: {}
        )
        .padding(20)
    }

    func testEveryStepRenders() throws {
        for step in EditorStep.allCases {
            let image = try render(content(step, draft: filledDraft()), name: "editor-\(step.rawValue)",
                                   size: CGSize(width: 720, height: 560), scheme: .light)
            assertNotBlank(image)
        }
    }

    func testEmptyDraftAndEnglishRender() throws {
        let image = try render(content(.endpoints, draft: TaskDraft(), language: "en"), name: "editor-empty-en",
                               size: CGSize(width: 720, height: 400), scheme: .dark)
        assertNotBlank(image)
    }

    func testSummaryWithASimulationThatDeletesRenders() throws {
        let result = SimulationResult(status: .succeeded, filesToTransfer: 128, bytesToTransfer: 3_400_000_000, deletions: 42, message: nil)
        let image = try render(content(.summary, draft: filledDraft(), simulation: .finished(.finished(result))),
                               name: "editor-summary-simulated", size: CGSize(width: 720, height: 560), scheme: .light)
        assertNotBlank(image)
        let failed = try render(content(.summary, draft: filledDraft(), simulation: .finished(.failed("source introuvable")), offline: true),
                                name: "editor-summary-failed", size: CGSize(width: 720, height: 560), scheme: .dark)
        assertNotBlank(failed)
    }
}
