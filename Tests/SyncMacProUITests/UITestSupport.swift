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
