import XCTest
@testable import SyncKit

/// Corrections issues de la relecture finale de la branche.
final class AgentReviewFixTests: XCTestCase {
    func isWaiting(_ state: TaskRunState?) -> Bool {
        if case .waiting = state { return true }
        return false
    }

    func testQueuedRunRechecksConditionsWhenItFinallyStarts() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let a = makeTask("A"), b = makeTask("B")
        let c = makeTask("C", conditions: TaskConditions(requiresACPower: true))
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        await core.tick()
        XCTAssertEqual(h.factory.created, 2, "C attend en file")

        h.conditions.acPower.set(false)   // le Mac est débranché pendant l'attente
        h.factory.runners.get()[0].release()
        let waiting = await eventually {
            let state = await core.status().tasks.first { $0.id == c.id }?.state
            return self.isWaiting(state)
        }
        XCTAssertTrue(waiting, "C ne démarre pas sur batterie")
        XCTAssertEqual(h.factory.created, 2)

        h.conditions.acPower.set(true)
        await core.tick()
        XCTAssertEqual(h.factory.created, 3, "C démarre dès que les conditions sont réunies")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testQueuedRunIsDroppedIfTheTaskWasDisabledMeanwhile() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let a = makeTask("A"), b = makeTask("B"), c = makeTask("C")
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        await core.tick()
        XCTAssertEqual(h.factory.created, 2)

        var disabled = c
        disabled.isEnabled = false
        try h.save([a, b, disabled])
        await core.reloadTasks()
        h.factory.runners.get()[0].release()
        let dropped = await eventually { await core.status().tasks.first { $0.id == c.id }?.state == .disabled }
        XCTAssertTrue(dropped)
        XCTAssertEqual(h.factory.created, 2, "une tâche désactivée ne démarre pas, même déjà en file")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testSleepAssertionIsReleasedWhileEverythingIsPaused() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        XCTAssertEqual(h.activity.begins.get(), 1)

        await core.setGlobalPause(true)
        XCTAssertEqual(h.activity.ends.get(), 1, "une copie figée n'a pas à empêcher la veille")
        await core.setGlobalPause(false)
        XCTAssertEqual(h.activity.begins.get(), 2)

        try await core.pause(task.id)
        XCTAssertEqual(h.activity.ends.get(), 2)
        try await core.resume(task.id)
        XCTAssertEqual(h.activity.begins.get(), 3)

        h.factory.runners.get()[0].release()
        await core.waitForIdle()
        XCTAssertEqual(h.activity.ends.get(), 3)
    }

    func testAgentPlistsRelaunchTheAgentAfterACrash() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["assemble-app.sh", "dev-launchd.sh"] {   // le plist du bundle est écrit par assemble-app.sh
            let text = try String(contentsOf: root.appendingPathComponent("scripts/\(name)"), encoding: .utf8)
            XCTAssertTrue(text.contains("<key>KeepAlive</key>"), "\(name) : KeepAlive manquant")
            XCTAssertTrue(text.contains("<key>SuccessfulExit</key><false/>"), "\(name) : sortie réussie ne doit pas relancer")
        }
    }
}
