import Foundation

/// Quand une tâche doit se lancer. Le calcul des échéances est fait par l'agent (sous-projet 2).
public enum Schedule: Codable, Equatable, Hashable, Sendable {
    case manual
    case daily(hour: Int, minute: Int)
    case everyMinutes(Int)
    /// `days` suit `Calendar` : 1 = dimanche … 7 = samedi.
    case weekdays(days: Set<Int>, hour: Int, minute: Int)
    /// Dès que la source et la destination sont joignables.
    case whenAvailable
}
