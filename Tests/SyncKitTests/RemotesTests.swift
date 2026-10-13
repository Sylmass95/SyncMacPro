import XCTest
@testable import SyncKit

final class RemotesTests: XCTestCase {
    func data(_ name: String) throws -> Data { Data(try Fixture.text(name, ext: "json").utf8) }

    func testBooleanQuestion() throws {
        guard case .question(let q) = try RcloneConfigReply.outcome(from: data("rclone_config_bool")) else { return XCTFail() }
        XCTAssertEqual(q.state, "*oauth-islocal,choose_type,,")
        XCTAssertEqual(q.option, "config_is_local")
        XCTAssertEqual(q.kind, "bool")
        XCTAssertEqual(q.defaultValue, "true")
        XCTAssertEqual(q.choices.map(\.value), ["true", "false"])
        XCTAssertTrue(q.exclusive)
        XCTAssertFalse(q.isPassword)
    }

    func testTextQuestion() throws {
        guard case .question(let q) = try RcloneConfigReply.outcome(from: data("rclone_config_string")) else { return XCTFail() }
        XCTAssertEqual(q.option, "config_token")
        XCTAssertTrue(q.required)
        XCTAssertTrue(q.choices.isEmpty)
    }

    func testChoiceQuestion() throws {
        guard case .question(let q) = try RcloneConfigReply.outcome(from: data("rclone_config_choice")) else { return XCTFail() }
        XCTAssertEqual(q.option, "provider")
        XCTAssertGreaterThan(q.choices.count, 10)
        XCTAssertTrue(q.choices.contains { $0.value == "AWS" })
        XCTAssertFalse(q.exclusive)
    }

    func testDriveSharedClientWarning() throws {
        guard case .question(let q) = try RcloneConfigReply.outcome(from: data("rclone_config_drive_shared")) else { return XCTFail() }
        XCTAssertEqual(q.option, "config_shared_client_id")
        XCTAssertEqual(q.state, "client_id_warning")
        XCTAssertTrue(q.help.contains("2026"))
    }

    func testDone() throws {
        XCTAssertEqual(try RcloneConfigReply.outcome(from: data("rclone_config_done")), .done)
    }

    func testRcloneErrorAndGarbage() {
        let error = Data(#"{"State":"","Option":null,"Error":"valeur refusée","Result":""}"#.utf8)
        XCTAssertThrowsError(try RcloneConfigReply.outcome(from: error)) {
            XCTAssertEqual($0 as? RemoteConfigError, .rclone("valeur refusée"))
        }
        XCTAssertThrowsError(try RcloneConfigReply.outcome(from: Data("NOTICE: rien\n".utf8))) {
            XCTAssertEqual($0 as? RemoteConfigError, .unreadable)
        }
        let partial = Data(#"{"State":"x","Option":{"Name":"n"}}"#.utf8)
        guard case .question(let q) = try? RcloneConfigReply.outcome(from: partial) else { return XCTFail("lecture tolérante") }
        XCTAssertEqual(q.option, "n")
        XCTAssertEqual(q.kind, "string")
    }

    func testRemotesAndFolders() throws {
        let remotes = try RcloneConfigReply.remotes(from: data("rclone_listremotes"))
        XCTAssertEqual(remotes, [RemoteInfo(name: "od", type: "onedrive"), RemoteInfo(name: "s", type: "s3"), RemoteInfo(name: "a", type: "alias")])
        let listing = Data(#"[{"Path":"b","Name":"b","IsDir":true},{"Path":"A","Name":"A","IsDir":true},{"Name":"f.txt","IsDir":false}]"#.utf8)
        XCTAssertEqual(try RcloneConfigReply.folders(from: listing), ["A", "b"])
    }

    func testNoConfigurationFileMeansNoRemotes() throws {
        // Sans rclone.conf (première installation), rclone n'écrit rien sur la sortie standard.
        XCTAssertEqual(try RcloneConfigReply.remotes(from: Data()), [])
        XCTAssertEqual(try RcloneConfigReply.remotes(from: Data(" \n".utf8)), [])
    }

    func testCommands() {
        let config = "/tmp/r.conf"
        XCTAssertEqual(RcloneConfigCommand.listRemotes(config: config), ["listremotes", "--long", "--json", "--config", config])
        XCTAssertEqual(
            RcloneConfigCommand.arguments(for: .start(name: "Drive", type: "drive", parameters: ["scope": "drive", "client_id": "x"]), config: nil),
            ["config", "create", "Drive", "drive", "client_id=x", "scope=drive", "--non-interactive"]
        )
        XCTAssertEqual(
            RcloneConfigCommand.arguments(for: .answer(name: "Drive", state: "*oauth", result: "true"), config: config),
            ["config", "update", "Drive", "--continue", "--state", "*oauth", "--result", "true", "--non-interactive", "--config", config]
        )
        XCTAssertEqual(
            RcloneConfigCommand.arguments(for: .reconnect(name: "Drive"), config: nil),
            ["config", "update", "Drive", "config_refresh_token=true", "--non-interactive"]
        )
        XCTAssertEqual(RcloneConfigCommand.delete("Drive", config: nil), ["config", "delete", "Drive"])
        XCTAssertEqual(RcloneConfigCommand.test("Drive", config: nil), ["lsjson", "Drive:", "--dirs-only", "--max-depth", "1"])
        XCTAssertEqual(RcloneConfigCommand.folders(remote: "Drive", path: "/Photos/", config: nil),
                       ["lsjson", "Drive:Photos", "--dirs-only", "--max-depth", "1"])
    }

    func testNameRule() {
        let existing = ["Google Drive", "nas"]
        XCTAssertNil(RemoteNameRule.problem("Mon Drive", existing: existing))
        XCTAssertNil(RemoteNameRule.problem("s3_backup-1.eu@x+y", existing: existing))
        XCTAssertEqual(RemoteNameRule.problem("", existing: existing), .empty)
        XCTAssertEqual(RemoteNameRule.problem("a:b", existing: existing), .invalidCharacters)
        XCTAssertEqual(RemoteNameRule.problem("a/b", existing: existing), .invalidCharacters)
        XCTAssertEqual(RemoteNameRule.problem("-a", existing: existing), .badStart)
        XCTAssertEqual(RemoteNameRule.problem(" a", existing: existing), .badStart)
        XCTAssertEqual(RemoteNameRule.problem("a ", existing: existing), .badEnd)
        XCTAssertEqual(RemoteNameRule.problem("NAS", existing: existing), .taken, "rclone distingue la casse, mais deux noms identiques à la casse près prêtent à confusion")
        XCTAssertEqual(RemoteNameRule.suggestion("Google Drive", existing: existing), "Google Drive 2")
        XCTAssertEqual(RemoteNameRule.suggestion("Dropbox", existing: existing), "Dropbox")
    }

    func testRemoteNamesOfATask() {
        let task = SyncTask(name: "t", source: .cloud(remote: "drive", path: "a"), destination: .cloud(remote: "s3", path: "b"))
        XCTAssertEqual(task.remoteNames, ["drive", "s3"])
        XCTAssertEqual(SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b")).remoteNames, [])
    }
}
