import XCTest
@testable import SyncKit

final class AgentProgressStatusTests: XCTestCase {
    func testRunningTaskReportsItsProgressInTheStatus() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        var snapshot = TransferSnapshot()
        snapshot.doneBytes = 4_000
        snapshot.totalBytes = 10_000
        snapshot.overallPercent = 40
        snapshot.currentName = "gros.bin"
        h.factory.snapshot.set(snapshot)
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        let seen = await eventually { await core.status().tasks.first?.progress?.doneBytes == 4_000 }
        XCTAssertTrue(seen, "une fenêtre ouverte en pleine copie doit voir l'avancement tout de suite")
        let info = await core.status().tasks[0].progress
        XCTAssertEqual(info?.overallPercent, 40)
        XCTAssertEqual(info?.currentName, "gros.bin")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        let after = await core.status().tasks[0].progress
        XCTAssertNil(after, "plus d'avancement une fois la tâche terminée")
    }

    func testTaskInfoWithoutProgressKeyStillDecodes() throws {
        let info = AgentTaskInfo(id: UUID(), name: "a", state: .idle)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        json.removeValue(forKey: "progress")
        let decoded = try JSONDecoder().decode(AgentTaskInfo.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, info)
        XCTAssertNil(decoded.progress)
    }
}
