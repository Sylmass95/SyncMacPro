import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.8.1 : l'éditeur propose de passer par SSH quand un côté est un partage réseau, et teste la connexion.
@MainActor
final class SSH181UITests: XCTestCase {
    let share = EndpointResolver { url in
        url.path.hasPrefix("/Volumes/Documents")
            ? .init(isLocal: false, remountURL: URL(string: "smb://admin@QNAPTS332X._smb._tcp.local/Documents"))
            : .init(isLocal: true, remountURL: nil)
    }

    func draft() -> TaskDraft {
        var d = TaskDraft()
        d.name = "t"
        d.source.path = "/Users/moi/PERSO-FILES"
        d.destination.path = "/Volumes/Documents/PERSO-FILES"
        return d
    }

    func testTheNetworkSideIsFound() {
        XCTAssertEqual(draft().networkSide(resolver: share),
                       .network(url: "smb://admin@QNAPTS332X._smb._tcp.local/Documents", mountPath: "/Volumes/Documents/PERSO-FILES"))
        var local = draft(); local.destination.path = "/Users/moi/b"
        XCTAssertNil(local.networkSide(resolver: share))
    }

    func testTurningSSHOnSuggestsTheQNAPPath() {
        var d = draft()
        d.setSSH(true, resolver: share)
        XCTAssertEqual(d.ssh, SSHAccess(user: "admin", host: "QNAPTS332X.local", path: "/share/Documents/PERSO-FILES"))
        XCTAssertEqual(d.task(resolver: share).sshAccess, d.ssh)
        d.setSSH(false, resolver: share)
        XCTAssertNil(d.task(resolver: share).sshAccess)
    }

    func testSSHIsDroppedWhenNoSideIsOnAShare() {
        var d = draft()
        d.setSSH(true, resolver: share)
        d.destination.path = "/Users/moi/b"
        XCTAssertNil(d.task(resolver: share).sshAccess)
    }

    func testEditingATaskKeepsItsSSHAccess() {
        var task = draft().task(resolver: share)
        task.sshAccess = SSHAccess(user: "admin", host: "QNAP", path: "/share/x")
        XCTAssertEqual(TaskDraft(task: task).ssh, task.sshAccess)
    }

    func testTheConnectionTestCommand() {
        let access = SSHAccess(user: "admin", host: "QNAP.local", path: "/share/Documents/L'été")
        let args = SSHProbe.arguments(for: access)
        XCTAssertEqual(Array(args.prefix(4)), ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"])
        XCTAssertEqual(args[4], "admin@QNAP.local")
        XCTAssertTrue(args[5].contains("'/share/Documents/L'\\''été'"), "le chemin est protégé : \(args[5])")
    }

    func testConnectionTestOutcomes() {
        XCTAssertEqual(SSHProbe.Outcome(code: 0), .ok)
        XCTAssertEqual(SSHProbe.Outcome(code: 3), .noRsync)
        XCTAssertEqual(SSHProbe.Outcome(code: 4), .noFolder)
        XCTAssertEqual(SSHProbe.Outcome(code: 255), .refused)
    }
}
