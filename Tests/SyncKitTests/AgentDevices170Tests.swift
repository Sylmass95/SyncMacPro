import XCTest
@testable import SyncKit

/// 1.7.0 : départ dans l'ordre de la liste, deux copies au plus, jamais deux sur un même disque physique (source ou
/// destination) ; une copie en pause libère sa place et son disque.
final class AgentDevices170Tests: XCTestCase {
    func task(_ name: String, from source: Endpoint? = nil, to destination: Endpoint? = nil, schedule: Schedule = .manual) -> SyncTask {
        SyncTask(name: name, source: source ?? .local(path: "/Users/moi/\(name)"),
                 destination: destination ?? .local(path: "/Users/moi/copie-\(name)"), schedule: schedule)
    }

    func harness() throws -> AgentHarness {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        h.conditions.devices.set(["/Volumes/NAS": "nas", "/Volumes/QNAP": "qnap"])
        return h
    }

    func startedNames(_ h: AgentHarness) -> [String] { h.factory.runners.get().compactMap { $0.ranTasks.get().first?.name } }
    func runner(_ h: AgentHarness, _ name: String) -> FakeRunner? { h.factory.runners.get().first { $0.ranTasks.get().first?.name == name } }
    func info(_ core: AgentCore, _ id: UUID) async -> AgentTaskInfo? { await core.status().tasks.first { $0.id == id } }

    func testWaitingRunsStartInListOrder() async throws {
        let h = try harness()
        let x = task("X"), y = task("Y"), a = task("A"), b = task("B"), c = task("C")
        try h.save([x, y, a, b, c])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(x.id)
        try await core.runNow(y.id)
        for t in [a, b, c] { try await core.runNow(t.id) }
        await core.reorder([x.id, y.id, c.id, b.id, a.id])
        runner(h, "X")?.release()
        runner(h, "Y")?.release()
        let next = await eventually { h.factory.created == 4 }
        XCTAssertTrue(next)
        XCTAssertEqual(Array(startedNames(h).suffix(2)), ["C", "B"])
        runner(h, "C")?.release()
        let last = await eventually { h.factory.created == 5 }
        XCTAssertTrue(last)
        XCTAssertEqual(startedNames(h).last, "A")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testABusyDiskLetsTheNextOneGo() async throws {
        let h = try harness()
        let a = task("A", to: .local(path: "/Volumes/NAS/a")), b = task("B", to: .local(path: "/Volumes/NAS/b")), c = task("C")
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        for t in [a, b, c] { try await core.runNow(t.id) }
        _ = await eventually { h.factory.created == 2 }
        XCTAssertEqual(Set(startedNames(h)), ["A", "C"])
        let waiting = await info(core, b.id)
        XCTAssertEqual(waiting?.state, .queued)
        XCTAssertTrue(waiting?.waitReason?.contains("même disque que « A »") == true, waiting?.waitReason ?? "nil")
        h.factory.runners.get().forEach { $0.release() }
        _ = await eventually { h.factory.created == 3 }
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testASourceCountsLikeADestination() async throws {
        let h = try harness()
        let a = task("A", from: .local(path: "/Volumes/NAS/x"), to: .cloud(remote: "drive", path: "x"))
        let b = task("B", from: .cloud(remote: "drive", path: "y"), to: .local(path: "/Volumes/NAS/y"))
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        XCTAssertEqual(h.factory.created, 1)
        h.factory.runners.get().forEach { $0.release() }
        _ = await eventually { h.factory.created == 2 }
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testTwoSharesOfTheSameServerAreOneDisk() {
        XCTAssertEqual(PhysicalDevice.networkKey(url: "smb://moi@10.92.7.3/01_PROJETS_ACTIFS"),
                       PhysicalDevice.networkKey(url: "smb://moi@10.92.7.3/03_ARCHIVES_GLOBALES"))
        XCTAssertNotEqual(PhysicalDevice.networkKey(url: "smb://moi@10.92.7.3/x"), PhysicalDevice.networkKey(url: "smb://admin@QNAP.local/x"))
        XCTAssertEqual(PhysicalDevice.networkKey(url: "smb://Admin@QNAP.Local/Documents"), "net:qnap.local")
        XCTAssertEqual(PhysicalDevice.wholeDisk(fromDevice: "/dev/disk6s1"), "disk:disk6")
        XCTAssertEqual(PhysicalDevice.wholeDisk(fromDevice: "//moi@10.92.7.3/03_ARCHIVES"), "net:10.92.7.3")
    }

    func testInternalDiskAndCloudAreNotLimited() async throws {
        let h = try harness()
        let a = task("A", to: .cloud(remote: "drive", path: "a")), b = task("B", to: .cloud(remote: "drive", path: "b"))
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        XCTAssertEqual(h.factory.created, 2)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testThirdRunWaitsForAPlace() async throws {
        let h = try harness()
        let a = task("A"), b = task("B"), c = task("C")
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        for t in [a, b, c] { try await core.runNow(t.id) }
        let third = await info(core, c.id)
        XCTAssertEqual(third?.state, .queued)
        XCTAssertTrue(third?.waitReason?.contains("place") == true, third?.waitReason ?? "nil")
        h.factory.runners.get().forEach { $0.release() }
        _ = await eventually { h.factory.created == 3 }
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testAPausedCopyFreesItsPlaceAndDisk() async throws {
        let h = try harness()
        let a = task("A", to: .local(path: "/Volumes/NAS/a")), b = task("B", to: .local(path: "/Volumes/NAS/b"))
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        XCTAssertEqual(h.factory.created, 1)
        try await core.pause(a.id)
        let started = await eventually { h.factory.created == 2 }
        XCTAssertTrue(started, "B part sur le disque libéré")
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testResumingWaitsForItsDisk() async throws {
        let h = try harness()
        let a = task("A", to: .local(path: "/Volumes/NAS/a")), b = task("B", to: .local(path: "/Volumes/NAS/b"))
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.pause(a.id)
        try await core.runNow(b.id)
        try await core.resume(a.id)
        let pending = await info(core, a.id)
        XCTAssertEqual(pending?.state, .paused)
        XCTAssertEqual(pending?.resumePending, true)
        XCTAssertTrue(pending?.waitReason?.contains("même disque que « B »") == true, pending?.waitReason ?? "nil")
        XCTAssertNotEqual(runner(h, "A")?.calls.get().last, "resume")
        runner(h, "B")?.release()
        let resumed = await eventually { self.runner(h, "A")?.calls.get().last == "resume" }
        XCTAssertTrue(resumed)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func driveTask(_ name: String) -> SyncTask {
        var t = task(name, to: .local(path: "/Volumes/X/\(name)"))
        t.removableDrive = RemovableDrive(volumeUUID: "U", volumeName: "X", relativePath: name, trigger: .everyConnection,
                                          resumeWindowDays: 3, eject: .never)
        return t
    }

    func plug(_ h: AgentHarness, _ drives: FakeDriveMonitor, _ core: AgentCore) async {
        drives.plug("U", at: "/Volumes/X")
        await core.drivesChanged()
        h.clock.advance(6)
        await core.drivesChanged()
        await core.tick()
    }

    func testADriveTaskPluggedWhileBothPlacesAreTakenWaitsThenStarts() async throws {
        let h = try harness()
        let a = task("A"), b = task("B"), d = driveTask("D")
        try h.save([a, b, d])
        let drives = FakeDriveMonitor()
        let core = h.makeCore(drives: drives)
        await core.start()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        await plug(h, drives, core)
        XCTAssertEqual(h.factory.created, 2)
        let waiting = await info(core, d.id)
        XCTAssertEqual(waiting?.state, .queued)
        runner(h, "A")?.release()
        let started = await eventually { h.factory.created == 3 }
        XCTAssertTrue(started)
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }

    func testAnUnpluggedDriveTaskLeavesTheWait() async throws {
        let h = try harness()
        let a = task("A"), b = task("B"), d = driveTask("D")
        try h.save([a, b, d])
        let drives = FakeDriveMonitor()
        let core = h.makeCore(drives: drives)
        await core.start()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        await plug(h, drives, core)
        drives.unplug("U")
        await core.drivesChanged()
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
        await core.tick()
        XCTAssertEqual(h.factory.created, 2, "D ne part pas sans son disque")
        let state = await info(core, d.id)?.state
        XCTAssertNotEqual(state, .queued)
    }
}
