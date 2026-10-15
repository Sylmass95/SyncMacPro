import XCTest
@testable import SyncKit

/// Sauvegarde sur disque amovible (1.4.0), avec un faux disque et une fausse horloge.
final class AgentDriveTests: XCTestCase {
    let uuid = "AAAA-1111"

    func backup(_ trigger: RemovableDrive.Trigger = .everyConnection, eject: RemovableDrive.Eject = .never) -> SyncTask {
        var task = SyncTask(name: "Sauvegarde", source: .local(path: "/source"), destination: .local(path: "/Volumes/Extreme Pro/Sauvegardes"),
                            schedule: .whenAvailable)
        task.removableDrive = RemovableDrive(volumeUUID: uuid, volumeName: "Extreme Pro", relativePath: "Sauvegardes",
                                             trigger: trigger, resumeWindowDays: 3, eject: eject)
        return task
    }

    func plugged(_ h: AgentHarness, _ drives: FakeDriveMonitor, _ core: AgentCore, at path: String = "/Volumes/Extreme Pro") async {
        drives.plug(uuid, at: path)
        await core.drivesChanged()
        h.clock.advance(6)
        await core.drivesChanged()   // l'agent relit les disques 6 s après un branchement (même au sortir de veille)
        await core.tick()
    }

    func testPluggingTheDriveStartsTheBackupAfterFiveSeconds() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.plug(uuid, at: "/Volumes/Extreme Pro")
        await core.drivesChanged()
        XCTAssertEqual(h.factory.created, 0, "attente de 5 s : le disque se prépare")
        h.clock.advance(6)
        await core.tick()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        XCTAssertEqual(h.factory.runners.get()[0].ranTasks.get()[0].destination, .local(path: "/Volumes/Extreme Pro/Sauvegardes"))
    }

    func testUnpluggedBeforeFiveSecondsStartsNothing() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.plug(uuid, at: "/Volumes/Extreme Pro")
        await core.drivesChanged()
        h.clock.advance(2)
        drives.unplug(uuid)
        await core.drivesChanged()
        h.clock.advance(10)
        await core.tick()
        XCTAssertEqual(h.factory.created, 0)
    }

    func testEveryConnectionRunsOncePerConnection() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        await core.waitForIdle()
        h.clock.advance(120)
        await core.tick()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1, "toujours branché : pas de deuxième sauvegarde")
        drives.unplug(uuid)
        await core.drivesChanged()
        await plugged(h, drives, core)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2, "rebranché : une nouvelle")
    }

    func testAtMostEveryNDaysSkipsARecentBackup() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        try h.save([backup(.atMostEveryDays(7))])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        await core.waitForIdle()
        drives.unplug(uuid); await core.drivesChanged()
        h.clock.advance(2 * 86_400)
        await plugged(h, drives, core)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1, "sauvegarde de moins de 7 jours : rien")
        drives.unplug(uuid); await core.drivesChanged()
        h.clock.advance(6 * 86_400)
        await plugged(h, drives, core)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2)
    }

    func testUnpluggingSuspendsInsteadOfFailing() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        let task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        drives.unplug(uuid)
        await core.drivesChanged()     // le moteur est arrêté
        await core.waitForIdle()
        let info = await core.status().tasks[0]
        XCTAssertNotNil(info.driveSuspendedSince)
        guard case .waiting(let reason) = info.state else { return XCTFail("\(info.state)") }
        XCTAssertTrue(reason.contains("débranché"), reason)
        XCTAssertNil(info.nextDue, "pas de nouvel essai")
        XCTAssertEqual(try h.history.list(limit: 5).first?.status, .interrupted)
    }

    func testEngineFailureWithTheVolumeGoneSuspends() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        drives.volumes.set([:])        // arraché : l'erreur d'entrée/sortie arrive avant l'avis de démontage
        let runner = h.factory.runners.get()[0]
        runner.status.set(.failed)
        runner.release()
        await core.waitForIdle()
        let info = await core.status().tasks[0]
        XCTAssertNotNil(info.driveSuspendedSince)
        XCTAssertNil(info.nextDue)
    }

    func testReplugWithinTheWindowContinuesTheSameRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        drives.unplug(uuid); await core.drivesChanged(); await core.waitForIdle()
        let firstID = try XCTUnwrap(h.history.list(limit: 5).first?.id)
        h.clock.advance(86_400)
        await plugged(h, drives, core, at: "/Volumes/Extreme Pro 1")
        h.factory.runners.get()[1].release()
        await core.waitForIdle()
        let records = try h.history.list(limit: 5)
        XCTAssertEqual(records.count, 1, "même exécution")
        XCTAssertEqual(records[0].id, firstID)
        XCTAssertEqual(records[0].status, .succeeded)
        XCTAssertEqual(records[0].summary?.filesTransferred, 2, "bilans additionnés")
        XCTAssertEqual(h.factory.runners.get()[1].ranTasks.get()[0].destination, .local(path: "/Volumes/Extreme Pro 1/Sauvegardes"),
                       "monté ailleurs : retrouvé")
    }

    func testReplugAfterTheWindowStartsANewRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        drives.unplug(uuid); await core.drivesChanged(); await core.waitForIdle()
        h.clock.advance(5 * 86_400)
        await plugged(h, drives, core)
        h.factory.runners.get()[1].release()
        await core.waitForIdle()
        let records = try h.history.list(limit: 5)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.last?.status, .interrupted)
        XCTAssertEqual(records.first?.status, .succeeded)
    }

    func testSuspensionSurvivesAnAgentRestart() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        drives.unplug(uuid); await core.drivesChanged(); await core.waitForIdle()
        let again = h.makeCore(drives: drives)
        await again.start()
        await again.drivesChanged()
        let info = await again.status().tasks[0]
        XCTAssertNotNil(info.driveSuspendedSince)
        XCTAssertEqual(h.factory.created, 1, "pas de rattrapage sans disque")
    }

    func testAnotherDiskWithTheSameNameIsIgnored() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.plug("BBBB-2222", at: "/Volumes/Extreme Pro")
        await core.drivesChanged()
        h.clock.advance(6)
        await core.tick()
        XCTAssertEqual(h.factory.created, 0)
    }

    func testManualRunWithoutTheDriveIsRefused() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        let task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        do { try await core.runNow(task.id); XCTFail("disque absent") } catch {
            XCTAssertEqual(error as? AgentError, .driveNotConnected("Extreme Pro"))
        }
    }

    func testAbandonClosesTheSuspendedRun() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        let task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        drives.unplug(uuid); await core.drivesChanged(); await core.waitForIdle()
        try await core.abandonSuspended(task.id)
        let info = await core.status().tasks[0]
        XCTAssertNil(info.driveSuspendedSince)
        XCTAssertEqual(try h.history.list(limit: 1).first?.summary?.message, "Abandonnée : disque débranché.")
    }
}
