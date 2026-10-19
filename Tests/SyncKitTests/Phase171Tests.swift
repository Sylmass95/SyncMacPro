import XCTest
@testable import SyncKit

/// 1.7.1 : pendant la vérification préalable (rsync compare la source et la destination), la copie semblait figée :
/// l'agent annonce maintenant l'étape à l'app.
final class Phase171Tests: XCTestCase {
    func testThePreparationStepIsReported() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        h.factory.phase.set(.planning)
        let task = SyncTask(name: "A", source: .local(path: "/a"), destination: .local(path: "/b"))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        let reported = await eventually { await core.status().tasks.first?.phase == "planning" }
        XCTAssertTrue(reported)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        let after = await core.status().tasks.first?.phase
        XCTAssertNil(after, "plus d'étape une fois fini")
    }
}
