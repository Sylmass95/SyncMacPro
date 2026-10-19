import XCTest
@testable import SyncKit

/// Corrections mineures de la 1.3.0, côté agent.
final class Fix140AgentTests: XCTestCase {
    func testUnknownQueueItemHasItsOwnError() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        do { try await core.dequeue(UUID()); XCTFail("absent") } catch {
            XCTAssertEqual(error as? AgentError, .notInQueue)
            XCTAssertEqual((error as? AgentError)?.errorDescription, "Cette tâche n'est pas dans la file.")
        }
    }

}
