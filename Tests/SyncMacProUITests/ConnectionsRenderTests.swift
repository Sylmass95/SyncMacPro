import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class ConnectionsRenderTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func body(_ remotes: [RemoteInfo], rows: [String: ConnectionRowState] = [:], error: String? = nil) -> ConnectionsListBody {
        ConnectionsListBody(
            remotes: remotes, usage: ["Drive": ["Photos vers Drive"]], rows: rows, error: error, offline: false,
            localizer: fr, onTest: { _ in }, onReconnect: { _ in }, onDelete: { _ in }
        )
    }

    func testListRendersEveryRowState() throws {
        let remotes = [RemoteInfo(name: "Drive", type: "drive"), RemoteInfo(name: "nas", type: "smb"), RemoteInfo(name: "S3", type: "s3")]
        let rows: [String: ConnectionRowState] = [
            "Drive": ConnectionRowState(testing: false, result: RemoteTestResult(ok: true)),
            "nas": ConnectionRowState(testing: true, result: nil),
            "S3": ConnectionRowState(testing: false, result: RemoteTestResult(ok: false, message: "InvalidAccessKeyId")),
        ]
        for scheme in [ColorScheme.light, .dark] {
            assertNotBlank(try render(body(remotes, rows: rows), name: "connections", size: CGSize(width: 640, height: 260), scheme: scheme))
        }
    }

    func testEmptyAndErrorStatesRender() throws {
        assertNotBlank(try render(body([]), name: "connections-empty", size: CGSize(width: 640, height: 160), scheme: .light))
        assertNotBlank(try render(body([], error: "rclone est introuvable."), name: "connections-error", size: CGSize(width: 640, height: 160), scheme: .light))
    }

    func testServiceLabels() {
        XCTAssertEqual(ConnectionsListBody.serviceName("drive", localizer: fr), "Google Drive")
        XCTAssertEqual(ConnectionsListBody.serviceName("sftp", localizer: fr), "sftp", "type inconnu : son nom rclone")
        XCTAssertEqual(ConnectionsListBody.serviceName("smb", localizer: fr), "NAS (SMB direct)", "1.8.10")
        XCTAssertTrue(ConnectionsListBody.canReconnect("drive"))
        XCTAssertFalse(ConnectionsListBody.canReconnect("s3"))
        XCTAssertFalse(ConnectionsListBody.canReconnect("smb"))
    }
}
