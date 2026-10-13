import Foundation
import Observation
import ServiceManagement
import SyncKit

public enum AgentInstallState: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    /// Le plist de l'agent est absent du bundle (l'app n'est pas lancée depuis SyncMacPro.app).
    case notFound
    case unknown
}

public protocol ServiceControlling: Sendable {
    func status() -> AgentInstallState
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// Enregistrement de l'agent de l'app par `SMAppService`.
public struct SystemAgentService: ServiceControlling {
    public init() {}

    private var service: SMAppService {
        SMAppService.agent(plistName: "\(AgentIdentifiers.launchdLabel).plist")
    }

    public func status() -> AgentInstallState {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
@Observable
public final class AgentInstaller {
    public private(set) var state: AgentInstallState
    public var errorMessage: String?

    @ObservationIgnored private let service: ServiceControlling

    public init(service: ServiceControlling = SystemAgentService()) {
        self.service = service
        state = service.status()
    }

    public func refresh() { state = service.status() }

    public func install() {
        errorMessage = nil
        if service.status() != .enabled {
            do { try service.register() } catch { errorMessage = Self.describe(error) }
        }
        refresh()
        if state == .requiresApproval { service.openSystemSettings() }
    }

    public func uninstall() {
        errorMessage = nil
        do { try service.unregister() } catch { errorMessage = Self.describe(error) }
        refresh()
    }

    public func openSettings() { service.openSystemSettings() }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: ouvrir à la connexion

public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public struct SystemLoginItem: LoginItemControlling {
    public init() {}

    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
@Observable
public final class LoginItemModel {
    public private(set) var isEnabled: Bool
    public var errorMessage: String?

    @ObservationIgnored private let control: LoginItemControlling

    public init(control: LoginItemControlling = SystemLoginItem()) {
        self.control = control
        isEnabled = control.isEnabled
    }

    public func refresh() { isEnabled = control.isEnabled }

    /// En cas d'échec, l'interrupteur revient à la vraie valeur et le message s'affiche.
    public func set(_ enabled: Bool) {
        errorMessage = nil
        do { try control.setEnabled(enabled) } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        refresh()
    }
}
