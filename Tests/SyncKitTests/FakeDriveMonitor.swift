import Foundation
@testable import SyncKit

/// Disques pilotés par les tests.
final class FakeDriveMonitor: DriveMonitor, @unchecked Sendable {
    let volumes = Locked<[String: String]>([:])
    let ejected = Locked<[String]>([])
    let ejectRefusal = Locked<String?>(nil)
    /// Durée d'une éjection (pour les éjections concurrentes).
    let ejectDelay = Locked<UInt64>(0)
    /// Date de montage de chaque point de montage (nil : inconnue).
    let mountDates = Locked<[String: Date]>([:])
    private let handler = Locked<(@Sendable () -> Void)?>(nil)

    func mountedVolumes() -> [String: String] { volumes.get() }
    func start(onChange: @escaping @Sendable () -> Void) { handler.set(onChange) }
    func mountDate(path: String) -> Date? { mountDates.get()[path] }
    func eject(mountPath: String) async -> String? {
        let delay = ejectDelay.get()
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if let refusal = ejectRefusal.get() { return refusal }
        ejected.update { $0.append(mountPath) }
        volumes.update { $0 = $0.filter { $0.value != mountPath } }
        return nil
    }

    func plug(_ uuid: String, at path: String) { volumes.update { $0[uuid] = path }; handler.get()?() }
    func unplug(_ uuid: String) { volumes.update { $0[uuid] = nil }; handler.get()?() }
}
