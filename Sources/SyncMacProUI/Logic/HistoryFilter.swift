import Foundation
import SyncKit

public enum HistoryPeriod: String, CaseIterable, Sendable {
    case day, week, month, all

    var interval: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .all: return nil
        }
    }
}

/// Filtres de l'historique, appliqués dans l'app sur les dernières exécutions que l'agent renvoie.
public struct HistoryFilter: Equatable, Sendable {
    public var taskID: UUID?
    /// Vide : tous les états.
    public var statuses: Set<RunStatus> = []
    public var period: HistoryPeriod = .all
    public var search = ""

    public init() {}

    public func apply(to records: [RunRecord], now: Date) -> [RunRecord] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return records.filter { record in
            if let taskID, record.taskID != taskID { return false }
            if !statuses.isEmpty, !statuses.contains(record.status) { return false }
            if let interval = period.interval, now.timeIntervalSince(record.startedAt) > interval { return false }
            if !query.isEmpty, record.taskName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
            return true
        }
    }
}
