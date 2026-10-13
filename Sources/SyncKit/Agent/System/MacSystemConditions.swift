import Foundation
import IOKit.ps
import Network

/// Conditions réelles du Mac : secteur, réseau, dossiers et volumes présents.
public final class MacSystemConditions: SystemConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    /// Optimiste tant que le moniteur n'a rien dit : mieux vaut tenter qu'attendre indéfiniment.
    private let networkUp = Locked(true)

    public init() {
        let flag = networkUp
        monitor.pathUpdateHandler = { path in flag.set(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "syncmacpro.network"))
    }

    deinit { monitor.cancel() }

    /// Un Mac de bureau (sans batterie) est toujours « sur secteur ».
    public func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPSACPowerValue
    }

    public func isNetworkAvailable() -> Bool { networkUp.get() }

    public func isReachable(_ endpoint: Endpoint) -> Bool {
        guard let path = endpoint.filesystemPath else { return isNetworkAvailable() }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
