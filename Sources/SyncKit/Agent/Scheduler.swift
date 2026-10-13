import Foundation

/// Source du temps de l'agent ; remplacée par une horloge fausse dans les tests.
public protocol SchedulerClock: Sendable {
    func now() -> Date
    var calendar: Calendar { get }
}

public struct SystemClock: SchedulerClock {
    public init() {}
    public func now() -> Date { Date() }
    public var calendar: Calendar { .current }
}

/// Calcul pur des échéances : aucune horloge, aucun état.
public enum Scheduler {
    /// Prochaine échéance après `basis`. `nil` : jamais (manuelle, « dès que disponible », ou aucun jour choisi).
    /// Sans `basis`, `everyMinutes` est dû tout de suite ; les horaires fixes partent de `now`.
    public static func nextDue(for schedule: Schedule, after basis: Date?, now: Date, calendar: Calendar) -> Date? {
        switch schedule {
        case .manual, .whenAvailable:
            return nil
        case .everyMinutes(let minutes):
            guard let basis else { return now }
            return basis.addingTimeInterval(Double(max(1, minutes)) * 60)
        case .daily(let hour, let minute):
            return occurrence(after: basis ?? now, hour: hour, minute: minute, weekday: nil, calendar: calendar)
        case .weekdays(let days, let hour, let minute):
            let start = basis ?? now
            return days.compactMap {
                occurrence(after: start, hour: hour, minute: minute, weekday: $0, calendar: calendar)
            }.min()
        }
    }

    /// `repeatedTimePolicy: .first` : à l'heure d'hiver, 02:30 existe deux fois, on ne prend que la première.
    /// `matchingPolicy: .nextTime` : à l'heure d'été, une heure inexistante glisse vers l'heure suivante.
    private static func occurrence(after date: Date, hour: Int, minute: Int, weekday: Int?, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.weekday = weekday
        return calendar.nextDate(
            after: date, matching: components, matchingPolicy: .nextTime,
            repeatedTimePolicy: .first, direction: .forward
        )
    }
}
