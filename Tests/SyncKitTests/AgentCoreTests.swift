import XCTest
@testable import SyncKit

/// Tout ce qu'il faut pour piloter un AgentCore dans le temps, sans processus ni attente réelle.
final class AgentHarness {
    let directory: URL
    let clock: FakeClock
    let conditions = FakeConditions()
    let notifier = FakeNotifier()
    let activity = FakeActivity()
    let factory: RunnerFactory
    let taskStore: TaskStore
    let stateStore: SchedulerStateStore
    let history: HistoryStore
    var configuration = AgentConfiguration()

    init(start: Date, gated: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        clock = FakeClock(start)
        factory = RunnerFactory(gated: gated)
        taskStore = TaskStore(url: directory.appendingPathComponent("tasks.json"))
        stateStore = SchedulerStateStore(url: directory.appendingPathComponent("scheduler-state.json"))
        history = try HistoryStore(path: directory.appendingPathComponent("history.sqlite").path)
        configuration.startupHold = 0
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        clock.calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    func save(_ tasks: [SyncTask]) throws { try taskStore.save(tasks) }

    func makeCore(runner: (@Sendable () -> TaskRunning)? = nil) -> AgentCore {
        let factory = self.factory
        return AgentCore(
            configuration: configuration, taskStore: taskStore, stateStore: stateStore, history: history,
            clock: clock, conditions: conditions, notifier: notifier, activity: activity,
            makeRunner: runner ?? { factory.make() }
        )
    }

    /// Avance minute par minute en évaluant à chaque pas, comme le minuteur de l'agent.
    func step(_ core: AgentCore, minutes: Int, wait: Bool = true) async {
        for _ in 0..<minutes {
            clock.advance(60)
            await core.tick()
            if wait { await core.waitForIdle() }
        }
    }
}

func makeTask(
    _ name: String = "tâche", schedule: Schedule = .everyMinutes(1), mode: SyncMode = .copy,
    notifications: NotificationPolicy = .always, conditions: TaskConditions = TaskConditions()
) -> SyncTask {
    SyncTask(
        name: name, source: .local(path: "/source"), destination: .local(path: "/dest"), mode: mode,
        schedule: schedule, notifications: notifications, conditions: conditions
    )
}

final class AgentSchedulingTests: XCTestCase {
    func testDailyTaskRunsAtItsTimeExactlyOnce() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 2, 0))
        let task = makeTask("nuit", schedule: .daily(hour: 3, minute: 0))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await h.step(core, minutes: 30)
        XCTAssertEqual(h.factory.runCount, 0)
        await h.step(core, minutes: 40)   // 03:10
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 30)
        XCTAssertEqual(h.factory.runCount, 1)
        XCTAssertEqual(try h.history.list(taskID: task.id).map(\.status), [.succeeded])
    }

    func testEveryMinutesRunsImmediatelyThenWaitsForTheInterval() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 9))
        try h.save([makeTask(schedule: .everyMinutes(10))])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 9)
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 1)
        XCTAssertEqual(h.factory.runCount, 2)
    }

    func testManualTaskNeverRunsByItself() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        try h.save([makeTask(schedule: .manual)])
        let core = h.makeCore()
        await core.start()
        await h.step(core, minutes: 120)
        XCTAssertEqual(h.factory.runCount, 0)
    }

    func testDisabledTaskDoesNotRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        var task = makeTask()
        task.isEnabled = false
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await h.step(core, minutes: 3)
        XCTAssertEqual(h.factory.runCount, 0)
        let state = await core.status().tasks.first?.state
        XCTAssertEqual(state, .disabled)
    }

    func testMissedRunsAfterSleepCatchUpOnlyOnceAfterTheWakeDelay() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 2, 0))
        try h.save([makeTask(schedule: .daily(hour: 3, minute: 0))])
        let core = h.makeCore()
        await core.start()
        await h.step(core, minutes: 70)            // 03:10, première exécution
        XCTAssertEqual(h.factory.runCount, 1)
        h.clock.set(h.at(2026, 10, 15, 9, 0))      // le Mac a dormi trois jours
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1, "attente de 60 s après le réveil")
        h.clock.advance(61)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2, "une seule exécution de rattrapage")
        await h.step(core, minutes: 5)
        XCTAssertEqual(h.factory.runCount, 2)
    }

    func testStartupHoldDelaysTheFirstEvaluation() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.configuration.startupHold = 60
        try h.save([makeTask(schedule: .everyMinutes(5))])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        h.clock.advance(61)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testUnmetConditionsMakeTheTaskWaitInsteadOfFailing() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.conditions.acPower.set(false)
        let task = makeTask(conditions: TaskConditions(requiresACPower: true))
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        let waiting = await core.status().tasks[0].state
        guard case .waiting = waiting else { return XCTFail("attendu : en attente, trouvé \(waiting)") }
        XCTAssertTrue(try h.history.list().isEmpty)
        h.conditions.acPower.set(true)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testHoursWindowBlocksOutsideTheRange() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 14, 0))
        try h.save([makeTask(conditions: TaskConditions(allowedHours: HourRange(start: 22, end: 6)))])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        h.clock.set(h.at(2026, 10, 12, 23, 0))   // un saut de 9 h ressemble à une veille : attente de 60 s
        await core.tick()
        h.clock.advance(61)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testUnreachableDestinationMakesTheTaskWait() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.conditions.reachable.set(false)
        try h.save([makeTask()])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        h.conditions.reachable.set(true)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    func testWhenAvailableRunsOnceEachTimeTheVolumeAppears() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.conditions.reachable.set(false)
        try h.save([makeTask(schedule: .whenAvailable)])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 0)
        h.conditions.reachable.set(true)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 3)
        XCTAssertEqual(h.factory.runCount, 1, "toujours branché : pas de nouvelle exécution")
        h.conditions.reachable.set(false)
        await core.tick()
        h.conditions.reachable.set(true)
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2)
    }
}

final class AgentConcurrencyTests: XCTestCase {
    func testAtMostTwoRunsInParallelAndTheThirdStartsWhenASlotFrees() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        try h.save([makeTask("A"), makeTask("B"), makeTask("C")])
        let core = h.makeCore()
        await core.start()
        await core.tick()
        var states = await core.status().tasks.map(\.state)
        XCTAssertEqual(states.filter { $0 == .running }.count, 2)
        XCTAssertEqual(states.filter { $0 == .queued }.count, 1)
        XCTAssertEqual(h.activity.begins.get(), 1)

        h.factory.runners.get()[0].release()
        let started = await eventually { h.factory.runners.get().count == 3 }
        XCTAssertTrue(started, "la troisième tâche démarre quand une place se libère")
        states = await core.status().tasks.map(\.state)
        XCTAssertEqual(states.filter { $0 == .queued }.count, 0)

        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        XCTAssertEqual(h.activity.begins.get(), 1)
        XCTAssertEqual(h.activity.ends.get(), 1, "l'anti-veille est relâché quand la file est vide")
    }

    func testATaskNeverRunsTwiceAtTheSameTime() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        try h.save([makeTask(schedule: .everyMinutes(1))])
        let core = h.makeCore()
        await core.start()
        await core.tick()
        await h.step(core, minutes: 3, wait: false)
        XCTAssertEqual(h.factory.created, 1)
        h.factory.runners.get()[0].release()
        await core.waitForIdle()
    }
}

final class AgentFailureTests: XCTestCase {
    func testFailuresRetryAfterAnHourThreeTimesThenFollowTheNormalSchedule() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.status.set(.failed)
        try h.save([makeTask(schedule: .everyMinutes(1))])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        await h.step(core, minutes: 30)
        XCTAssertEqual(h.factory.runCount, 1, "la nouvelle tentative attend une heure")
        await h.step(core, minutes: 30)
        XCTAssertEqual(h.factory.runCount, 2)
        await h.step(core, minutes: 60)
        XCTAssertEqual(h.factory.runCount, 3)
        XCTAssertEqual(h.notifier.messages.get().count, 3)
        await h.step(core, minutes: 1)
        XCTAssertEqual(h.factory.runCount, 4, "après trois essais : retour à l'échéance normale")
    }

    func testNotificationPolicyErrorsOnlyStaysSilentOnSuccess() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        try h.save([makeTask(notifications: .errorsOnly)])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        XCTAssertTrue(h.notifier.messages.get().isEmpty)
    }

    func testRunnerThatThrowsIsRecordedAsFailed() async throws {
        struct Boom: Error {}
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.failure.set(Boom())
        let task = makeTask()
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        await core.tick(); await core.waitForIdle()
        let record = try XCTUnwrap(try h.history.list(taskID: task.id).first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.summary?.message?.contains("Boom") == true)
    }

    func testHistoryOlderThanRetentionIsPurged() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.clock.set(h.at(2026, 10, 12, 9))
        try h.save([makeTask(schedule: .manual)])
        let old = RunRecord(
            taskID: UUID(), taskName: "vieille", engine: .rsync, mode: .copy,
            startedAt: h.clock.now().addingTimeInterval(-100 * 86400),
            finishedAt: h.clock.now().addingTimeInterval(-100 * 86400), status: .succeeded
        )
        try h.history.save(old)
        let core = h.makeCore()
        await core.start()
        await core.tick()
        XCTAssertNil(try h.history.record(id: old.id))
    }
}
