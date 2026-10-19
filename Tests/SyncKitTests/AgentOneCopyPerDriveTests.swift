import XCTest
@testable import SyncKit

/// 1.6.3 : une seule copie à la fois par disque amovible (deux copies sur un même disque dur se ralentissent l'une
/// l'autre : essai réel sur HDDExtBRSM, ~10 Mo/s à deux).
final class AgentOneCopyPerDriveTests: XCTestCase {
    let uuid = "AAAA-1111"

    func backup(_ name: String, uuid: String? = nil, volume: String = "Extreme Pro") -> SyncTask {
        var task = SyncTask(name: name, source: .local(path: "/source/\(name)"), destination: .local(path: "/Volumes/\(volume)/\(name)"),
                            schedule: .manual)
        task.removableDrive = RemovableDrive(volumeUUID: uuid ?? self.uuid, volumeName: volume, relativePath: name,
                                             trigger: .everyConnection, resumeWindowDays: 3, eject: .never)
        return task
    }

    func plug(_ h: AgentHarness, _ drives: FakeDriveMonitor, _ core: AgentCore, _ id: String, at path: String) async {
        drives.plug(id, at: path)
        await core.drivesChanged()
        h.clock.advance(6)
        await core.drivesChanged()
        await core.tick()
    }

    func testTwoBackupsOnOneDriveRunOneAfterTheOther() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        try h.save([backup("A"), backup("B")])
        let core = h.makeCore(drives: drives)
        await core.start()
        await plug(h, drives, core, uuid, at: "/Volumes/Extreme Pro")
        XCTAssertEqual(h.factory.created, 1)
        h.factory.runners.get()[0].release()
        let second = await eventually { h.factory.created == 2 }
        XCTAssertTrue(second)
        h.factory.runners.get()[1].release()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.runCount, 2)
    }

    func testManualRunOnABusyDriveWaitsInLine() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        var a = backup("A"); a.removableDrive?.trigger = .atMostEveryDays(30)
        var b = backup("B"); b.removableDrive?.trigger = .atMostEveryDays(30)
        let other = SyncTask(name: "Autre", source: .local(path: "/x"), destination: .local(path: "/y"), schedule: .manual)
        try h.save([a, b, other])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.plug(uuid, at: "/Volumes/Extreme Pro")
        await core.drivesChanged()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        try await core.runNow(other.id)
        XCTAssertEqual(h.factory.created, 2, "A et Autre tournent ; B attend son disque")
        let states = await core.status().tasks
        XCTAssertEqual(states.first { $0.id == b.id }?.state, .queued)
        h.factory.runners.get()[0].release()
        let bStarted = await eventually { h.factory.runners.get().contains { $0.ranTasks.get().first?.name == "B" } }
        XCTAssertTrue(bStarted)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testDifferentDrivesRunTogether() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        try h.save([backup("A"), backup("B", uuid: "BBBB-2222", volume: "HDD")])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.plug("BBBB-2222", at: "/Volumes/HDD")
        await plug(h, drives, core, uuid, at: "/Volumes/Extreme Pro")
        XCTAssertEqual(h.factory.created, 2)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testUserQueueWaitsForTheDrive() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let drives = FakeDriveMonitor()
        var a = backup("A"); a.removableDrive?.trigger = .atMostEveryDays(30)
        var b = backup("B"); b.removableDrive?.trigger = .atMostEveryDays(30)
        try h.save([a, b])
        let core = h.makeCore(drives: drives)
        await core.start()
        drives.plug(uuid, at: "/Volumes/Extreme Pro")
        await core.drivesChanged()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        XCTAssertEqual(h.factory.created, 1, "B attend que A libère le disque")
        let bState = await core.status().tasks.first { $0.id == b.id }?.state
        XCTAssertEqual(bState, .queued, "B reste en attente")
        h.factory.runners.get()[0].release()
        let bStarted = await eventually { h.factory.created == 2 }
        XCTAssertTrue(bStarted)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }
}
