import XCTest
@testable import SyncKit

final class RcloneConfiguratorTests: XCTestCase {
    var folder: URL!
    var config: String { folder.appendingPathComponent("rclone.conf").path }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data/Photos"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data/Docs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func configurator(timeout: TimeInterval = 600) throws -> RcloneConfigurator {
        guard let rclone = BinaryLocator.locate(.rclone) else { throw XCTSkip("rclone introuvable") }
        return RcloneConfigurator(rclonePath: rclone, configPath: config, configureTimeout: timeout, openBrowser: false)
    }

    func testCreateListTestAndDelete() async throws {
        let rclone = try configurator()
        let made = try await rclone.configure(.start(name: "local", type: "alias", parameters: ["remote": folder.appendingPathComponent("data").path]))
        XCTAssertEqual(made, .done)
        let remotes = try await rclone.listRemotes()
        XCTAssertEqual(remotes, [RemoteInfo(name: "local", type: "alias")])
        let test = await rclone.test("local")
        XCTAssertTrue(test.ok, test.message ?? "")
        let folders = try await rclone.folders(remote: "local", path: "")
        XCTAssertEqual(folders, ["Docs", "Photos"])
        try await rclone.delete("local")
        let after = try await rclone.listRemotes()
        XCTAssertTrue(after.isEmpty)
    }

    func testS3IsCreatedWithoutNetwork() async throws {
        let rclone = try configurator()
        let outcome = try await rclone.configure(.start(name: "s3", type: "s3", parameters: [
            "provider": "AWS", "env_auth": "false", "access_key_id": "AKIAFAKE", "secret_access_key": "secret", "region": "eu-west-3",
        ]))
        XCTAssertEqual(outcome, .done)
        let remotes = try await rclone.listRemotes()
        XCTAssertEqual(remotes.map(\.type), ["s3"])
    }

    func testQuestionsThenAnswer() async throws {
        let rclone = try configurator()
        guard case .question(let first) = try await rclone.configure(.start(name: "od", type: "onedrive", parameters: [:])) else {
            return XCTFail("OneDrive demande d'abord comment s'authentifier")
        }
        XCTAssertEqual(first.option, "config_is_local")
        // « false » : pas de navigateur, rclone demande alors un jeton collé (on ne va pas plus loin).
        guard case .question(let second) = try await rclone.configure(.answer(name: "od", state: first.state, result: "false")) else {
            return XCTFail()
        }
        XCTAssertEqual(second.option, "config_token")
    }

    func testUnreachableRemoteFailsTheTest() async throws {
        let rclone = try configurator()
        _ = try await rclone.configure(.start(name: "absent", type: "alias", parameters: ["remote": "/n-existe-pas-\(UUID().uuidString)"]))
        let test = await rclone.test("absent")
        XCTAssertFalse(test.ok)
        XCTAssertFalse((test.message ?? "").isEmpty)
        let unknown = await rclone.test("inconnue")
        XCTAssertFalse(unknown.ok)
    }

    func testTimeoutStopsRclone() async throws {
        // `config_is_local = true` lance l'attente du navigateur (sans l'ouvrir : --auth-no-open-browser est ajouté
        // par le test via le paramètre d'environnement) ; le délai très court l'interrompt.
        let rclone = try configurator(timeout: 1.5)
        guard case .question(let first) = try await rclone.configure(.start(name: "db", type: "dropbox", parameters: [:])) else {
            return XCTFail()
        }
        let started = Date()
        do {
            _ = try await rclone.configure(.answer(name: "db", state: first.state, result: "true"))
            XCTFail("doit expirer")
        } catch {
            XCTAssertEqual(error as? RemoteConfigError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testCancelStopsRclone() async throws {
        let rclone = try configurator()
        guard case .question(let first) = try await rclone.configure(.start(name: "db", type: "dropbox", parameters: [:])) else {
            return XCTFail()
        }
        let pending = Task { try await rclone.configure(.answer(name: "db", state: first.state, result: "true")) }
        try await Task.sleep(nanoseconds: 800_000_000)
        rclone.cancelConfiguration("db")
        do {
            _ = try await pending.value
            XCTFail("doit être annulée")
        } catch {
            XCTAssertEqual(error as? RemoteConfigError, .cancelled)
        }
    }

    // Les deux sorties sont lues par deux fils : aucune ligne ne doit se perdre.
    func testNoOutputLineIsLost() async throws {
        let shell = RcloneConfigurator(rclonePath: "/bin/sh", configPath: nil)
        let script = "i=0; while [ $i -lt 2000 ]; do echo o$i; echo e$i >&2; i=$((i+1)); done"
        let output = try await shell.run(["-c", script], timeout: 30)
        XCTAssertEqual(output.stdout.split(separator: "\n").count, 2000)
        XCTAssertEqual(output.stderr.split(separator: "\n").count, 2000)
    }

    // Les messages de rclone sont ramenés à l'essentiel.
    func testMessagesAreShortened() {
        let s3 = "2026/10/13 15:30:00 ERROR : : error listing: lsjson with 2 errors: last error was: error in ListJSON: operation error S3: ListBuckets, https response error StatusCode: 403, RequestID: X, HostID: Y, api error InvalidAccessKeyId: The AWS Access Key Id you provided does not exist in our records."
        XCTAssertEqual(RcloneConfigurator.message(s3), "InvalidAccessKeyId: The AWS Access Key Id you provided does not exist in our records.")
        let missing = "2026/10/13 15:30:00 NOTICE: lsjson with 2 errors: last error was: error in ListJSON: directory not found"
        XCTAssertEqual(RcloneConfigurator.message(missing), "directory not found")
        let unknown = #"2026/10/13 15:04:40 CRITICAL: Failed to create file system for "nope:": didn't find section in config file ("nope")"#
        XCTAssertEqual(RcloneConfigurator.message(unknown), #"Failed to create file system for "nope:": didn't find section in config file ("nope")"#)
        XCTAssertEqual(RcloneConfigurator.message(""), "rclone a échoué.")
    }
}
