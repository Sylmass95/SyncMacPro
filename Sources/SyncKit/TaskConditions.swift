import Foundation

/// Plage d'heures locales [start, end[. Si `start > end`, la plage passe minuit ; si `start == end`, c'est toute la journée.
public struct HourRange: Codable, Equatable, Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public func contains(hour: Int) -> Bool {
        if start == end { return true }
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }
}

/// Ce qui doit être vrai pour qu'une tâche planifiée démarre. Sinon elle attend (ce n'est pas un échec).
public struct TaskConditions: Codable, Equatable, Hashable, Sendable {
    public var requiresACPower: Bool
    public var requiresNetwork: Bool
    public var allowedHours: HourRange?

    public init(requiresACPower: Bool = false, requiresNetwork: Bool = false, allowedHours: HourRange? = nil) {
        self.requiresACPower = requiresACPower
        self.requiresNetwork = requiresNetwork
        self.allowedHours = allowedHours
    }
}
