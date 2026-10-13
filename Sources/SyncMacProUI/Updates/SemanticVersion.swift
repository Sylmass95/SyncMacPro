import Foundation

/// « 1.2.3 », « v1.2 », « 2.0.0-beta » (pré-version, plus ancienne que 2.0.0) ; « 1.0.0 (321) » ignore la construction.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if let space = value.firstIndex(of: " ") { value = String(value[..<space]) }
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let pieces = value.split(separator: "-", maxSplits: 1).map(String.init)
        guard let numbers = pieces.first, !numbers.isEmpty else { return nil }
        let parsed = numbers.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parsed.isEmpty, parsed.count <= 3, parsed.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        var all = parsed.compactMap { $0 }
        while all.count < 3 { all.append(0) }
        parts = all
        prerelease = pieces.count > 1 ? pieces[1] : nil
    }

    public var description: String {
        parts.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.parts != rhs.parts { return lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let a?, let b?): return a < b
        }
    }
}
