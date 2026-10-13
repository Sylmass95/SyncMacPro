import Foundation
import Observation

public enum UpdateState: Equatable, Sendable {
    case idle, checking, upToDate
    case available(ReleaseInfo)
    case failed(String)
}

@MainActor
@Observable
public final class UpdateModel {
    public private(set) var state: UpdateState = .idle
    public var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Self.automaticKey) }
    }
    @ObservationIgnored let checker: UpdateChecker
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var running: Task<UpdateCheckResult, Never>?
    static let automaticKey = "checkUpdates"
    static let lastCheckKey = "lastUpdateCheck"

    public init(checker: UpdateChecker, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.checker = checker
        self.defaults = defaults
        self.now = now
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    public var available: ReleaseInfo? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// Au lancement : au plus une fois par jour, si l'utilisateur le veut.
    public func checkIfDue() async {
        guard automatic, UpdateChecker.isDue(lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date, now: now()) else { return }
        await checkNow()
    }

    /// Une seule vérification à la fois : une seconde demande attend la première.
    public func checkNow() async {
        if let running {
            _ = await running.value
            return
        }
        state = .checking
        let checker = self.checker
        let task = Task { await checker.check() }
        running = task
        let result = await task.value
        running = nil
        defaults.set(now(), forKey: Self.lastCheckKey)
        switch result {
        case .upToDate: state = .upToDate
        case .available(let release): state = .available(release)
        case .failed(let message): state = .failed(message)
        }
    }
}
