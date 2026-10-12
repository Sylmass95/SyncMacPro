import XCTest
@testable import SyncKit

final class EngineSelectorTests: XCTestCase {
    private func task(
        source: Endpoint = .local(path: "/a"),
        destination: Endpoint = .local(path: "/b"),
        mode: SyncMode = .copy,
        forced: EngineKind? = nil
    ) -> SyncTask {
        SyncTask(
            name: "t", source: source, destination: destination, mode: mode,
            options: TaskOptions(forcedEngine: forced)
        )
    }

    func testLocalToNetworkUsesRsync() throws {
        let t = task(destination: .network(url: "smb://n/s", mountPath: "/Volumes/s"))
        XCTAssertEqual(try EngineSelector.engine(for: t), .rsync)
    }

    func testAnyCloudSideUsesRclone() throws {
        XCTAssertEqual(try EngineSelector.engine(for: task(destination: .cloud(remote: "g", path: ""))), .rclone)
        XCTAssertEqual(try EngineSelector.engine(for: task(source: .cloud(remote: "g", path: ""))), .rclone)
    }

    func testRcloneOnlyModesUseRcloneEvenLocally() throws {
        XCTAssertEqual(try EngineSelector.engine(for: task(mode: .bidirectional)), .rclone)
        XCTAssertEqual(try EngineSelector.engine(for: task(mode: .versioned)), .rclone)
    }

    func testForcingRcloneAlwaysWorks() throws {
        XCTAssertEqual(try EngineSelector.engine(for: task(mode: .mirror, forced: .rclone)), .rclone)
    }

    func testForcingRsyncOnCloudFails() {
        let t = task(destination: .cloud(remote: "g", path: ""), forced: .rsync)
        XCTAssertThrowsError(try EngineSelector.engine(for: t)) {
            XCTAssertEqual($0 as? EngineSelectionError, .cloudRequiresRclone)
        }
    }

    func testForcingRsyncOnBidirectionalFails() {
        let t = task(mode: .bidirectional, forced: .rsync)
        XCTAssertThrowsError(try EngineSelector.engine(for: t)) {
            XCTAssertEqual($0 as? EngineSelectionError, .unsupportedMode(mode: .bidirectional, engine: .rsync))
        }
    }
}
