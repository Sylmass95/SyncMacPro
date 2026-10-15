import Foundation
import XCTest

/// Attend qu'une condition devienne vraie (2 s au plus) ; faux si elle ne l'est jamais.
@MainActor
func eventually(timeout: TimeInterval = 2, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
