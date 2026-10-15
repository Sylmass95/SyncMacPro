import Foundation

/// Ce que le mécanisme de mise à jour (Sparkle) signale à l'app.
public enum UpdateEvent: Equatable, Sendable {
    case checking, upToDate
    /// Nouvelle version en cours de téléchargement.
    case downloading(String)
    /// Téléchargée et vérifiée : il ne reste qu'à installer (puis relancer).
    case ready(String)
    case installing
    case failed(String)
}

/// Le mécanisme de mise à jour vu par l'app (Sparkle en réel, faux dans les tests).
@MainActor
public protocol UpdateDriving: AnyObject {
    var onEvent: ((UpdateEvent) -> Void)? { get set }
    var automaticallyChecks: Bool { get set }
    func start()
    func checkNow()
    /// Installe la mise à jour prête et relance l'app.
    func installNow()
}
