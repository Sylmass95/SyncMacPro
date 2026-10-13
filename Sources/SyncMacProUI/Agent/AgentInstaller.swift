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

    /// Version de l'app qui a enregistré l'agent (clé de `UserDefaults`).
    public static let registeredBuildKey = "agentRegisteredBuild"

    public func install(currentBuild: String = AppInfo.version(), defaults: UserDefaults = .standard) {
        errorMessage = nil
        if service.status() != .enabled {
            do { try service.register() } catch { errorMessage = Self.describe(error) }
        }
        refresh()
        if state == .enabled { defaults.set(currentBuild, forKey: Self.registeredBuildKey) }
        if state == .requiresApproval { service.openSystemSettings() }
    }

    public typealias Pause = @Sendable (UInt64) async -> Void
    public nonisolated static let realPause: Pause = { try? await Task.sleep(nanoseconds: $0) }
    @ObservationIgnored private var repaired = false

    /// Après une mise à jour (app remplacée), launchd refuse de lancer l'agent enregistré avec l'ancienne signature ad hoc
    /// (code 78, ou OS_REASON_CODESIGNING) : on le désenregistre, on attend que macOS l'ait retiré, puis on le réenregistre.
    /// Rien si l'agent n'est pas installé ou hors bundle (« dev »).
    public func reRegisterAfterUpdate(
        currentBuild: String = AppInfo.version(), defaults: UserDefaults = .standard, pause: Pause = AgentInstaller.realPause
    ) async {
        guard currentBuild != "dev", service.status() == .enabled,
              defaults.string(forKey: Self.registeredBuildKey) != currentBuild else { return }
        await reRegister(currentBuild: currentBuild, defaults: defaults, pause: pause)
    }

    /// Un agent déclaré installé qui ne répond jamais : on le réenregistre, une seule fois par lancement.
    /// Vrai si une réparation a été tentée.
    @discardableResult
    public func repairIfStuck(
        currentBuild: String = AppInfo.version(), defaults: UserDefaults = .standard, pause: Pause = AgentInstaller.realPause
    ) async -> Bool {
        guard !repaired, currentBuild != "dev", service.status() == .enabled else { return false }
        repaired = true
        await reRegister(currentBuild: currentBuild, defaults: defaults, pause: pause)
        return true
    }

    private func reRegister(currentBuild: String, defaults: UserDefaults, pause: Pause) async {
        errorMessage = nil
        do {
            try service.unregister()
            // macOS retire l'agent en différé : on attend (5 s au plus) qu'il ne soit plus déclaré, puis une seconde
            // pour que launchd décharge l'ancien job. Réenregistrer aussitôt le laissait chargé avec l'ancienne signature.
            var polls = 0
            while service.status() == .enabled && polls < 25 {
                polls += 1
                await pause(200_000_000)
            }
            await pause(1_000_000_000)
            try service.register()
            defaults.set(currentBuild, forKey: Self.registeredBuildKey)
        } catch {
            errorMessage = Self.describe(error)
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
