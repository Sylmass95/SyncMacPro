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
    /// launchd connaît encore le job de l'agent (il peut le garder après `unregister`, avec son ancienne signature).
    func isJobLoaded() -> Bool
    /// launchd fait tourner l'agent.
    func isAgentRunning() -> Bool
}

public extension ServiceControlling {
    func isJobLoaded() -> Bool { status() == .enabled }
    func isAgentRunning() -> Bool { status() == .enabled }
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

    public func isJobLoaded() -> Bool { launchdDescription() != nil }

    public func isAgentRunning() -> Bool { launchdDescription()?.contains("\tstate = running") == true }

    /// `launchctl print gui/<uid>/<label>` ; `nil` si launchd ne connaît pas le job.
    private func launchdDescription() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(AgentIdentifiers.launchdLabel)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
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
            // Essais réels 1.2.1 → 1.2.2 et 1.2.2 → 1.2.3 : juste après le remplacement de l'app, le premier
            // réenregistrement donnait un job que launchd refusait de lancer (« spawn failed », code 78, « needs LWCR
            // update ») ; un second le réparait. On attend donc que launchd ne connaisse plus l'ancien job, on vérifie
            // que l'agent tourne vraiment (15 s au plus), et sinon on recommence une fois en attendant plus longtemps.
            for attempt in 0..<2 {
                try service.unregister()
                var polls = 0
                while (service.status() == .enabled || service.isJobLoaded()) && polls < 75 {   // 15 s au plus
                    polls += 1
                    await pause(200_000_000)
                }
                await pause(attempt == 0 ? 1_000_000_000 : 3_000_000_000)
                try service.register()
                var running = false
                for _ in 0..<60 {
                    if service.isAgentRunning() { running = true; break }
                    await pause(250_000_000)
                }
                if running { break }
            }
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
