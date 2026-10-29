import XCTest
@testable import SyncKit

/// 1.8.12 : la connexion directe au NAS ne se crée plus à la main. SyncMacPro la déduit du partage (adresse, compte) et
/// prend le mot de passe que macOS garde dans le trousseau pour le monter ; rclone le reçoit le temps de la copie, par
/// son environnement (jamais dans ses arguments ni dans un fichier).
final class Keychain1812Tests: IntegrationTestCase {
    func testAPasswordObscuredBySyncMacProIsReadByRclone() throws {
        let rclone = try rclonePath()
        for secret in ["mot de passe", "é,:'\"=%", String(repeating: "x", count: 70)] {
            let obscured = RcloneObscure.obscure(secret)
            XCTAssertNotEqual(obscured, RcloneObscure.obscure(secret), "nouveau vecteur à chaque fois")
            XCTAssertEqual(try shell(rclone, ["reveal", obscured]).trimmingCharacters(in: .newlines), secret)
        }
    }

    func testTheInlineConnectionNamesTheShare() {
        let share = SMBShare(host: "10.92.7.3", user: "sylvain.masson", share: "03_ARCHIVES_GLOBALES", subpath: "COMMONS")
        XCTAssertEqual(share.inlineSpec, ":smb,host=10.92.7.3,user=sylvain.masson:03_ARCHIVES_GLOBALES/COMMONS")
        let odd = SMBShare(host: "nas", user: "dom,ain:x", share: "Mes Documents", subpath: "")
        XCTAssertEqual(odd.inlineSpec, ":smb,host=nas,user='dom,ain:x':Mes Documents")
        XCTAssertEqual(SMBShare(host: "nas", user: nil, share: "s", subpath: "").inlineSpec, ":smb,host=nas:s")
    }

    // MARK: rattrapage par la connexion tirée du trousseau

    private func fakeRclone() throws -> String {
        let fake = sandbox.appendingPathComponent("fake-rclone").path
        let args = sandbox.appendingPathComponent("recovery-args").path
        let env = sandbox.appendingPathComponent("recovery-env").path
        let line = #"{"level":"error","msg":"Failed to copy: failed to open source object: open /s/a\#u{301}.png: no such file or directory","object":"a\#u{301}.png","objectType":"*local.Object"}"#
        try """
        #!/bin/sh
        for a in "$@"; do [ "$a" = "--dry-run" ] && exit 0; done
        [ "$1" = "copy" ] || exit 0
        list=""; prev=""
        for a in "$@"; do [ "$prev" = "--files-from-raw" ] && list="$a"; prev="$a"; done
        if [ -n "$list" ]; then
          printf '%s\\n' "$@" > '\(args)'
          printf '%s' "$RCLONE_SMB_PASS" > '\(env)'
          while IFS= read -r p; do
            printf '{"level":"info","msg":"Copied (new)","size":5,"object":"%s","objectType":"*smb.Object"}\\n' "$p" >&2
          done < "$list"
          exit 0
        fi
        echo '\(line)' >&2
        exit 1
        """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        return fake
    }

    private func runner(config: String = "[Drive]\ntype = drive\n", password: (@Sendable (SMBShare) -> String?)?) throws -> TaskRunner {
        let file = sandbox.appendingPathComponent("rclone.conf")
        try config.write(to: file, atomically: true, encoding: .utf8)
        var configuration = RunnerConfiguration(rclonePath: try fakeRclone(), rcloneConfigPath: file.path,
                                                workDirectory: sandbox.appendingPathComponent("w"))
        configuration.smbPassword = password
        return TaskRunner(configuration: configuration)
    }

    private func task() throws -> SyncTask {
        SyncTask(name: "NAS → Drive", source: .network(url: "smb://sylvain.masson@10.92.7.3/03_ARCHIVES_GLOBALES", mountPath: try folder("s")),
                 destination: .cloud(remote: "Drive", path: "BACKUP"))
    }

    func testTheKeychainPasswordRecoversTheFilesWithoutAnyConnection() async throws {
        let asked = Locked<[SMBShare]>([])
        let result = try await runner(password: { share in asked.update { $0.append(share) }; return "secret du NAS" }).run(try task())
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(asked.get().map(\.host), ["10.92.7.3"])
        XCTAssertEqual(asked.get().first?.user, "sylvain.masson")
        let args = try String(contentsOfFile: sandbox.appendingPathComponent("recovery-args").path, encoding: .utf8)
        XCTAssertTrue(args.contains(":smb,host=10.92.7.3,user=sylvain.masson:03_ARCHIVES_GLOBALES\n"), args)
        XCTAssertFalse(args.contains("secret"), "jamais dans les arguments")
        let env = try String(contentsOfFile: sandbox.appendingPathComponent("recovery-env").path, encoding: .utf8)
        XCTAssertFalse(env.isEmpty)
        XCTAssertNotEqual(env, "secret du NAS", "chiffré à la façon de rclone")
    }

    func testAConnectionSetUpByHandComesFirst() async throws {
        let config = "[NAS]\ntype = smb\nhost = 10.92.7.3\nuser = sylvain.masson\npass = x\n"
        let asked = Locked(0)
        let result = try await runner(config: config, password: { _ in asked.update { $0 += 1 }; return "secret" }).run(try task())
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(asked.get(), 0, "le trousseau n'est pas consulté")
        let args = try String(contentsOfFile: sandbox.appendingPathComponent("recovery-args").path, encoding: .utf8)
        XCTAssertTrue(args.contains("NAS:03_ARCHIVES_GLOBALES\n"), args)
    }

    func testWithoutThePasswordTheMessageSaysWhatToAllow() async throws {
        let result = try await runner(password: { _ in nil }).run(try task())
        XCTAssertEqual(result.status, .failed)
        let message = result.summary.message ?? ""
        XCTAssertTrue(message.contains("trousseau"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("recovery-args").path))
    }
}

final class KeychainCache1812Tests: XCTestCase {
    private let share = SMBShare(host: "10.92.7.3", user: "sylvain.masson", share: "03", subpath: "")

    /// La question de macOS peut rester sans réponse (la nuit) : la copie n'attend pas indéfiniment.
    func testAnUnansweredKeychainQuestionDoesNotBlockTheCopy() {
        let source = CachedSMBPassword(timeout: 0.2, lookup: { _ in Thread.sleep(forTimeInterval: 2); return "tard" })
        let started = Date()
        XCTAssertNil(source.password(for: share))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    /// Une réponse est retenue : macOS ne repose pas la question à chaque copie ; un refus est retenu quelques heures.
    func testTheAnswerIsRememberedPerNAS() {
        let calls = Locked(0)
        var now = Date(timeIntervalSince1970: 0)
        let found = CachedSMBPassword(lookup: { _ in calls.update { $0 += 1 }; return "pw" }, now: { now })
        XCTAssertEqual(found.password(for: share), "pw")
        XCTAssertEqual(found.password(for: share), "pw")
        XCTAssertEqual(calls.get(), 1)
        let refused = CachedSMBPassword(lookup: { _ in calls.update { $0 += 1 }; return nil }, now: { now })
        XCTAssertNil(refused.password(for: share))
        XCTAssertNil(refused.password(for: share))
        XCTAssertEqual(calls.get(), 2)
        now = now.addingTimeInterval(CachedSMBPassword.refusalMemory + 1)
        XCTAssertNil(refused.password(for: share))
        XCTAssertEqual(calls.get(), 3, "redemandé après quelques heures")
    }
}
