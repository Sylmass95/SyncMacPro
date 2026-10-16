import XCTest
@testable import SyncKit

/// 1.6.4 : après une mise à jour, macOS ne reconnaît plus les autorisations de SyncMacPro (signature ad hoc nouvelle) ;
/// les erreurs le disent clairement, et l'agent redemande l'accès à tous les dossiers des tâches.
final class PrivacyAccess164Tests: XCTestCase {
    func testOperationNotPermittedOnAProtectedPlaceExplainsTheSetting() {
        let home = NSHomeDirectory()
        let network = EngineErrorText.summary(errors: [
            #"rsync: [sender] opendir "/Volumes/03_ARCHIVES_GLOBALES/." failed: Operation not permitted (1)"#], total: 1) ?? ""
        XCTAssertTrue(network.contains("Confidentialité et sécurité"), network)
        XCTAssertTrue(network.contains("Volumes de réseau"), network)
        let desktop = EngineErrorText.summary(errors: [
            "failed to open source object: open \(home)/Desktop/PERSO-FILES/a.txt: operation not permitted"], total: 1) ?? ""
        XCTAssertTrue(desktop.contains("« Dossier Bureau »"), desktop)
        let plain = EngineErrorText.summary(errors: ["rsync: send_files failed to open \"/srv/a\": Permission denied (13)"], total: 1) ?? ""
        XCTAssertTrue(plain.hasPrefix("Accès refusé."), "droits Unix ordinaires : message inchangé — \(plain)")
    }

    func testCheckAccessTouchesEveryFolderOfTheEnabledTasks() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let touched = Locked<[String]>([])
        h.configuration.touchAccess = { folders in touched.update { $0.append(contentsOf: folders) } }
        let a = SyncTask(name: "A", source: .local(path: NSTemporaryDirectory()), destination: .cloud(remote: "drive", path: "x"))
        var b = SyncTask(name: "B", source: .network(url: "smb://nas/p", mountPath: "/tmp"), destination: .local(path: NSTemporaryDirectory()))
        var off = SyncTask(name: "C", source: .local(path: "/private/var"), destination: .local(path: "/private/etc"))
        off.isEnabled = false
        b.name = "B"
        try h.save([a, b, off])
        let core = h.makeCore()
        await core.start()
        await core.checkAccess()
        let folders = Set(touched.get())
        XCTAssertTrue(folders.contains(VolumeLookup.canonical(NSTemporaryDirectory())))
        XCTAssertTrue(folders.contains(VolumeLookup.canonical("/tmp")))
        XCTAssertFalse(folders.contains(VolumeLookup.canonical("/private/var")), "tâche désactivée")
        XCTAssertEqual(touched.get().count, folders.count, "chaque dossier une seule fois")
    }
}
