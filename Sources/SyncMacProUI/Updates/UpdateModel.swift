import Foundation
import Observation

public enum UpdateState: Equatable, Sendable {
    case idle, checking, upToDate
    case downloading(String)
    case ready(String)
    case installing
    case failed(String)
}

/// État des mises à jour pour l'interface ; installe une mise à jour prête quand l'agent est au repos.
@MainActor
@Observable
public final class UpdateModel {
    public private(set) var state: UpdateState = .idle
    /// Vérifier automatiquement (une fois par jour au plus).
    public var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: Self.automaticKey)
            driver?.automaticallyChecks = automatic
        }
    }
    /// Plage horaire de l'installation automatique (heures, début inclus, fin exclue) : les demandes d'autorisation
    /// de macOS qui suivent une mise à jour attendent quelqu'un devant le Mac.
    public var installFrom: Int {
        didSet { defaults.set(installFrom, forKey: Self.installFromKey); considerInstall() }
    }
    public var installUntil: Int {
        didSet { defaults.set(installUntil, forKey: Self.installUntilKey); considerInstall() }
    }
    /// Installer automatiquement dès qu'aucune copie ne tourne.
    public var autoInstall: Bool {
        didSet {
            defaults.set(autoInstall, forKey: Self.autoInstallKey)
            considerInstall()
        }
    }
    @ObservationIgnored let driver: UpdateDriving?
    @ObservationIgnored let defaults: UserDefaults
    /// Inconnu tant que l'app ne l'a pas dit : on n'installe pas à l'aveugle.
    @ObservationIgnored private var agentIdle = false
    @ObservationIgnored private var installRequested = false
    /// État de l'agent relu au moment d'installer (`nil` : pas encore joint) ; sans lui, le dernier `agentActivity`.
    @ObservationIgnored private let isIdle: (@MainActor () -> Bool?)?
    @ObservationIgnored private let now: () -> Date

    static let automaticKey = "checkUpdates"
    static let autoInstallKey = "installUpdates"
    static let lastLaunchKey = "lastLaunchedVersion"
    static let installFromKey = "installFromHour"
    static let installUntilKey = "installUntilHour"

    public init(
        driver: UpdateDriving?, defaults: UserDefaults = .standard, isIdle: (@MainActor () -> Bool?)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.driver = driver
        self.defaults = defaults
        self.isIdle = isIdle
        self.now = now
        installFrom = defaults.object(forKey: Self.installFromKey) as? Int ?? 9
        installUntil = defaults.object(forKey: Self.installUntilKey) as? Int ?? 19
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        autoInstall = defaults.object(forKey: Self.autoInstallKey) as? Bool ?? true
        driver?.automaticallyChecks = automatic
        driver?.onEvent = { [weak self] event in self?.receive(event) }
    }

    /// Faux hors de l'app installée (« dev », `swift run`) : rien n'est vérifié.
    public var isAvailable: Bool { driver != nil }

    public var readyVersion: String? {
        if case .ready(let version) = state { return version }
        return nil
    }

    /// Prête, installation automatique, mais une copie tourne : elle s'installera à la fin.
    public var waitingForCopies: Bool { readyVersion != nil && autoInstall && !agentIdle && inInstallHours }

    /// Prête, installation automatique, mais hors de la plage horaire : elle s'installera en journée.
    public var waitingForDaytime: Bool { readyVersion != nil && autoInstall && !inInstallHours }

    var inInstallHours: Bool {
        let hour = Calendar.current.component(.hour, from: now())
        return installFrom <= installUntil ? (hour >= installFrom && hour < installUntil) : (hour >= installFrom || hour < installUntil)
    }

    public func start() { driver?.start() }
    public func checkNow() { driver?.checkNow() }

    public func installNow() {
        guard readyVersion != nil, !installRequested, let driver else { return }
        installRequested = true
        state = .installing
        driver.installNow()
    }

    /// Appelée régulièrement par l'app avec l'état de l'agent.
    public func agentActivity(idle: Bool) {
        agentIdle = idle
        considerInstall()
    }

    func receive(_ event: UpdateEvent) {
        switch event {
        case .checking: state = .checking
        case .upToDate: state = .upToDate
        case .downloading(let version): state = .downloading(version)
        case .ready(let version):
            state = .ready(version)
            installRequested = false
            considerInstall()
        case .installing: state = .installing
        case .failed(let message):
            state = .failed(message)
            installRequested = false
        }
    }

    private func considerInstall() {
        // Relu maintenant : une copie a pu partir depuis le dernier `agentActivity` (toutes les 30 s).
        if let isIdle { agentIdle = isIdle() ?? false }
        if UpdatePolicy.shouldInstall(ready: readyVersion != nil, autoInstall: autoInstall, idle: agentIdle), inInstallHours { installNow() }
    }

    /// Au lancement : la version à annoncer (« SyncMacPro a été mis à jour en … »), une seule fois.
    public static func launchAnnouncement(current: String, defaults: UserDefaults = .standard) -> String? {
        let previous = defaults.string(forKey: lastLaunchKey)
        defaults.set(current, forKey: lastLaunchKey)
        guard UpdatePolicy.shouldNotifyUpdated(previous: previous, current: current) else { return nil }
        return SemanticVersion(current)?.description
    }
}
