import CoreGraphics
import Foundation

/// Colonnes de la liste (1.7.5) : la colonne Tâche prend la place restante, les autres se redimensionnent.
enum ListColumn: String, CaseIterable, Sendable {
    case rank, task, state, last, actions

    var resizable: Bool { self == .state || self == .last }
    var standard: CGFloat {
        switch self {
        case .rank: return 28
        case .task: return 180
        case .state: return 300
        case .last: return 190
        case .actions: return 128
        }
    }
    var minimum: CGFloat {
        switch self {
        case .last: return 130
        case .state: return 180
        default: return standard
        }
    }
    var maximum: CGFloat {
        switch self {
        case .state: return 600
        case .last: return 280
        default: return standard
        }
    }
    var titleKey: String { "list.column.\(rawValue)" }
}

/// Largeurs choisies par l'utilisateur, retenues dans les préférences.
struct ListColumns: Equatable {
    private(set) var widths: [ListColumn: CGFloat] = [:]
    static let spacing: CGFloat = 8

    init() {}

    init(from defaults: UserDefaults) {
        for column in ListColumn.allCases where column.resizable {
            let saved = defaults.double(forKey: Self.key(column))
            if saved > 0 { widths[column] = min(column.maximum, max(column.minimum, CGFloat(saved))) }
        }
    }

    func width(_ column: ListColumn) -> CGFloat { widths[column] ?? column.standard }

    mutating func resize(_ column: ListColumn, by delta: CGFloat) {
        guard column.resizable else { return }
        widths[column] = min(column.maximum, max(column.minimum, width(column) + delta))
    }

    mutating func reset(_ column: ListColumn) { widths[column] = nil }

    func save(to defaults: UserDefaults) {
        for column in ListColumn.allCases where column.resizable {
            if let value = widths[column] { defaults.set(Double(value), forKey: Self.key(column)) } else { defaults.removeObject(forKey: Self.key(column)) }
        }
    }

    private static func key(_ column: ListColumn) -> String { "list.width.\(column.rawValue)" }
}
