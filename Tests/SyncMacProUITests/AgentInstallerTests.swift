import XCTest
@testable import SyncMacProUI

private final class FakeService: ServiceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AgentInstallState
    var afterRegister: AgentInstallState = .enabled
    var registerError: Error?
    private(set) var registers = 0, unregisters = 0, settingsOpened = 0

    init(_ state: AgentInstallState) { current = state }

    func status() -> AgentInstallState { lock.lock(); defer { lock.unlock() }; return current }

    func register() throws {
        lock.lock(); defer { lock.unlock() }
        registers += 1
        if let registerError { throw registerError }
        current = afterRegister
    }

    func unregister() throws {
        lock.lock(); defer { lock.unlock() }
        unregisters += 1
        current = .notRegistered
    }

    func openSystemSettings() { lock.lock(); settingsOpened += 1; lock.unlock() }
}

private final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    var isEnabled = false
    var error: Error?
    func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
        isEnabled = enabled
    }
}

@MainActor
final class AgentInstallerTests: XCTestCase {
    func testInstallRegistersAndBecomesEnabled() {
        let service = FakeService(.notRegistered)
        let installer = AgentInstaller(service: service)
        XCTAssertEqual(installer.state, .notRegistered)
        installer.install()
        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(installer.state, .enabled)
        XCTAssertEqual(service.settingsOpened, 0)
        XCTAssertNil(installer.errorMessage)
    }

    func testInstallThatNeedsApprovalOpensSystemSettings() {
        let service = FakeService(.notRegistered)
        service.afterRegister = .requiresApproval
        let installer = AgentInstaller(service: service)
        installer.install()
        XCTAssertEqual(installer.state, .requiresApproval)
        XCTAssertEqual(service.settingsOpened, 1)
    }

    func testInstallOnAnEnabledAgentDoesNothing() {
        let service = FakeService(.enabled)
        let installer = AgentInstaller(service: service)
        installer.install()
        XCTAssertEqual(service.registers, 0)
    }

    func testInstallFailureIsReported() {
        struct Boom: LocalizedError { var errorDescription: String? { "boum" } }
        let service = FakeService(.notRegistered)
        service.registerError = Boom()
        let installer = AgentInstaller(service: service)
        installer.install()
        XCTAssertEqual(installer.errorMessage, "boum")
        XCTAssertEqual(installer.state, .notRegistered)
    }

    func testUninstallUnregisters() {
        let service = FakeService(.enabled)
        let installer = AgentInstaller(service: service)
        installer.uninstall()
        XCTAssertEqual(service.unregisters, 1)
        XCTAssertEqual(installer.state, .notRegistered)
    }

    func testRefreshReadsTheCurrentState() {
        let service = FakeService(.notFound)
        let installer = AgentInstaller(service: service)
        XCTAssertEqual(installer.state, .notFound)
    }

    func testLoginItemToggle() {
        let control = FakeLoginItem()
        let model = LoginItemModel(control: control)
        XCTAssertFalse(model.isEnabled)
        model.set(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(control.isEnabled)
        model.set(false)
        XCTAssertFalse(model.isEnabled)
    }

    func testLoginItemFailureKeepsTheRealValueAndReports() {
        struct Boom: LocalizedError { var errorDescription: String? { "refusé" } }
        let control = FakeLoginItem()
        control.error = Boom()
        let model = LoginItemModel(control: control)
        model.set(true)
        XCTAssertFalse(model.isEnabled, "l'interrupteur revient à la vraie valeur")
        XCTAssertEqual(model.errorMessage, "refusé")
    }
}
