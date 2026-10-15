import XCTest
@testable import SyncKit

/// Petits défauts de la 1.4.0 (disque amovible), corrigés en 1.5.0.
final class AgentDrive150Tests: XCTestCase {
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

    func suspended(_ h: AgentHarness, _ drives: FakeDriveMonitor, _ core: AgentCore) async {
        await plugged(h, drives, core)
        drives.unplug(uuid); await core.drivesChanged(); await core.waitForIdle()
    }

    // 1. La simulation compare avec le dossier du disque, là où il est monté ; sans lui, elle est refusée.
    func testSimulationFollowsTheDrive() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        let task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        do { _ = try await core.simulate(task); XCTFail("disque absent") } catch {
            XCTAssertEqual(error as? AgentError, .driveNotConnected("Extreme Pro"))
        }
        drives.plug(uuid, at: "/Volumes/Extreme Pro 1")
        await core.drivesChanged()
        _ = try await core.simulate(task)
        let ran = try XCTUnwrap(h.factory.runners.get().last?.ranTasks.get().last)
        XCTAssertEqual(ran.destination, .local(path: "/Volumes/Extreme Pro 1/Sauvegardes"))
    }

    // 2. Supprimer ou délier une tâche clôt sa sauvegarde en pause.
    func testDeletingATaskClosesItsSuspension() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        let task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        await suspended(h, drives, core)
        try await core.removeTask(task.id)
        let record = try XCTUnwrap(h.history.list(limit: 1).first)
        XCTAssertEqual(record.summary?.message, "Interrompue : tâche supprimée.")
    }

    func testUnlinkingATaskClosesItsSuspension() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        var task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        await suspended(h, drives, core)
        task.removableDrive = nil
        try await core.saveTask(task)
        let info = await core.status().tasks[0]
        XCTAssertNil(info.driveSuspendedSince)
        XCTAssertEqual(info.state, .idle)
        XCTAssertEqual(try h.history.list(limit: 1).first?.summary?.message, "Interrompue : la tâche n'est plus liée au disque.")
    }

    func testRenamingALinkedTaskKeepsItsSuspension() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        var task = backup()
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        await suspended(h, drives, core)
        task.name = "Photos"
        try await core.saveTask(task)
        let info = await core.status().tasks[0]
        XCTAssertNotNil(info.driveSuspendedSince)
    }

    // 3. Disque rebranché mais reprise en attente d'une condition : la cause est affichée, pas « débranché ».
    func testPluggedSuspensionWaitingForPowerShowsTheCondition() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        var task = backup()
        task.conditions.requiresACPower = true
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        await suspended(h, drives, core)
        h.conditions.acPower.set(false)
        await plugged(h, drives, core)
        let info = await core.status().tasks[0]
        guard case .waiting(let reason) = info.state else { return XCTFail("\(info.state)") }
        XCTAssertTrue(reason.contains("secteur"), reason)
        XCTAssertNotNil(info.driveSuspendedSince)
        drives.unplug(uuid); await core.drivesChanged()
        let after = await core.status().tasks[0]
        guard case .waiting(let again) = after.state else { return XCTFail("\(after.state)") }
        XCTAssertTrue(again.contains("débranché"), "la cause périmée est oubliée : \(again)")
    }

    // 4. Une seule éjection à la fois, et aucune exécution ne part sur un disque en cours d'éjection.
    func testConcurrentEjectIsRefusedAndNothingStartsMeanwhile() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let drives = FakeDriveMonitor()
        var task = backup(eject: .button)
        task.removableDrive?.trigger = .atMostEveryDays(30)
        try h.save([task])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        await core.waitForIdle()
        drives.ejectDelay.set(400_000_000)
        let first = Task { try await core.ejectDrive(task.id) }
        try await Task.sleep(nanoseconds: 100_000_000)
        do { try await core.ejectDrive(task.id); XCTFail("éjection déjà en cours") } catch {
            XCTAssertEqual(error as? AgentError, .ejectRefused("Une éjection de ce disque est déjà en cours."))
        }
        do { try await core.runNow(task.id); XCTFail("disque en cours d'éjection") } catch {
            XCTAssertEqual(error as? AgentError, .ejectRefused("Le disque est en cours d'éjection."))
        }
        try await first.value
        XCTAssertEqual(drives.ejected.get(), ["/Volumes/Extreme Pro"])
        XCTAssertEqual(h.factory.created, 1)
    }

    // 5. Redémarrage pendant une sauvegarde liée : pas de nouvel essai programmé, et la file n'attend pas.
    func testRestartDuringALinkedRunLeavesNoRetryAndFreesTheQueue() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        var task = backup()
        task.removableDrive?.trigger = .atMostEveryDays(30)
        let other = SyncTask(name: "Autre", source: .local(path: "/a"), destination: .local(path: "/b"), schedule: .manual)
        try h.save([task, other])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.plug(uuid, at: "/Volumes/Extreme Pro")
        await core.drivesChanged()
        try await core.enqueue(task.id)
        try await core.enqueue(other.id)
        await core.setQueueRunning(true)
        XCTAssertEqual(h.factory.created, 1)
        let again = h.makeCore(drives: drives)   // l'agent est tué en route
        await again.start()
        let started = await eventually { h.factory.created == 2 }
        XCTAssertTrue(started, "la file passe à l'élément suivant")
        var unlinked = task
        unlinked.removableDrive = nil
        try await again.saveTask(unlinked)
        let info = await again.status().tasks.first { $0.id == task.id }
        XCTAssertNil(info?.nextDue, "pas de nouvel essai fantôme")
        h.factory.runners.get().forEach { $0.release() }
        await again.waitForIdle()
    }

    // 6. Un redémarrage de l'agent n'est pas un branchement : un disque resté branché n'est pas sauvegardé de nouveau.
    func testAgentRestartIsNotANewConnection() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 1_000))
        let drives = FakeDriveMonitor()
        drives.mountDates.set(["/Volumes/Extreme Pro": Date(timeIntervalSince1970: 990)])
        try h.save([backup()])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plugged(h, drives, core)
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1)
        h.clock.advance(3_600)
        let again = h.makeCore(drives: drives)
        await again.start()
        await again.drivesChanged()
        h.clock.advance(10)
        await again.drivesChanged(); await again.tick(); await again.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 1, "même branchement")
        drives.unplug(uuid); await again.drivesChanged()
        drives.mountDates.set(["/Volumes/Extreme Pro": h.clock.now()])
        await plugged(h, drives, again)
        await again.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2, "vrai rebranchement")
    }

    // 7. Vitesse moyenne d'une exécution reprise : sur le temps actif des deux parties.
    func testCombinedAverageSpeedExcludesPauses() {
        let first = RunSummary(filesTransferred: 1, bytesTransferred: 100, durationSeconds: 100, averageSpeed: 10)
        let second = RunSummary(filesTransferred: 1, bytesTransferred: 100, durationSeconds: 10, averageSpeed: 10)
        XCTAssertEqual(AgentCore.combine(first, second).averageSpeed ?? 0, 10, accuracy: 0.001)
    }

    // 8. « Abandonner » sans sauvegarde en pause : message exact.
    func testAbandonWithoutSuspensionSaysSo() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = backup()
        try h.save([task])
        let core = h.makeCore(drives: FakeDriveMonitor())
        await core.start()
        do { try await core.abandonSuspended(task.id); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .invalidTask("Aucune sauvegarde en pause pour cette tâche."))
        }
    }
}
