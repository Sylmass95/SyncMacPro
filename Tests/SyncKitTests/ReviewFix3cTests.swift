import XCTest
@testable import SyncKit

/// Corrections issues de la relecture finale de la branche 3c (agent et validation).
final class ReviewFix3cValidatorTests: XCTestCase {
    // I1 : un élément choisi est un nom (ou un chemin) simple, jamais « . », « .. », vide ou absolu.
    func testItemsMustBePlainNames() {
        for bad in [".", "..", "", "/", "a/../b", "/etc", "./x"] {
            var task = SyncTask(name: "t", source: .local(path: "/a/b"), destination: .local(path: "/a"), mode: .mirror)
            task.sourceItems = [bad]
            XCTAssertEqual(TaskValidator.problems(in: task), [.invalidItem], bad)
        }
        var fine = SyncTask(name: "t", source: .local(path: "/a/b"), destination: .local(path: "/c"))
        fine.sourceItems = ["photos/2024", "x.txt", ".cache"]
        XCTAssertEqual(TaskValidator.problems(in: fine), [])
    }
}

final class ReviewFix3cAgentTests: XCTestCase {
    // I2 : une copie ponctuelle encore en file à l'arrêt de l'agent figure « interrompue » dans l'historique.
    func testQueuedOneOffIsRecordedAsInterruptedAtShutdown() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let copies = (0..<3).map { makeTask("c\($0)", schedule: .manual) }
        for copy in copies { try await core.runOnce(copy) }
        await core.shutdown()
        for copy in copies {
            XCTAssertEqual(try h.history.list(taskID: copy.id).first?.status, .interrupted, copy.name)
        }
    }

    // I3 : une copie ponctuelle bloquée ne demande pas une validation impossible.
    func testBlockedOneOffExplainsHowToRetry() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.status.set(.blocked)
        let core = h.makeCore()
        await core.start()
        try await core.runOnce(makeTask("Synchronisation de a vers b", schedule: .manual, mode: .mirror))
        await core.waitForIdle()
        let message = try XCTUnwrap(h.notifier.messages.get().last)
        XCTAssertFalse(message.title.contains("validation"), message.title)
        XCTAssertTrue(message.body.contains("simulation"), message.body)
    }
}
