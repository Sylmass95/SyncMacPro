import XCTest
@testable import SyncKit

/// 1.8.13 : la question du trousseau arrive au démarrage de l'agent et quand une tâche vers un NAS change, quand
/// l'utilisateur est là ; plus au milieu d'une copie de nuit.
final class KeychainStart1813Tests: XCTestCase {
    private func nasTask(_ name: String, share: String = "03_ARCHIVES_GLOBALES", host: String = "10.92.7.3") -> SyncTask {
        SyncTask(name: name, source: .network(url: "smb://sylvain.masson@\(host)/\(share)", mountPath: "/Volumes/\(share)"),
                 destination: .cloud(remote: "Drive", path: name))
    }

    func testTheAgentAsksForTheNASPasswordsWhenItStartsAndWhenTasksChange() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 1_000_000))
        let asked = Locked<[[SMBShare]]>([])
        h.configuration.prepareSMBPasswords = { shares in asked.update { $0.append(shares) } }
        try h.save([nasTask("A"), nasTask("B"), nasTask("P", share: "01_PROJETS_ACTIFS"), SyncTask(name: "L", source: .local(path: "/a"), destination: .local(path: "/b"))])
        let core = h.makeCore()
        await core.start()
        XCTAssertEqual(asked.get().last?.map(\.host), ["10.92.7.3"], "un NAS et un compte, une question, même pour trois tâches")
        try await core.saveTask(nasTask("Q", share: "Documents", host: "qnap.local"))
        XCTAssertEqual(asked.get().last?.map(\.host), ["10.92.7.3", "qnap.local"])
    }
}

final class KeychainCache1813Tests: XCTestCase {
    private let share = SMBShare(host: "10.92.7.3", user: "sylvain.masson", share: "03", subpath: "")

    /// Question restée sans réponse : pas un refus ; la réponse donnée plus tard sert à la copie suivante, sans
    /// nouvelle question entre-temps.
    func testAnUnansweredQuestionIsNeitherRepeatedNorTakenAsARefusal() {
        let answer = DispatchSemaphore(value: 0)
        let calls = Locked(0)
        let source = CachedSMBPassword(timeout: 0.1, lookup: { _ in calls.update { $0 += 1 }; answer.wait(); return "pw" })
        source.prefetch(share)
        XCTAssertNil(source.password(for: share), "question encore affichée")
        XCTAssertNil(source.password(for: share))
        XCTAssertEqual(calls.get(), 1, "une seule question")
        answer.signal()
        let deadline = Date().addingTimeInterval(2)
        while source.password(for: share) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(source.password(for: share), "pw")
        XCTAssertEqual(calls.get(), 1)
    }

    func testAPrefetchedPasswordIsReadyForTheCopy() {
        let calls = Locked(0)
        let source = CachedSMBPassword(lookup: { _ in calls.update { $0 += 1 }; return "pw" })
        source.prefetch(share)
        source.prefetch(share)
        let deadline = Date().addingTimeInterval(2)
        while calls.get() == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(source.password(for: share), "pw")
        XCTAssertEqual(calls.get(), 1)
    }
}
