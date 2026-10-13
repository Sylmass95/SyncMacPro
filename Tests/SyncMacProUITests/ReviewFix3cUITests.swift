import XCTest
import SyncKit
@testable import SyncMacProUI

/// Corrections issues de la relecture finale de la branche 3c (côté app).
@MainActor
final class ReviewFix3cUITests: XCTestCase {
    // Les suppressions acceptées ne valent que pour la simulation vue : une nouvelle simulation les annule.
    func testNewSimulationClearsTheAcceptedDeletions() {
        var flow = ConfirmationFlow()
        let deleting = SimulationResult(status: .succeeded, filesToTransfer: 0, bytesToTransfer: 0, deletions: 3, message: nil)
        flow.finish(.finished(deleting))
        flow.acceptDeletions = true
        XCTAssertTrue(flow.acceptsDeletions(isSync: true))
        flow.beginSimulation()
        XCTAssertFalse(flow.acceptDeletions)
        XCTAssertFalse(flow.acceptsDeletions(isSync: true))
        flow.acceptDeletions = true
        XCTAssertFalse(flow.acceptsDeletions(isSync: true), "rien à accepter tant que la simulation tourne")
        XCTAssertFalse(flow.acceptsDeletions(isSync: false))
    }
}
