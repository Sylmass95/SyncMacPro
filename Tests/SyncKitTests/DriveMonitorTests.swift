import XCTest
@testable import SyncKit

/// Volumes réels : une image disque montée dans le bac à sable du test joue le disque externe.
final class DriveMonitorTests: IntegrationTestCase {
    private func hdiutil(_ arguments: [String]) throws -> String { try shell("/usr/bin/hdiutil", arguments) }

    func testInternalVolumeIsRecognised() throws {
        let info = try XCTUnwrap(VolumeLookup.info(forPath: NSTemporaryDirectory()))
        XCTAssertFalse(info.isRemovable)
        XCTAssertFalse(info.isNetwork)
        XCTAssertNotNil(info.uuid)
    }

    func testDiskImageIsAnExternalVolumeAndItsComingAndGoingIsSeen() async throws {
        let image = sandbox.appendingPathComponent("usb.dmg").path
        let mount = VolumeLookup.canonical(sandbox.appendingPathComponent("BancUSB").path)
        _ = try hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "BancUSB", "-ov", image])
        let monitor = DiskArbitrationMonitor()
        let changes = Locked(0)
        monitor.start { changes.update { $0 += 1 } }
        defer { monitor.stop() }
        _ = try hdiutil(["attach", "-nobrowse", "-mountpoint", mount, image])
        defer { _ = try? hdiutil(["detach", "-force", mount]) }
        // Le volume peut mettre un instant à apparaître après le retour de `hdiutil attach`.
        _ = await eventually(timeout: 3) { VolumeLookup.info(forPath: mount + "/")?.rootPath == mount }
        let info = try XCTUnwrap(VolumeLookup.info(forPath: mount + "/"))
        XCTAssertTrue(info.isRemovable)
        let uuid = try XCTUnwrap(info.uuid)
        XCTAssertEqual(info.rootPath, mount)
        XCTAssertEqual(info.relativePath(of: mount + "/Sauvegardes/Photos"), "Sauvegardes/Photos")
        let seenMount = await eventually(timeout: 5) { changes.get() > 0 }
        XCTAssertTrue(seenMount, "montage signalé")
        XCTAssertEqual(monitor.mountedVolumes()[uuid], mount)
        let before = changes.get()
        let refusal = await monitor.eject(mountPath: mount)
        XCTAssertNil(refusal, refusal ?? "")
        let seenEject = await eventually(timeout: 5) { changes.get() > before }
        XCTAssertTrue(seenEject, "démontage signalé")
        XCTAssertNil(monitor.mountedVolumes()[uuid])
    }

    /// Un moniteur abandonné sans `stop()` ne doit pas faire planter le processus au disque suivant (rappel
    /// DiskArbitration sur un objet libéré).
    func testAbandonedMonitorSurvivesTheNextDiskEvent() async throws {
        let image = sandbox.appendingPathComponent("usb2.dmg").path
        let mount = VolumeLookup.canonical(sandbox.appendingPathComponent("BancUSB2").path)
        _ = try hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "BancUSB2", "-ov", image])
        do {
            let abandoned = DiskArbitrationMonitor()
            abandoned.start {}
        }
        let watcher = DiskArbitrationMonitor()
        let changes = Locked(0)
        watcher.start { changes.update { $0 += 1 } }
        defer { watcher.stop() }
        _ = try hdiutil(["attach", "-nobrowse", "-mountpoint", mount, image])
        _ = try hdiutil(["detach", "-force", mount])
        let seen = await eventually(timeout: 5) { changes.get() >= 2 }
        XCTAssertTrue(seen, "le processus est toujours là et les événements arrivent")
    }

    func testStoppedMonitorNoLongerCallsBack() async throws {
        let image = sandbox.appendingPathComponent("usb3.dmg").path
        let mount = VolumeLookup.canonical(sandbox.appendingPathComponent("BancUSB3").path)
        _ = try hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "BancUSB3", "-ov", image])
        let monitor = DiskArbitrationMonitor()
        let changes = Locked(0)
        monitor.start { changes.update { $0 += 1 } }
        monitor.stop()
        _ = try hdiutil(["attach", "-nobrowse", "-mountpoint", mount, image])
        _ = try hdiutil(["detach", "-force", mount])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(changes.get(), 0)
    }

    /// Heure du branchement (1.5.0) : celle du dernier branchement, pas du formatage du volume.
    func testMountDateIsThePlugTime() throws {
        let image = sandbox.appendingPathComponent("usb4.dmg").path
        let mount = VolumeLookup.canonical(sandbox.appendingPathComponent("BancUSB4").path)
        _ = try hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "BancUSB4", "-ov", image])
        _ = try hdiutil(["attach", "-nobrowse", "-mountpoint", mount, image])
        _ = try hdiutil(["detach", "-force", mount])
        Thread.sleep(forTimeInterval: 2)
        let replugged = Date()
        _ = try hdiutil(["attach", "-nobrowse", "-mountpoint", mount, image])
        defer { _ = try? hdiutil(["detach", "-force", mount]) }
        let appeared = try XCTUnwrap(DiskArbitrationMonitor().mountDate(path: mount))
        XCTAssertGreaterThan(appeared.timeIntervalSince(replugged), -1, "date du rebranchement, pas du formatage")
    }
}
