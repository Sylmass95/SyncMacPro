import XCTest
@testable import SyncKit

/// Revue finale de la 1.7.0 : une sauvegarde de disque amovible qui attend une place ne doit jamais être perdue.
final class Review170DriveTests: XCTestCase {
    let uuid = "AAAA-1111"

    func backup(_ name: String = "D") -> SyncTask {
        var t = SyncTask(name: name, source: .local(path: "/source/\(name)"), destination: .local(path: "/Volumes/X/\(name)"), schedule: .manual)
        t.removableDrive = RemovableDrive(volumeUUID: uuid, volumeName: "X", relativePath: name, trigger: .everyConnection,
                                          resumeWindowDays: 3, eject: .never)
        return t
    }
    func other(_ name: String) -> SyncTask { SyncTask(name: name, source: .local(path: "/\(name)"), destination: .local(path: "/\(name)2")) }

    func release(_ h: AgentHarness, _ core: AgentCore) async {
        let factory = h.factory
        let releaser = Task { while !Task.isCancelled { factory.runners.get().forEach { $0.release() }; try? await Task.sleep(nanoseconds: 5_000_000) } }
        await core.waitForIdle()
        releaser.cancel()
    }

    func plug(_ h: AgentHarness, _ drives: FakeDriveMonitor, _ core: AgentCore) async {
        drives.plug(uuid, at: "/Volumes/X")
        await core.drivesChanged()
        h.clock.advance(6)
        await core.drivesChanged()
        await core.tick()
    }

    func ran(_ h: AgentHarness, _ name: String) -> Bool { h.factory.runners.get().contains { $0.ranTasks.get().first?.name == name } }

    func testAWaitingDriveBackupSurvivesAnAgentRestart() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        try h.save([other("A"), other("B"), backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        for name in ["A", "B"] { try await core.runNow(h.taskStore.load().first { $0.name == name }!.id) }
        await plug(h, drives, core)
        XCTAssertFalse(ran(h, "D"), "attend une place")
        await core.shutdown()
        let again = h.makeCore(drives: drives)
        await again.start()
        await again.drivesChanged()
        h.clock.advance(60)   // le minuteur de l'agent
        await again.drivesChanged()
        await again.tick()
        await release(h, again)
        await again.tick()
        await release(h, again)
        XCTAssertTrue(ran(h, "D"), "la sauvegarde du branchement n'est pas perdue")
    }

    func testAWaitingDriveBackupDroppedByAConditionComesBack() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        var d = backup()
        d.conditions.requiresACPower = true
        try h.save([other("A"), other("B"), d])
        let core = h.makeCore(drives: drives)
        await core.start()
        for name in ["A", "B"] { try await core.runNow(h.taskStore.load().first { $0.name == name }!.id) }
        await plug(h, drives, core)
        h.conditions.acPower.set(false)
        await release(h, core)   // les places se libèrent : D est revérifiée et écartée (pas sur secteur)
        XCTAssertFalse(ran(h, "D"))
        h.conditions.acPower.set(true)
        h.clock.advance(60)
        await core.tick()
        await release(h, core)
        XCTAssertTrue(ran(h, "D"), "repart sans rebrancher le disque")
    }

    func testStoppingAWaitingResumeKeepsTheSuspendedRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        let d = backup()
        try h.save([other("A"), other("B"), d])
        var state = SchedulerState()
        var entry = TaskScheduleState(firstSeen: Date(timeIntervalSince1970: 0))
        entry.suspendedRun = SuspendedRun(recordID: UUID(), since: Date(timeIntervalSince1970: 0), summary: RunSummary())
        state.tasks[d.id.uuidString] = entry
        try h.stateStore.save(state)
        let core = h.makeCore(drives: drives)
        await core.start()
        for name in ["A", "B"] { try await core.runNow(h.taskStore.load().first { $0.name == name }!.id) }
        await plug(h, drives, core)
        let waiting = await core.status().tasks.first { $0.id == d.id }
        XCTAssertEqual(waiting?.state, .queued)
        XCTAssertNotNil(waiting?.driveSuspendedSince, "la sauvegarde en pause reste visible pendant l'attente")
        try await core.stop(d.id)
        let after = await core.status().tasks.first { $0.id == d.id }
        XCTAssertNotNil(after?.driveSuspendedSince, "« Arrêter » l'attente ne perd pas la sauvegarde en pause")
        await release(h, core)
    }
}

final class Review170CtlTests: XCTestCase {
    /// « queue remove » retire de l'attente ; il n'arrête jamais une copie en cours.
    func testQueueRemoveOnlyLeavesTheWait() {
        let id = UUID()
        XCTAssertEqual(CtlFormatter.request(for: .queueRemove("x"), id: id), .dequeue(id))
        XCTAssertEqual(CtlFormatter.request(for: .queueAdd("x"), id: id), .runNow(id))
        XCTAssertEqual(CtlFormatter.request(for: .force("x"), id: id), .force(id))
    }
}
