import Foundation

/// Sommeil injectable : les tests pilotent les attentes (reconnexion, relecture groupée) sans attendre.
public protocol Sleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct RealSleeper: Sleeping {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
