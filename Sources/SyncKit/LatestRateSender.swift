import Foundation

/// Envoie les changements de limite de débit un par un, et seulement le plus récent : deux envois lancés en parallèle
/// pourraient arriver dans le désordre (relecture 1.3.0 : une exécution restait à la part entière d'avant).
/// Un envoi refusé (prise pas encore ouverte) est retenté quelques fois.
public final class LatestRateSender: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: BandwidthRate?
    private var sending = false
    private let send: @Sendable (BandwidthRate) async -> Bool

    public init(send: @escaping @Sendable (BandwidthRate) async -> Bool) { self.send = send }

    public func submit(_ rate: BandwidthRate) {
        lock.lock()
        pending = rate
        let start = !sending
        sending = true
        lock.unlock()
        guard start else { return }
        Task.detached { [self] in await drain() }
    }

    private func next() -> BandwidthRate? {
        lock.lock(); defer { lock.unlock() }
        guard let rate = pending else { sending = false; return nil }
        pending = nil
        return rate
    }

    private func drain() async {
        while let rate = next() {
            for attempt in 0..<5 {
                if await send(rate) { break }
                if attempt < 4 { try? await Task.sleep(nanoseconds: 400_000_000) }
            }
        }
    }
}
