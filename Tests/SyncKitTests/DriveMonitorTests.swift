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
        _ = try hdiutil(["attach", "-nobrowse", "-mountpoint", mount, image])
        defer { _ = try? hdiutil(["detach", "-force", mount]) }
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
}
