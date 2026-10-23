import XCTest
@testable import SyncKit

/// 1.8.1 : un partage réseau peut être joint par SSH ; rsync tourne alors aussi sur le NAS, qui parcourt son propre disque
/// (essai réel QNAP : 55 s au lieu de plus de 18 min). Les noms accentués sont convertis (Mac NFD → NAS NFC).
final class SSH181Tests: XCTestCase {
    let qnap = SSHAccess(user: "admin", host: "QNAPTS332X.local", path: "/share/Documents/PERSO-FILES")
    let run = RunOptions(archiveStamp: "2026-10-23")

    func task(mode: SyncMode = .copy, toNAS: Bool = true) -> SyncTask {
        let share = Endpoint.network(url: "smb://admin@QNAPTS332X._smb._tcp.local/Documents", mountPath: "/Volumes/Documents/PERSO-FILES")
        let mac = Endpoint.local(path: "/Users/moi/PERSO-FILES")
        var t = SyncTask(name: "t", source: toNAS ? mac : share, destination: toNAS ? share : mac, mode: mode)
        t.sshAccess = qnap
        return t
    }

    func testTheNASSideGoesThroughSSH() throws {
        let args = try RsyncCommandBuilder.command(for: task(), run: run).arguments
        XCTAssertEqual(args.suffix(2), ["/Users/moi/PERSO-FILES/", "admin@QNAPTS332X.local:/share/Documents/PERSO-FILES/"])
        let e = try XCTUnwrap(args.firstIndex(of: "-e"))
        XCTAssertTrue(args[e + 1].hasPrefix("ssh -o BatchMode=yes"), "jamais de mot de passe demandé")
        XCTAssertTrue(args.contains("--iconv=UTF-8-MAC,UTF-8"))
        XCTAssertTrue(args.contains("--protect-args"), "les noms avec espaces passent tels quels")
        XCTAssertTrue(args.contains("--modify-window=1"))
    }

    func testTheNASAsSource() throws {
        let args = try RsyncCommandBuilder.planCommand(for: task(toNAS: false), run: run).arguments
        XCTAssertEqual(args.suffix(2), ["admin@QNAPTS332X.local:/share/Documents/PERSO-FILES/", "/Users/moi/PERSO-FILES/"])
        XCTAssertTrue(args.contains("--iconv=UTF-8-MAC,UTF-8"))
    }

    func testTheMirrorArchiveIsOnTheNAS() throws {
        let args = try RsyncCommandBuilder.command(for: task(mode: .mirror), run: run).arguments
        XCTAssertTrue(args.contains("--backup-dir=/share/Documents/PERSO-FILES/_ARCHIVE/2026-10-23"))
    }

    func testWithoutSSHNothingChanges() throws {
        var t = task(); t.sshAccess = nil
        let args = try RsyncCommandBuilder.command(for: t, run: run).arguments
        XCTAssertEqual(args.last, "/Volumes/Documents/PERSO-FILES/")
        XCTAssertFalse(args.contains("-e"))
    }

    func testOlderTaskFilesStillLoad() throws {
        let data = try JSONEncoder().encode(SyncTask(name: "a", source: .local(path: "/a"), destination: .local(path: "/b")))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "sshAccess")
        let decoded = try JSONDecoder().decode(SyncTask.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.sshAccess)
        let round = try JSONDecoder().decode(SyncTask.self, from: JSONEncoder().encode(task()))
        XCTAssertEqual(round.sshAccess, qnap)
    }

    func testSSHNeedsANetworkShareAndCompleteFields() {
        XCTAssertFalse(TaskValidator.problems(in: task()).contains(.invalidSSH))
        var local = SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))
        local.sshAccess = qnap
        XCTAssertTrue(TaskValidator.problems(in: local).contains(.invalidSSH))
        var empty = task(); empty.sshAccess = SSHAccess(user: "", host: "QNAP", path: "/share/x")
        XCTAssertTrue(TaskValidator.problems(in: empty).contains(.invalidSSH))
        var relative = task(); relative.sshAccess = SSHAccess(user: "admin", host: "QNAP", path: "share/x")
        XCTAssertTrue(TaskValidator.problems(in: relative).contains(.invalidSSH))
    }

    func testASuggestedPathOnAQNAP() {
        XCTAssertEqual(SSHAccess.suggested(for: .network(url: "smb://admin@QNAPTS332X._smb._tcp.local/Documents", mountPath: "/Volumes/Documents/PERSO-FILES")),
                       SSHAccess(user: "admin", host: "QNAPTS332X.local", path: "/share/Documents/PERSO-FILES"))
        XCTAssertEqual(SSHAccess.suggested(for: .network(url: "smb://moi@10.92.7.3/03_ARCHIVES_GLOBALES", mountPath: "/Volumes/03_ARCHIVES_GLOBALES"))?.path,
                       "/share/03_ARCHIVES_GLOBALES")
        XCTAssertNil(SSHAccess.suggested(for: .local(path: "/a")))
    }

    func testAnSSHFailureIsExplained() {
        XCTAssertTrue(SSHAccess.failureMessage(code: 255, access: qnap)?.contains("admin@QNAPTS332X.local") == true)
        XCTAssertNil(SSHAccess.failureMessage(code: 23, access: qnap))
    }
}
