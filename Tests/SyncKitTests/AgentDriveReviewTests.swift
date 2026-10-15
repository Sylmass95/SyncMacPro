import XCTest
@testable import SyncKit

/// Relecture finale de la 1.4.0 : disque amovible.
final class AgentDriveReviewTests: XCTestCase {
    let uuid = "AAAA-1111"

    func backup(_ name: String = "Sauvegarde", eject: RemovableDrive.Eject = .never) -> SyncTask {
        var task = SyncTask(name: name, source: .local(path: "/source"), destination: .local(path: "/Volumes/Extreme Pro/Sauvegardes"),
                            schedule: .manual)
        task.removableDrive = RemovableDrive(volumeUUID: uuid, volumeName: "Extreme Pro", relativePath: "Sauvegardes",
                                             trigger: .everyConnection, resumeWindowDays: 3, eject: eject)
        return task
    }

    func plugged(_ h: AgentHarness, _ drives: FakeDriveMonitor, _ core: AgentCore, at path: String = "/Volumes/Extreme Pro") async {
        drives.plug(uuid, at: path)
        await core.drivesChanged()
        h.clock.advance(6)
        await core.drivesChanged()
        await core.tick()
    }

    // Critique 1 : la file ne lance jamais une tâche liée sans son disque (un autre disque du même nom serait écrit).
    func testQueueRefusesALinkedTaskWithoutItsDrive() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        let task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        do { try await core.enqueue(task.id); XCTFail("disque absent") } catch {
            XCTAssertEqual(error as? AgentError, .driveNotConnected("Extreme Pro"))
        }
    }

    func testQueuedLinkedTaskWhoseDriveLeftIsSkipped() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        var task = backup()
        task.removableDrive?.trigger = .atMostEveryDays(30)
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.plug(uuid, at: "/Volumes/Extreme Pro")
        await core.drivesChanged()
        try await core.enqueue(task.id)       // branché : accepté (le départ au branchement attend 5 s)
        drives.unplug(uuid)
        await core.drivesChanged()
        drives.plug("BBBB-2222", at: "/Volumes/Extreme Pro")   // un autre disque du même nom
        await core.drivesChanged()
        await core.setQueueRunning(true)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.created, 0, "rien n'est écrit sur l'autre disque")
        let items = await core.queueInfo.items
        XCTAssertTrue(items.isEmpty)
    }

    // Important 2 : « Lancer » consomme le branchement (pas de deuxième sauvegarde au passage suivant).
    func testManualRunConsumesTheConnection() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        let task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.plug(uuid, at: "/Volumes/Extreme Pro")
        await core.drivesChanged()
        try await core.runNow(task.id)     // avant la fin des 5 s
        await core.waitForIdle()
        h.clock.advance(10)
        await core.drivesChanged()
        await core.tick()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    // Important 2 : « Lancer » pendant une suspension reprend l'exécution suspendue (même ligne d'historique).
    func testManualRunResumesTheSuspendedRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        var task = backup()
        task.removableDrive?.trigger = .atMostEveryDays(30)
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        drives.unplug(uuid); await core.drivesChanged(); await core.waitForIdle()
        let suspendedID = try XCTUnwrap(h.history.list(limit: 1).first?.id)
        h.clock.advance(3_600)
        drives.plug(uuid, at: "/Volumes/Extreme Pro")
        await core.drivesChanged()
        try await core.runNow(task.id)
        h.factory.runners.get()[1].release()
        await core.waitForIdle()
        h.clock.advance(10)
        await core.drivesChanged(); await core.tick(); await core.waitForIdle()
        let records = try h.history.list(limit: 5)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, suspendedID)
        XCTAssertEqual(records[0].status, .succeeded)
        XCTAssertEqual(h.factory.created, 2)
        let info = await core.status().tasks[0]
        XCTAssertNil(info.driveSuspendedSince)
    }

    // Important 3 : le branchement respecte la limite de deux exécutions simultanées.
    func testPlugRespectsTheParallelLimit() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        let a = SyncTask(name: "A", source: .local(path: "/a"), destination: .local(path: "/b"), schedule: .manual)
        let b = SyncTask(name: "B", source: .local(path: "/c"), destination: .local(path: "/d"), schedule: .manual)
        let task = backup()
        try h.save([a, b, task])
        let core = h.makeCore(drives: drives)
        await core.start()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        await plugged(h, drives, core)
        XCTAssertEqual(h.factory.created, 2, "pas de troisième exécution")
        h.factory.runners.get()[0].release()
        let started = await eventually { h.factory.created == 3 }
        XCTAssertTrue(started, "la sauvegarde part quand une place se libère")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    // Important 4 : disque arraché, l'erreur du moteur arrive avant que le volume disparaisse de la liste.
    func testFailureJustBeforeTheVolumeVanishesSuspends() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        h.configuration.driveFailureRecheck = 0.5
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        let runner = h.factory.runners.get()[0]
        runner.status.set(.failed)
        runner.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        drives.volumes.set([:])       // l'avis de démontage arrive après l'erreur
        await core.waitForIdle()
        let info = await core.status().tasks[0]
        XCTAssertNotNil(info.driveSuspendedSince)
        XCTAssertTrue(h.notifier.messages.get().allSatisfy { !$0.title.contains("échec") })
    }

    func testFailureWithTheDriveStillThereIsAFailure() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        h.configuration.driveFailureRecheck = 0.05
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        let runner = h.factory.runners.get()[0]
        runner.status.set(.failed)
        runner.release()
        await core.waitForIdle()
        let info = await core.status().tasks[0]
        XCTAssertNil(info.driveSuspendedSince)
        XCTAssertEqual(try h.history.list(limit: 1).first?.status, .failed)
    }

    // Important 6 (relevé de Minor) : le minuteur relit les disques si un avis de DiskArbitration a été manqué.
    func testTickNoticesAMissedMount() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.volumes.set([uuid: "/Volumes/Extreme Pro"])   // aucun rappel
        await core.tick()
        h.clock.advance(15)
        await core.tick()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
    }

    // Important 7 (relevé de Minor) : la suspension est annoncée comme une fin d'exécution (historique, ctl watch).
    func testSuspensionIsAnnouncedAsAFinishedRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        let task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        let events = Locked<[AgentEvent]>([])
        _ = await core.addObserver { event in events.update { $0.append(event) } }
        drives.unplug(uuid); await core.drivesChanged(); await core.waitForIdle()
        XCTAssertTrue(events.get().contains { if case .taskFinished(task.id, .interrupted, _) = $0 { return true }; return false })
    }
}
