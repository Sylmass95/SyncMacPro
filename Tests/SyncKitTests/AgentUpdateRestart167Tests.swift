import XCTest
@testable import SyncKit

/// 1.6.7 : une mise à jour remplace l'app (et l'agent) sur le disque pendant qu'une copie tourne ; l'ancien agent n'est
/// plus reconnu par macOS (autorisations refusées) et toutes ses nouvelles copies échouaient pendant des heures (essai
/// réel du 17/10). Dès que son programme a été remplacé, l'agent ne lance plus rien : les copies en cours finissent,
/// puis l'app le réenregistre.
final class AgentUpdateRestart167Tests: XCTestCase {
    let identity = Locked<String?>("v1")

    func harness(gated: Bool = false) throws -> AgentHarness {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: gated)
        let identity = self.identity
        h.configuration.executableIdentity = { identity.get() }
        h.configuration.openApp = {}   // jamais la vraie app pendant les tests
        return h
    }

    func task(_ name: String, schedule: Schedule = .manual) -> SyncTask {
        SyncTask(name: name, source: .local(path: "/s/\(name)"), destination: .local(path: "/d/\(name)"), schedule: schedule)
    }

    func testOnceTheProgramIsReplacedNoScheduledRunStarts() async throws {
        let h = try harness()
        let due = task("Nuit", schedule: .everyMinutes(60))
        try h.save([due])
        let core = h.makeCore()
        await core.start()
        identity.set("v2")
        await core.tick()
        XCTAssertEqual(h.factory.created, 0)
        let status = await core.status()
        XCTAssertEqual(status.restartPending, true)
        guard case .waiting(let reason) = status.tasks.first?.state else { return XCTFail("en attente attendu") }
        XCTAssertTrue(reason.contains("mise à jour"), reason)
        XCTAssertEqual(h.notifier.messages.get().count, 1, "prévenu une fois")
        await core.tick()
        XCTAssertEqual(h.notifier.messages.get().count, 1)
    }

    func testRunningCopiesFinishButNothingNewStarts() async throws {
        let h = try harness(gated: true)
        let a = task("A"), b = task("B")
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        XCTAssertEqual(h.factory.created, 1)
        identity.set("v2")
        await core.tick()
        try await core.runNow(b.id)
        XCTAssertEqual(h.factory.created, 1, "B attend le redémarrage")
        let bState = await core.status().tasks.first { $0.id == b.id }?.state
        guard case .waiting = bState else { return XCTFail("B en attente (et non en file) : \(String(describing: bState))") }
        h.factory.runners.get()[0].release()
        await core.waitForIdle()
        await core.tick()
        XCTAssertEqual(h.factory.created, 1)
        XCTAssertEqual(try h.history.list(taskID: a.id).map(\.status), [.succeeded], "la copie en cours a fini normalement")
    }

    func testARunAskedDuringTheWaitStartsAfterTheRestart() async throws {
        let h = try harness()
        let b = task("B")
        try h.save([b])
        let core = h.makeCore()
        await core.start()
        identity.set("v2")
        await core.tick()
        try await core.runNow(b.id)
        XCTAssertEqual(h.factory.created, 0)
        // Redémarrage : nouvel agent, nouveau programme.
        let restarted = h.makeCore()
        await restarted.start()
        await restarted.tick()
        await restarted.waitForIdle()
        XCTAssertEqual(h.factory.created, 1, "la demande n'est pas perdue")
    }

    func testTheUserQueueWaitsForTheRestart() async throws {
        let h = try harness()
        let a = task("A")
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        identity.set("v2")
        await core.tick()
        try await core.enqueue(a.id)
        await core.setQueueRunning(true)
        XCTAssertEqual(h.factory.created, 0)
        let items = await core.status().queue?.items.count
        XCTAssertEqual(items, 1, "l'élément reste dans la file")
    }

    func testAPluggedDriveWaitsForTheRestart() async throws {
        let h = try harness()
        var backup = SyncTask(name: "D", source: .local(path: "/s"), destination: .local(path: "/Volumes/X/D"), schedule: .manual)
        backup.removableDrive = RemovableDrive(volumeUUID: "U", volumeName: "X", relativePath: "D", trigger: .everyConnection,
                                               resumeWindowDays: 3, eject: .never)
        try h.save([backup])
        let drives = FakeDriveMonitor()
        let core = h.makeCore(drives: drives)
        await core.start()
        identity.set("v2")
        await core.tick()
        drives.plug("U", at: "/Volumes/X")
        await core.drivesChanged()
        h.clock.advance(6)
        await core.drivesChanged()
        await core.tick()
        XCTAssertEqual(h.factory.created, 0)
        let restarted = h.makeCore(drives: drives)
        identity.set("v2")
        await restarted.start()
        await restarted.drivesChanged()
        h.clock.advance(6)
        await restarted.drivesChanged()
        await restarted.tick()
        await restarted.waitForIdle()
        XCTAssertEqual(h.factory.created, 1, "le branchement est servi après le redémarrage")
    }

    func testAnUnreadableProgramIsNotTakenForAnUpdate() async throws {
        let h = try harness()
        try h.save([task("Nuit", schedule: .everyMinutes(60))])
        let core = h.makeCore()
        await core.start()
        identity.set(nil)   // remplacement en cours : le fichier manque un instant
        await core.tick()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.created, 1)
        let pending = await core.status().restartPending
        XCTAssertNotEqual(pending, true)
    }

    /// Revue : l'agent en attente et au repos ouvre l'app (en arrière-plan) pour qu'elle le redémarre, une fois.
    func testAnIdleWaitingAgentOpensTheAppOnce() async throws {
        let h = try harness(gated: true)
        let opened = Locked(0)
        h.configuration.openApp = { opened.update { $0 += 1 } }
        let a = task("A")
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        identity.set("v2")
        await core.tick()
        XCTAssertEqual(opened.get(), 0, "une copie tourne encore")
        h.factory.runners.get()[0].release()
        await core.waitForIdle()
        await core.tick()
        await core.tick()
        XCTAssertEqual(opened.get(), 1)
    }

    /// Revue : remplacement vu tout de suite (pas au prochain passage du minuteur) quand on lance une tâche.
    func testARunAskedRightAfterTheReplacementDoesNotStartWithTheOldProgram() async throws {
        let h = try harness()
        let b = task("B")
        try h.save([b])
        let core = h.makeCore()
        await core.start()
        identity.set("v2")
        try await core.runNow(b.id)
        XCTAssertEqual(h.factory.created, 0)
    }

    /// Revue : demandes qui ne survivraient pas au redémarrage (copie ponctuelle, validation d'une suppression,
    /// simulation) : refusées avec un message clair.
    func testRequestsThatWouldBeLostAreRefusedWhileWaiting() async throws {
        let h = try harness()
        let b = task("B")
        try h.save([b])
        let core = h.makeCore()
        await core.start()
        identity.set("v2")
        await core.tick()
        do { try await core.runOnce(task("Ponctuelle")); XCTFail("refus attendu") } catch {
            XCTAssertTrue("\((error as? LocalizedError)?.errorDescription ?? "")".contains("redémarrage"), "\(error)")
        }
        do { _ = try await core.simulate(b); XCTFail("refus attendu") } catch {}
    }

    /// 1.6.9 : seule une copie en pause reste : l'agent ouvre l'app (le redémarrage peut se faire).
    func testOnlyAPausedCopyLeftStillOpensTheApp() async throws {
        let h = try harness(gated: true)
        let opened = Locked(0)
        h.configuration.openApp = { opened.update { $0 += 1 } }
        let a = task("A")
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.pause(a.id)
        identity.set("v2")
        await core.tick()
        XCTAssertEqual(opened.get(), 1)
    }

    /// 1.6.9 : la copie en pause coupée par le redémarrage est reprise par l'agent suivant.
    func testAPausedCopyCutByTheRestartIsTakenUpAgain() async throws {
        let h = try harness(gated: true)
        let a = task("A")
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.pause(a.id)
        await core.shutdown()
        XCTAssertEqual(try h.history.list(taskID: a.id).map(\.status), [.interrupted])
        identity.set("v2")
        let restarted = h.makeCore()
        await restarted.start()
        await restarted.tick()
        XCTAssertEqual(h.factory.created, 2, "reprise après le redémarrage")
        h.factory.runners.get()[1].release()
        await restarted.waitForIdle()
    }
}
