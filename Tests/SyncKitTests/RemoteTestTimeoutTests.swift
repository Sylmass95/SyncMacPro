import XCTest
@testable import SyncKit

/// Essai réel 1.0.0 : le premier test d'une connexion Google Drive a dépassé 30 s, avec un message parlant du navigateur.
final class RemoteTestTimeoutTests: XCTestCase {
    func testConnectionTestsAllowAMinuteByDefault() throws {
        let rclone = RcloneConfigurator(rclonePath: "/bin/sh", configPath: nil)
        XCTAssertGreaterThanOrEqual(rclone.testTimeout, 60)
    }

    func testASlowServiceIsNotBlamedOnTheBrowser() async throws {
        // Un faux rclone qui ne répond jamais.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("rclone")
        try "#!/bin/sh\nsleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let rclone = RcloneConfigurator(rclonePath: fake.path, configPath: nil, testTimeout: 1)
        let result = await rclone.test("gdrive")
        XCTAssertFalse(result.ok)
        let message = try XCTUnwrap(result.message)
        XCTAssertFalse(message.contains("navigateur"), message)
        XCTAssertTrue(message.contains("répondu"), message)
    }
}
