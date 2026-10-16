import XCTest
import SwiftUI
import SyncKit
@testable import SyncMacProUI

/// Sous-projet 8 : les mises à jour dans Réglages et sur le tableau de bord.
@MainActor
final class UpdateUITests: XCTestCase {
    let fr = UpdateText(localizer: Localizer(language: "fr"))
    let en = UpdateText(localizer: Localizer(language: "en"))

    func testStateTexts() {
        XCTAssertEqual(fr.state(.idle), "")
        XCTAssertEqual(fr.state(.checking), "Vérification…")
        XCTAssertEqual(fr.state(.upToDate), "SyncMacPro est à jour.")
        XCTAssertEqual(fr.state(.downloading("1.6.1")), "Téléchargement de la version 1.6.1…")
        XCTAssertEqual(fr.state(.ready("1.6.1")), "Version 1.6.1 prête à être installée.")
        XCTAssertEqual(fr.state(.installing), "Installation… SyncMacPro va redémarrer.")
        XCTAssertEqual(fr.state(.failed("réseau")), "Mise à jour impossible : réseau")
        XCTAssertEqual(en.state(.ready("1.6.1")), "Version 1.6.1 is ready to install.")
        XCTAssertEqual(en.state(.downloading("1.6.1")), "Downloading version 1.6.1…")
    }

    func testBannerTexts() {
        XCTAssertEqual(fr.banner(UpdateBannerInfo(version: "1.6.1", waitingForCopies: false, install: {})), "SyncMacPro 1.6.1 est prête à être installée.")
        XCTAssertEqual(fr.banner(UpdateBannerInfo(version: "1.6.1", waitingForCopies: true, install: nil)),
                       "SyncMacPro 1.6.1 s’installera à la fin des copies en cours.")
        XCTAssertEqual(en.banner(UpdateBannerInfo(version: "1.6.1", waitingForCopies: true, install: nil)),
                       "SyncMacPro 1.6.1 will install once the current copies finish.")
    }

    func testBannerOnlyWhenTheUserHasSomethingToKnow() {
        let driver = FakeUpdateDriver()
        let name = "maj-ui-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        let model = UpdateModel(driver: driver, defaults: store)
        model.agentActivity(idle: false)
        driver.send(.ready("1.6.1"))
        XCTAssertEqual(UpdateBannerInfo.make(model)?.waitingForCopies, true, "auto : elle attend les copies")
        model.autoInstall = false
        let manual = UpdateBannerInfo.make(model)
        XCTAssertEqual(manual?.waitingForCopies, false)
        manual?.install?()
        XCTAssertEqual(driver.installs, 1)
        XCTAssertNil(UpdateBannerInfo.make(UpdateModel(driver: FakeUpdateDriver(), defaults: store)), "rien de prêt : pas de bannière")
    }

    func testNewStringsExistInBothLanguages() {
        for key in ["update.autoInstall", "update.install", "update.unavailable", "update.done.title", "update.done.body",
                    "update.banner.ready", "update.banner.waiting"] {
            for language in ["fr", "en"] {
                XCTAssertNotEqual(Localizer(language: language).text(key), key, "\(language) : \(key)")
            }
        }
    }

    func testRenders() throws {
        let agent = FakeAgent()
        agent.setStatus(.success(makeStatus()))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        for (index, info) in [UpdateBannerInfo(version: "1.6.1", waitingForCopies: false, install: {}),
                              UpdateBannerInfo(version: "1.6.1", waitingForCopies: true, install: nil)].enumerated() {
            for scheme in [ColorScheme.light, .dark] {
                let view = DashboardBody(model: model, installState: .enabled, text: UIFixtures.french, onInstall: {}, update: info).glassThemed()
                assertNotBlank(try render(view, name: "dashboard-update-\(index)", size: CGSize(width: 760, height: 300), scheme: scheme))
            }
        }
        let driver = FakeUpdateDriver()
        let updates = UpdateModel(driver: driver, defaults: UserDefaults(suiteName: "maj-rendu-\(UUID().uuidString)")!)
        driver.send(.ready("1.6.1"))
        let settings = SettingsView(installer: AgentInstaller(service: UpdateStubService()), loginItem: LoginItemModel(control: UpdateStubLogin()),
                                    localizer: Localizer(language: "fr"), updates: updates)
        XCTAssertGreaterThan(try render(settings, name: "settings-update", size: CGSize(width: 520, height: 700), scheme: .light).width, 0)
        model.shutdown()
    }
}

extension UpdateUITests {
    // 1.6.2 : après une mise à jour, macOS peut redemander l'accès aux dossiers ; la notification le dit.
    func testUpdatedNotificationWarnsAboutFolderAccess() {
        XCTAssertTrue(Localizer(language: "fr").format("update.done.body", "1.6.2").contains("autoris"))
        XCTAssertTrue(Localizer(language: "en").format("update.done.body", "1.6.2").lowercased().contains("allow"))
    }
}

private struct UpdateStubService: ServiceControlling {
    func status() -> AgentInstallState { .enabled }
    func register() throws {}
    func unregister() throws {}
    func isJobLoaded() -> Bool { true }
    func isAgentRunning() -> Bool { true }
    func openSystemSettings() {}
}

private struct UpdateStubLogin: LoginItemControlling {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
}
