import Foundation
@testable import SyncKit

/// Disques pilotés par les tests.
final class FakeDriveMonitor: DriveMonitor, @unchecked Sendable {
    let volumes = Locked<[String: String]>([:])
    let ejected = Locked<[String]>([])
    let ejectRefusal = Locked<String?>(nil)
    private let handler = Locked<(@Sendable () -> Void)?>(nil)

    func mountedVolumes() -> [String: String] { volumes.get() }
    func start(onChange: @escaping @Sendable () -> Void) { handler.set(onChange) }
    func eject(mountPath: String) async -> String? {
        if let refusal = ejectRefusal.get() { return refusal }
        ejected.update { $0.append(mountPath) }
        volumes.update { $0 = $0.filter { $0.value != mountPath } }
        return nil
    }

    func plug(_ uuid: String, at path: String) { volumes.update { $0[uuid] = path }; handler.get()?() }
    func unplug(_ uuid: String) { volumes.update { $0[uuid] = nil }; handler.get()?() }
}
