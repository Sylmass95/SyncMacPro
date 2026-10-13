import SyncKit

/// L'état de la confirmation : la simulation et les suppressions acceptées.
struct ConfirmationFlow: Equatable {
    var simulation: SimulationState = .idle
    var acceptDeletions = false

    mutating func beginSimulation() {
        simulation = .running
        acceptDeletions = false   // l'acceptation ne valait que pour la simulation précédente
    }

    mutating func finish(_ outcome: SimulationOutcome) {
        simulation = .finished(outcome)
    }

    /// Les suppressions ne sont acceptées que pour une synchronisation, après une simulation qui les a annoncées.
    func acceptsDeletions(isSync: Bool) -> Bool {
        acceptDeletions && CopyConfirmationContent.offersDeletionApproval(isSync: isSync, simulation: simulation)
    }
}
