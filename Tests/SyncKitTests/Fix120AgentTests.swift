import XCTest
@testable import SyncKit

/// Constats de la campagne de tests réels sur la 1.1.1.
final class Fix120AgentTests: XCTestCase {
    // C3 : une vérification qui trouve des différences n'est pas une panne passagère : pas de relance automatique.
    func testFailedVerifyIsNotRetried() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.status.set(.failed)
        h.factory.retryable.set(false)   // des différences trouvées (1.2.2 : une vérification impossible est retentée)
        let check = makeTask("Vérif", schedule: .manual, mode: .verify)
        let copy = makeTask("Copie", schedule: .manual)
        try h.save([check, copy])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(check.id)
        await core.waitForIdle()
        h.factory.retryable.set(true)
        try await core.runNow(copy.id)
        await core.waitForIdle()
        let infos = await core.status().tasks
        XCTAssertNil(infos.first { $0.name == "Vérif" }?.nextDue, "pas de nouvelle tentative pour une vérification")
        XCTAssertNotNil(infos.first { $0.name == "Copie" }?.nextDue, "une copie en échec est retentée")
    }

    // C5 : supprimer une tâche supprime son dossier de travail (état de bisync, liens courts).
    func testRemovingATaskRemovesItsWorkFiles() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let work = h.directory.appendingPathComponent("work")
        h.configuration.workDirectory = work
        let task = makeTask("Bidir", schedule: .manual, mode: .bidirectional)
        try h.save([task])
        let state = work.appendingPathComponent("bisync/\(task.id.uuidString)")
        let links = work.appendingPathComponent("bl/\(task.id.uuidString.prefix(12))")
        for folder in [state, links] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let core = h.makeCore()
        await core.start()
        try await core.removeTask(task.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: links.path))
    }

    // Un binaire qui ne rend pas la main ne bloque plus le démarrage : la vérification abandonne au bout du délai.
    func testHangingBinaryIsRejectedInTime() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("rclone")
        try "#!/bin/sh\nsleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let started = Date()
        XCTAssertNil(BinaryLocator.firstLine(of: fake.path, arguments: ["version"], timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
