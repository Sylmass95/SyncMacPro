import Foundation

/// Empêche la mise en veille du Mac tant qu'une copie tourne.
public final class SleepActivity: ActivityHolding, @unchecked Sendable {
    private let token = Locked<NSObjectProtocol?>(nil)

    public init() {}

    public func begin() {
        guard token.get() == nil else { return }
        token.set(ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled], reason: "Synchronisation en cours"
        ))
    }

    public func end() {
        guard let current = token.get() else { return }
        ProcessInfo.processInfo.endActivity(current)
        token.set(nil)
    }
}
