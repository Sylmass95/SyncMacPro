import XCTest
@testable import SyncKit

/// 1.8.10 : sur le NAS 03, des noms enregistrés avec l'accent à part (« e » + accent) sont listés par le partage monté
/// mais introuvables à l'ouverture : macOS renvoie le nom sous l'autre forme. 45 fichiers échouaient à chaque copie
/// (« Dossier introuvable »), et 33 noms présents sous les deux formes étaient ignorés comme doublons. Une connexion SMB
/// directe (rclone) lit le nom tel qu'il est stocké : les fichiers illisibles sont rattrapés par elle.
private let nfdName = "COMMONS/Capture d\u{2019}e\u{301}cran a\u{300} 15.05.26.png"

private func unreadableLine(_ path: String, root: String = "/Volumes/03_ARCHIVES_GLOBALES") -> String {
    #"{"level":"error","msg":"Failed to copy: failed to open source object: open \#(root)/\#(path): no such file or directory","object":"\#(path)","objectType":"*local.Object"}"#
}

private func duplicateLine(_ path: String) -> String {
    #"{"level":"notice","msg":"Duplicate object found in source - ignoring","object":"\#(path)","objectType":"*local.Object"}"#
}

final class SourceNames1810Tests: XCTestCase {
    func testUnreadableAndDuplicateNamesAreRecognised() {
        XCTAssertEqual(SourceNameIssue.parse(rcloneLine: unreadableLine(nfdName)), .unreadable(nfdName))
        XCTAssertEqual(SourceNameIssue.parse(rcloneLine: duplicateLine("COMMONS/b.png")), .duplicate("COMMONS/b.png"))
        let missingFolder = #"{"level":"error","msg":"directory not found","object":"","objectType":"*local.Object"}"#
        XCTAssertNil(SourceNameIssue.parse(rcloneLine: missingFolder), "un dossier absent n'est pas un nom illisible")
        XCTAssertNil(SourceNameIssue.parse(rcloneLine: #"{"level":"info","msg":"Copied (new)","object":"a.png"}"#))
    }

    func testTheDirectConnectionAsksForTheFileNameAsListed() {
        let path = "Re\u{301}cupe\u{301}re\u{301}/Capture d\u{2019}e\u{301}cran.png"
        let direct = SourceNameIssue.directPath(path)
        XCTAssertEqual(Array(direct.unicodeScalars.prefix(2)).map(\.value), [0x52, 0xE9], "dossier : « é » en un caractère")
        XCTAssertTrue(direct.unicodeScalars.map(\.value).contains(0x301), "nom du fichier : tel que listé")
        XCTAssertEqual(SourceNameIssue.directPath("a.png"), "a.png")
    }

    func testRsyncUnreadableNamesAreRecognisedRelativeToTheSource() {
        let line = #"rsync: [sender] send_files failed to open "/Volumes/03_ARCHIVES_GLOBALES/\#(nfdName)": No such file or directory (2)"#
        XCTAssertEqual(SourceNameIssue.parse(rsyncLine: line, sourceRoot: "/Volumes/03_ARCHIVES_GLOBALES"), .unreadable(nfdName))
        XCTAssertNil(SourceNameIssue.parse(rsyncLine: line, sourceRoot: "/Volumes/Autre"))
    }

    func testTheShareOfANetworkSource() {
        let root = SMBShare.of(.network(url: "smb://sylvain.masson@10.92.7.3/03_ARCHIVES_GLOBALES", mountPath: "/Volumes/03_ARCHIVES_GLOBALES"))
        XCTAssertEqual(root, SMBShare(host: "10.92.7.3", user: "sylvain.masson", share: "03_ARCHIVES_GLOBALES", subpath: ""))
        let sub = SMBShare.of(.network(url: "smb://sylvain.masson@10.92.7.3/01_PROJETS_ACTIFS", mountPath: "/Volumes/01_PROJETS_ACTIFS/BEHIND_THE_STREAMS"))
        XCTAssertEqual(sub?.subpath, "BEHIND_THE_STREAMS")
        XCTAssertEqual(SMBShare.of(.network(url: "smb://NAS/Mes%20Documents", mountPath: "/Volumes/Mes Documents"))?.share, "Mes Documents")
        XCTAssertNil(SMBShare.of(.local(path: "/Users/x")))
        XCTAssertNil(SMBShare.of(.network(url: "afp://nas/x", mountPath: "/Volumes/x")))
    }

    func testTheDirectConnectionIsFoundByHostAndUser() {
        let config = """
        [Google Drive SyncMacPro rclone]
        type = drive
        token = {"access_token":"x"}

        [QNAP]
        type = smb
        host = qnapts332x.local
        user = admin

        [NAS Bedrock]
        type = smb
        host = 10.92.7.3
        user = sylvain.masson
        pass = obscur
        """
        let share = SMBShare(host: "10.92.7.3", user: "sylvain.masson", share: "03_ARCHIVES_GLOBALES", subpath: "COMMONS")
        XCTAssertEqual(SMBShare.remote(for: share, config: config), "NAS Bedrock")
        XCTAssertEqual(share.spec(remote: "NAS Bedrock"), "NAS Bedrock:03_ARCHIVES_GLOBALES/COMMONS")
        var other = share
        other.user = "autre"
        XCTAssertNil(SMBShare.remote(for: other, config: config), "autre compte : pas la même connexion")
        XCTAssertNil(SMBShare.remote(for: share, config: "[Drive]\ntype = drive\n"))
    }

    func testTheMessagesExplainWhatHappened() {
        XCTAssertEqual(SourceNameText.recovered(45),
                       "45 fichiers au nom mal enregistré sur le NAS (accents) ont été récupérés par la connexion directe.")
        XCTAssertTrue(SourceNameText.unreadable(45, hasDirectConnection: false).contains("trousseau"), "1.8.12")
        XCTAssertTrue(SourceNameText.duplicates(33).contains("33"))
    }

    func testDetailsKeepTheNewKindsOfRows() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("details-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let rows = [RunDetailRow(action: .added, size: 10, path: "a.png", origin: .local),
                    RunDetailRow(action: .recovered, size: 10, path: "a.png", origin: .local),
                    RunDetailRow(action: .unreadable, size: nil, path: "b.png", origin: .source),
                    RunDetailRow(action: .duplicate, size: nil, path: "c.png", origin: .source)]
        try rows.map(\.line).joined().write(to: file, atomically: true, encoding: .utf8)
        let details = try RunDetails.read(url: file, maxRows: 10)
        XCTAssertEqual(details.rows.map(\.action), [.recovered, .unreadable, .duplicate], "rattrapé : une seule ligne")
        XCTAssertEqual(details.rows.first?.size, 10)
    }

    func testFilesReadOverSMBAreOnTheNASSide() {
        let line = #"{"level":"info","msg":"Copied (new)","size":12,"object":"a.png","objectType":"*smb.Object"}"#
        XCTAssertEqual(RunDetailParser.parse(line)?.origin, .local)
    }
}

final class SourceNamesRunner1810Tests: IntegrationTestCase {
    /// Faux rclone : la copie échoue sur deux noms illisibles et signale un doublon ; la copie par connexion directe
    /// (`--files-from-raw`) copie ce qu'on lui donne et note ses arguments.
    private func fakeRclone(recoveryFails: Bool = false) throws -> String {
        let fake = sandbox.appendingPathComponent("fake-rclone").path
        let args = sandbox.appendingPathComponent("recovery-args").path
        try """
        #!/bin/sh
        for a in "$@"; do [ "$a" = "--dry-run" ] && exit 0; done
        [ "$1" = "copy" ] || exit 0
        list=""; prev=""
        for a in "$@"; do [ "$prev" = "--files-from-raw" ] && list="$a"; prev="$a"; done
        if [ -n "$list" ]; then
          printf '%s\\n' "$@" > '\(args)'
          \(recoveryFails ? "echo '{\"level\":\"error\",\"msg\":\"Failed to copy: refus\",\"object\":\"x\"}' >&2; exit 1" : "")
          while IFS= read -r p; do
            printf '{"level":"info","msg":"Copied (new)","size":5,"object":"%s","objectType":"*smb.Object"}\\n' "$p" >&2
          done < "$list"
          exit 0
        fi
        echo '\(unreadableLine(nfdName))' >&2
        echo '\(unreadableLine("COMMONS/Récupéré.psd"))' >&2
        echo '\(duplicateLine("COMMONS/double.png"))' >&2
        exit 1
        """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        return fake
    }

    private func runner(_ fake: String, smb: Bool) throws -> TaskRunner {
        let config = sandbox.appendingPathComponent("rclone.conf")
        let section = smb ? "[NAS Bedrock]\ntype = smb\nhost = 10.92.7.3\nuser = sylvain.masson\npass = x\n" : ""
        try "[Drive]\ntype = drive\n\n\(section)".write(to: config, atomically: true, encoding: .utf8)
        return TaskRunner(configuration: RunnerConfiguration(rclonePath: fake, rcloneConfigPath: config.path,
                                                             workDirectory: sandbox.appendingPathComponent("w")))
    }

    private func task() throws -> SyncTask {
        SyncTask(name: "NAS → Drive", source: .network(url: "smb://sylvain.masson@10.92.7.3/03_ARCHIVES_GLOBALES", mountPath: try folder("s")),
                 destination: .cloud(remote: "Drive", path: "BACKUP"))
    }

    func testUnreadableFilesAreRecoveredThroughTheDirectConnection() async throws {
        let rows = Locked<[RunDetailRow]>([]), lines = Locked<[String]>([])
        let result = try await runner(try fakeRclone(), smb: true).run(try task()) { update in
            if case .detail(let row) = update { rows.update { $0.append(row) } }
            if case .line(let text) = update { lines.update { $0.append(text) } }
        }
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertTrue(result.summary.message?.contains("2 fichiers au nom mal enregistré") == true, result.summary.message ?? "")
        XCTAssertTrue(result.summary.message?.contains("1 nom en double") == true, result.summary.message ?? "")
        let recovered = rows.get().filter { $0.action == .recovered }.map(\.path).sorted()
        XCTAssertEqual(recovered, ["COMMONS/Récupéré.psd", nfdName].sorted())
        XCTAssertEqual(rows.get().filter { $0.action == .duplicate }.map(\.path), ["COMMONS/double.png"])
        let args = try String(contentsOfFile: sandbox.appendingPathComponent("recovery-args").path, encoding: .utf8)
        XCTAssertTrue(args.contains("NAS Bedrock:03_ARCHIVES_GLOBALES\n"), args)
        XCTAssertTrue(args.contains("Drive:BACKUP\n"), args)
        XCTAssertTrue(lines.get().contains { $0.contains("Doublon sur le NAS") && $0.contains("COMMONS/double.png") })
    }

    func testWithoutADirectConnectionTheFailureIsExplained() async throws {
        let rows = Locked<[RunDetailRow]>([])
        let result = try await runner(try fakeRclone(), smb: false).run(try task()) { update in
            if case .detail(let row) = update { rows.update { $0.append(row) } }
        }
        XCTAssertEqual(result.status, .failed)
        let message = result.summary.message ?? ""
        XCTAssertTrue(message.contains("2 fichiers au nom mal enregistré"), message)
        XCTAssertFalse(message.contains("Dossier introuvable"), message)
        XCTAssertEqual(rows.get().filter { $0.action == .unreadable }.count, 2)
        XCTAssertFalse(result.retryable, "relancer ne changerait rien tant que la connexion directe manque")
    }

    func testAFailedRecoveryKeepsTheFilesListedAsUnreadable() async throws {
        let rows = Locked<[RunDetailRow]>([])
        let result = try await runner(try fakeRclone(recoveryFails: true), smb: true).run(try task()) { update in
            if case .detail(let row) = update { rows.update { $0.append(row) } }
        }
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(rows.get().filter { $0.action == .unreadable }.count, 2)
        XCTAssertTrue(result.summary.message?.contains("connexion directe") == true, result.summary.message ?? "")
    }
}
