import XCTest
@testable import SyncKit

/// 1.7.4 : après une mise à jour, l'agent redémarre tout de suite, copies en cours comprises ; elles reprennent juste
/// après — y compris celles d'un disque amovible (avant, elles attendaient un nouveau branchement).
final class Restart174Tests: XCTestCase {
    let uuid = "AAAA-1111"

    func backup(trigger: RemovableDrive.Trigger = .atMostEveryDays(30)) -> SyncTask {
        var t = SyncTask(name: "D", source: .local(path: "/source/D"), destination: .local(path: "/Volumes/X/D"), schedule: .manual)
        t.removableDrive = RemovableDrive(volumeUUID: uuid, volumeName: "X", relativePath: "D", trigger: trigger, resumeWindowDays: 3, eject: .never)
        return t
    }

    func settle(_ h: AgentHarness, _ core: AgentCore) async {
        await core.drivesChanged()
        h.clock.advance(60)
        await core.drivesChanged()
        await core.tick()
    }

    func ranCount(_ h: AgentHarness) -> Int { h.factory.runners.get().filter { !$0.ranTasks.get().isEmpty }.count }

    func testADriveCopyCutByAnAgentRestartStartsAgain() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        let d = backup()
        try h.save([d])
        drives.plug(uuid, at: "/Volumes/X")
        let core = h.makeCore(drives: drives)
        await core.start()
        await core.drivesChanged()
        try await core.runNow(d.id)
        _ = await eventually { self.ranCount(h) == 1 }
        await core.shutdown()   // redémarrage de l'agent pour une mise à jour
        let again = h.makeCore(drives: drives)
        await again.start()
        await settle(h, again)
        let restarted = await eventually(timeout: 5) { self.ranCount(h) == 2 }
        XCTAssertTrue(restarted, "la copie coupée repart sans rebrancher le disque")
        h.factory.runners.get().forEach { $0.release() }
        await again.waitForIdle()
    }

    func testADriveRunAskedDuringTheWaitStartsAfterTheRestart() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let identity = Locked<String?>("v1")
        h.configuration.executableIdentity = { identity.get() }
        let drives = FakeDriveMonitor()
        let d = backup()
        try h.save([d])
        drives.plug(uuid, at: "/Volumes/X")
        let core = h.makeCore(drives: drives)
        await core.start()
        await settle(h, core)
        await core.waitForIdle()
        let before = ranCount(h)
        identity.set("v2")
        await core.tick()
        try await core.runNow(d.id)   // « Lancer » pendant l'attente du redémarrage
        await core.shutdown()
        let again = h.makeCore(drives: drives)
        await again.start()
        await settle(h, again)
        await again.waitForIdle()
        XCTAssertEqual(ranCount(h), before + 1, "la demande n'est pas perdue")
    }

    func testTheAppIsOpenedAtOnceEvenWithACopyRunning() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let identity = Locked<String?>("v1")
        let opened = Locked(0)
        h.configuration.executableIdentity = { identity.get() }
        h.configuration.openApp = { opened.update { $0 += 1 } }
        let a = SyncTask(name: "A", source: .local(path: "/a"), destination: .local(path: "/b"))
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        identity.set("v2")
        await core.tick()
        XCTAssertEqual(opened.get(), 1, "l'app redémarre l'agent sans attendre la fin de la copie")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }
}
