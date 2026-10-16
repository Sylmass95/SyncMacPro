import XCTest
@testable import SyncMacProUI

@MainActor
final class FakeUpdateDriver: UpdateDriving {
    var onEvent: ((UpdateEvent) -> Void)?
    var automaticallyChecks = true
    var started = 0, checks = 0, installs = 0
    func start() { started += 1 }
    func checkNow() { checks += 1 }
    func installNow() { installs += 1 }
    func send(_ event: UpdateEvent) { onEvent?(event) }
}

/// Sous-projet 8 : l'état de Sparkle vu par l'interface, et l'installation au bon moment.
@MainActor
final class UpdateModelSparkleTests: XCTestCase {
    /// `allDay` : installation permise à toute heure (les tests tournent à n'importe quelle heure de la journée).
    func defaults(allDay: Bool = true) -> UserDefaults {
        let name = "maj-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        if allDay {
            store.set(0, forKey: UpdateModel.installFromKey)
            store.set(24, forKey: UpdateModel.installUntilKey)
        }
        return store
    }

    func testEventsBecomeStates() {
        let driver = FakeUpdateDriver()
        let model = UpdateModel(driver: driver, defaults: defaults())
        XCTAssertTrue(model.isAvailable)
        for (event, state) in [(UpdateEvent.checking, UpdateState.checking), (.upToDate, .upToDate), (.downloading("1.6.1"), .downloading("1.6.1")),
                               (.failed("réseau"), .failed("réseau"))] {
            driver.send(event)
            XCTAssertEqual(model.state, state)
        }
        model.checkNow()
        XCTAssertEqual(driver.checks, 1)
    }

    func testReadyUpdateInstallsOnceWhenTheAgentIsIdle() {
        let driver = FakeUpdateDriver()
        let model = UpdateModel(driver: driver, defaults: defaults())
        model.agentActivity(idle: false)
        driver.send(.ready("1.6.1"))
        XCTAssertEqual(driver.installs, 0, "une copie tourne : on attend")
        XCTAssertTrue(model.waitingForCopies)
        model.agentActivity(idle: false)
        XCTAssertEqual(driver.installs, 0)
        model.agentActivity(idle: true)
        XCTAssertEqual(driver.installs, 1)
        XCTAssertEqual(model.state, .installing)
        model.agentActivity(idle: true)
        XCTAssertEqual(driver.installs, 1, "une seule installation")
    }

    func testWithoutAutoInstallTheUserDecides() {
        let driver = FakeUpdateDriver()
        let store = defaults()
        let model = UpdateModel(driver: driver, defaults: store)
        model.autoInstall = false
        model.agentActivity(idle: true)
        driver.send(.ready("1.6.1"))
        XCTAssertEqual(driver.installs, 0)
        XCTAssertEqual(model.readyVersion, "1.6.1")
        XCTAssertFalse(model.waitingForCopies)
        model.installNow()
        XCTAssertEqual(driver.installs, 1)
        XCTAssertFalse(UpdateModel(driver: FakeUpdateDriver(), defaults: store).autoInstall, "réglage gardé")
    }

    func testReEnablingAutoInstallInstallsAtTheNextIdleMoment() {
        let driver = FakeUpdateDriver()
        let model = UpdateModel(driver: driver, defaults: defaults())
        model.autoInstall = false
        model.agentActivity(idle: false)
        driver.send(.ready("1.6.1"))
        model.autoInstall = true
        XCTAssertEqual(driver.installs, 0)
        model.agentActivity(idle: true)
        XCTAssertEqual(driver.installs, 1)
    }

    func testCheckSettingReachesTheDriver() {
        let driver = FakeUpdateDriver()
        let store = defaults()
        store.set(false, forKey: UpdateModel.automaticKey)
        let model = UpdateModel(driver: driver, defaults: store)
        XCTAssertFalse(driver.automaticallyChecks)
        model.automatic = true
        XCTAssertTrue(driver.automaticallyChecks)
        model.start()
        XCTAssertEqual(driver.started, 1)
    }

    func testWithoutDriverNothingHappens() {
        let model = UpdateModel(driver: nil, defaults: defaults())
        XCTAssertFalse(model.isAvailable)
        model.checkNow(); model.installNow(); model.agentActivity(idle: true)
        XCTAssertEqual(model.state, .idle)
    }

    func testLaunchAnnouncesAnUpdateOnce() {
        let store = defaults()
        XCTAssertNil(UpdateModel.launchAnnouncement(current: "1.6.0 (200)", defaults: store), "première installation")
        XCTAssertEqual(UpdateModel.launchAnnouncement(current: "1.6.1 (205)", defaults: store), "1.6.1")
        XCTAssertNil(UpdateModel.launchAnnouncement(current: "1.6.1 (205)", defaults: store), "une seule fois")
    }

    // Relecture finale : l'état « au repos » pouvait dater de 30 s ; il est relu au moment d'installer.
    func testIdlenessIsReadAtInstallTime() {
        let driver = FakeUpdateDriver()
        var idle: Bool? = true
        let model = UpdateModel(driver: driver, defaults: defaults(), isIdle: { idle })
        model.agentActivity(idle: true)
        idle = false   // une copie vient de partir
        driver.send(.ready("1.6.1"))
        XCTAssertEqual(driver.installs, 0)
        idle = nil     // agent pas encore joint
        model.agentActivity(idle: true)
        XCTAssertEqual(driver.installs, 0)
        idle = true
        model.agentActivity(idle: true)
        XCTAssertEqual(driver.installs, 1)
    }

    // 1.6.4 : installation automatique en journée seulement (les demandes d'autorisation de macOS attendent quelqu'un).
    func testAutomaticInstallOnlyDuringTheDay() {
        let driver = FakeUpdateDriver()
        let store = defaults(allDay: false)
        var hour = 23
        let calendar = Calendar(identifier: .gregorian)
        let model = UpdateModel(driver: driver, defaults: store, now: {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
        })
        XCTAssertEqual(model.installFrom, 9)
        XCTAssertEqual(model.installUntil, 19)
        model.agentActivity(idle: true)
        driver.send(.ready("1.6.5"))
        XCTAssertEqual(driver.installs, 0, "la nuit : on attend la journée")
        XCTAssertTrue(model.waitingForDaytime)
        hour = 9
        model.agentActivity(idle: true)
        XCTAssertEqual(driver.installs, 1)
    }

    func testInstallHoursAreKept() {
        let store = defaults(allDay: false)
        let model = UpdateModel(driver: FakeUpdateDriver(), defaults: store)
        model.installFrom = 7
        model.installUntil = 22
        let again = UpdateModel(driver: FakeUpdateDriver(), defaults: store)
        XCTAssertEqual(again.installFrom, 7)
        XCTAssertEqual(again.installUntil, 22)
    }
}
