import XCTest
@testable import SyncKit

final class AgentControlTests: XCTestCase {
    func testRunNowIgnoresScheduleAndConditions() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.conditions.acPower.set(false)
        let task = makeTask(schedule: .manual, conditions: TaskConditions(requiresACPower: true))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testRunNowErrors() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        do { try await core.runNow(UUID()); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .unknownTask) }
        try await core.runNow(task.id)
        do { try await core.runNow(task.id); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .alreadyRunning) }
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testPauseResumeStopAreForwardedToTheRunner() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        do { try await core.pause(task.id); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .notRunning) }
        try await core.runNow(task.id)
        let started = await eventually { h.factory.runners.get()[0].calls.get().contains("run") }
        XCTAssertTrue(started)
        try await core.pause(task.id)
        var state = await core.status().tasks[0].state
        XCTAssertEqual(state, .paused)
        try await core.resume(task.id)
        state = await core.status().tasks[0].state
        XCTAssertEqual(state, .running)
        try await core.stop(task.id)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runners.get()[0].calls.get(), ["run", "pause", "resume", "stop"])
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .stopped)
    }

    func testStoppedTaskIsNotRetried() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        try await core.stop(task.id)
        await core.waitForIdle()
        await h.step(core, minutes: 120)
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testGlobalPausePausesRunsStopsNewOnesAndSurvivesARestart() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let running = makeTask("A", schedule: .manual)
        let scheduled = makeTask("B", schedule: .everyMinutes(1))
        try h.save([running, scheduled])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(running.id)

        await core.setGlobalPause(true)
        XCTAssertTrue(h.factory.runners.get()[0].calls.get().contains("pause"))
        let before = h.factory.created
        await h.step(core, minutes: 5, wait: false)
        XCTAssertEqual(h.factory.created, before, "rien ne démarre en pause globale")
        do { try await core.runNow(scheduled.id); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .globallyPaused) }

        // Redémarrage de l'agent : la pause est relue sur le disque.
        let restarted = h.makeCore()
        await restarted.start()
        let paused = await restarted.status().globalPause
        XCTAssertTrue(paused)

        await core.setGlobalPause(false)
        XCTAssertTrue(h.factory.runners.get()[0].calls.get().contains("resume"))
        let caughtUp = await eventually { h.factory.created > before }
        XCTAssertTrue(caughtUp, "à la reprise, la tâche en retard est rattrapée")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testBlockedTaskWaitsForApprovalThenRunsWithTheGuardRaised() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.status.set(.blocked)
        let task = makeTask(schedule: .everyMinutes(1), mode: .mirror)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        let state = await core.status().tasks[0].state
        XCTAssertEqual(state, .awaitingApproval)
        XCTAssertEqual(h.notifier.messages.get().count, 1)
        await h.step(core, minutes: 5)
        XCTAssertEqual(h.factory.runCount, 1, "pas de relance tant que l'utilisateur n'a pas validé")

        h.factory.status.set(.succeeded)
        try await core.approveDeletion(task.id)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2)
        let lastRun = h.factory.runners.get()[1].ranTasks.get()[0]
        XCTAssertEqual(lastRun.options.deleteThresholdPercent, 100)
        let after = await core.status().tasks[0].state
        XCTAssertEqual(after, .idle)
    }

    func testApproveRequiresAPendingApproval() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        do { try await core.approveDeletion(task.id); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .notAwaitingApproval)
        }
    }

    func testShutdownMarksRunsInterruptedAndTheyAreCaughtUpOnTheNextStart() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .daily(hour: 3, minute: 0))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.shutdown()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .interrupted)
        XCTAssertTrue(h.notifier.messages.get().isEmpty)

        let next = h.makeCore()
        await next.start()
        await next.tick()
        XCTAssertEqual(h.factory.created, 2, "l'exécution interrompue est rattrapée")
        h.factory.runners.get().forEach { $0.release() }
        await next.waitForIdle()
    }

    func testKilledAgentLeavesARunningRecordThatIsInterruptedAndCaughtUp() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask(schedule: .daily(hour: 3, minute: 0))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        // L'agent est tué net : aucun `shutdown`, l'enregistrement reste « en cours ».
        let restarted = h.makeCore()
        await restarted.start()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .interrupted)
        await restarted.tick()
        XCTAssertEqual(h.factory.created, 2)
        h.factory.runners.get().forEach { $0.release() }
        await restarted.waitForIdle()
        await core.waitForIdle()
    }

    func testUnreadableTasksFileKeepsThePreviousTasks() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        try h.save([makeTask("A", schedule: .manual)])
        let core = h.makeCore()
        await core.start()
        try h.save([makeTask("A", schedule: .manual), makeTask("B", schedule: .manual)])
        await core.reloadTasks()
        var status = await core.status()
        XCTAssertEqual(status.tasks.count, 2)
        try "{ cassé".write(to: h.taskStore.url, atomically: true, encoding: .utf8)
        await core.reloadTasks()
        status = await core.status()
        XCTAssertEqual(status.tasks.count, 2)
        XCTAssertNotNil(status.taskLoadError)
    }

    func testObserversReceiveStartAndFinishEvents() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        let events = Locked<[AgentEvent]>([])
        let token = await core.addObserver { events.set(events.get() + [$0]) }
        try await core.runNow(task.id)
        await core.waitForIdle()
        await core.removeObserver(token)
        let all = events.get()
        XCTAssertTrue(all.contains(.taskStarted(task.id)))
        XCTAssertTrue(all.contains { if case .taskFinished(task.id, .succeeded, _) = $0 { return true } else { return false } })
    }
}
