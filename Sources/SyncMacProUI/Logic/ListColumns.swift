import CoreGraphics
import Foundation

/// Colonnes de la liste (1.7.5). 1.7.9 : comme dans le Finder, chaque colonne (sauf N° et Actions) se redimensionne par
/// son bord droit ; la place libre reste devant Actions.
enum ListColumn: String, CaseIterable, Sendable {
    case rank, task, state, last, actions

    var resizable: Bool { self == .task || self == .state || self == .last }
    var standard: CGFloat {
        switch self {
        case .rank: return 28
        case .task: return 260
        case .state: return 300
        case .last: return 190
        case .actions: return 128
        }
    }
    var minimum: CGFloat {
        switch self {
        case .task: return 180
        case .last: return 130
        case .state: return 180
        default: return standard
        }
    }
    var maximum: CGFloat {
        switch self {
        case .task: return 900
        case .state: return 1200
        case .last: return 500
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

    /// 1.7.9 : le séparateur placé après une colonne tire son bord droit (comme dans le Finder).
    static func separatorTarget(after column: ListColumn) -> ListColumn? { column.resizable ? column : nil }

    /// Glisser le bord droit de `column` : vers la droite il l'élargit, vers la gauche il la rétrécit ; les colonnes
    /// suivantes se décalent. Jamais plus large que la place libre de la liste (largeur `available`).
    mutating func drag(_ column: ListColumn, from start: CGFloat, translation: CGFloat, available: CGFloat) {
        guard column.resizable else { return }
        let others = ListColumn.allCases.filter { $0 != column }.reduce(0) { $0 + width($1) }
            + CGFloat(ListColumn.allCases.count - 1) * Self.spacing
        let upper = max(column.minimum, min(column.maximum, available - others))
        widths[column] = min(upper, max(column.minimum, start + translation))
    }

    func save(to defaults: UserDefaults) {
        for column in ListColumn.allCases where column.resizable {
            if let value = widths[column] { defaults.set(Double(value), forKey: Self.key(column)) } else { defaults.removeObject(forKey: Self.key(column)) }
        }
    }

    private static func key(_ column: ListColumn) -> String { "list.width.\(column.rawValue)" }
}
