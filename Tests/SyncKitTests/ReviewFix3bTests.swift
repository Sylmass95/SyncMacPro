import XCTest
@testable import SyncKit

/// Corrections issues de la relecture finale de la branche 3b.
final class ReviewFix3bValidatorTests: XCTestCase {
    func problems(_ source: Endpoint, _ destination: Endpoint, mode: SyncMode = .copy, archive: String = "_ARCHIVE") -> [TaskProblem] {
        var task = SyncTask(name: "t", source: source, destination: destination, mode: mode)
        task.options.archiveFolder = archive
        return TaskValidator.problems(in: task)
    }

    // I2 : la racine du disque, d'un côté comme de l'autre.
    func testDiskRootIsNestedWithEverything() {
        XCTAssertEqual(problems(.local(path: "/"), .local(path: "/Volumes/Backup")), [.nestedFolders])
        XCTAssertEqual(problems(.local(path: "/Users/moi"), .local(path: "/"), mode: .mirror), [.nestedFolders])
    }

    // I3 : casse, liens symboliques, chemins relatifs, racine d'un service en ligne.
    func testCaseVariantsAreTheSameFolderOnAPFS() {
        XCTAssertEqual(problems(.local(path: "/Users/moi/Photos"), .local(path: "/Users/moi/photos/sauvegarde")), [.nestedFolders])
        XCTAssertEqual(problems(.local(path: "/Users/moi/Photos"), .local(path: "/users/MOI/photos")), [.sameSourceAndDestination])
    }

    func testSymlinksAreResolved() {
        // /tmp est un lien vers /private/tmp.
        XCTAssertEqual(problems(.local(path: "/tmp/a"), .local(path: "/private/tmp/a/b")), [.nestedFolders])
    }

    func testRelativePathsAreRefused() {
        XCTAssertEqual(problems(.local(path: "Photos"), .local(path: "/b")), [.relativePath])
        XCTAssertEqual(problems(.local(path: "/a"), .network(url: "smb://x", mountPath: "NAS/a")), [.relativePath])
    }

    func testCloudRootIsNested() {
        XCTAssertEqual(problems(.cloud(remote: "drive", path: ""), .cloud(remote: "drive", path: "x")), [.nestedFolders])
        XCTAssertEqual(problems(.cloud(remote: "drive", path: "/a"), .cloud(remote: "drive", path: "a")), [.sameSourceAndDestination])
        XCTAssertEqual(problems(.cloud(remote: "drive", path: "a"), .cloud(remote: "autre", path: "a")), [])
    }

    // I4 : le dossier d'archive reste un nom simple, dans la destination.
    func testArchiveFolderMustBeASimpleName() {
        for bad in ["", "  ", "..", ".", "a/b", "../x"] {
            XCTAssertEqual(problems(.local(path: "/a"), .local(path: "/b"), mode: .mirror, archive: bad), [.invalidArchiveFolder], bad)
            XCTAssertEqual(problems(.local(path: "/a"), .cloud(remote: "d", path: "b"), mode: .versioned, archive: bad), [.invalidArchiveFolder], bad)
        }
        XCTAssertEqual(problems(.local(path: "/a"), .local(path: "/b"), mode: .mirror, archive: "_OLD"), [])
        XCTAssertEqual(problems(.local(path: "/a"), .local(path: "/b"), mode: .copy, archive: ""), [], "inutilisé hors miroir et versions")
    }
}

final class ReviewFix3bAgentTests: XCTestCase {
    // I1 : modifier une tâche bloquée annule la validation en attente.
    func testEditingABlockedTaskCancelsThePendingApproval() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.status.set(.blocked)
        var task = makeTask(schedule: .manual, mode: .mirror)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        let blocked = await core.status().tasks[0].state
        XCTAssertEqual(blocked, .awaitingApproval)
        task.source = .local(path: "/autre-source")
        try await core.saveTask(task)
        let state = await core.status().tasks[0].state
        XCTAssertNotEqual(state, .awaitingApproval, "la tâche modifiée doit être replanifiée, pas validée telle quelle")
        do {
            try await core.approveDeletion(task.id)
            XCTFail("plus rien à valider")
        } catch {
            XCTAssertEqual(error as? AgentError, .notAwaitingApproval)
        }
    }

    // I8 : l'arrêt de l'agent arrête les simulations ; leur nombre est borné.
    func testShutdownStopsSimulations() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let pending = Task { try await core.simulate(makeTask(schedule: .manual)) }
        _ = await eventually { h.factory.runners.get().count == 1 }
        await core.shutdown()
        let result = try await pending.value
        XCTAssertEqual(result.status, .stopped)
    }

    func testAtMostTwoSimulationsAtOnce() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let core = h.makeCore()
        await core.start()
        let first = Task { try await core.simulate(makeTask("a", schedule: .manual)) }
        let second = Task { try await core.simulate(makeTask("b", schedule: .manual)) }
        _ = await eventually { h.factory.runners.get().count == 2 }
        do {
            _ = try await core.simulate(makeTask("c", schedule: .manual))
            XCTFail("une troisième simulation doit être refusée")
        } catch {
            XCTAssertEqual(error as? AgentError, .tooManySimulations)
        }
        h.factory.runners.get().forEach { $0.release() }
        _ = try await first.value
        _ = try await second.value
    }
}

final class ReviewFix3bLogTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("logfix-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    // I5 : les lignes de progression ne remplissent pas le journal ; la ligne de fin est toujours écrite.
    func testProgressLinesAreNotLogged() throws {
        let url = folder.appendingPathComponent("p.log")
        let writer = RunLogWriter(url: url, now: { Date(timeIntervalSince1970: 0) })
        writer.append(">f+++++++++|photo.jpg")
        writer.append("      3,145,728  42%   12.50MB/s    0:00:03")
        writer.append("          3 100%    0.00kB/s    0:00:00 (xfr#1, to-chk=2/4)")
        writer.append(#"{"level":"info","msg":"x","stats":{"bytes":1}}"#)
        writer.append("rsync error: some files could not be transferred (code 23)")
        writer.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("photo.jpg"))
        XCTAssertTrue(text.contains("code 23"))
        XCTAssertFalse(text.contains("42%"))
        XCTAssertFalse(text.contains("to-chk"))
        XCTAssertFalse(text.contains("\"stats\""))
    }

    func testFinalLineIsWrittenEvenAfterTheCap() throws {
        let url = folder.appendingPathComponent("f.log")
        let writer = RunLogWriter(url: url, limit: 80, now: { Date(timeIntervalSince1970: 0) })
        for index in 0..<20 { writer.append("fichier numéro \(index)") }
        writer.append("Fin : succeeded", force: true)
        writer.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("journal tronqué"))
        XCTAssertTrue(text.hasSuffix("Fin : succeeded\n"))
    }

    // I6 : écrire après la fermeture ne plante pas.
    func testWritingAfterCloseIsIgnored() throws {
        let url = folder.appendingPathComponent("c.log")
        let writer = RunLogWriter(url: url)
        writer.append("avant")
        writer.close()
        writer.append("après")
        writer.append("après", force: true)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("après"))
    }
}
