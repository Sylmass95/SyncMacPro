import Foundation
import SyncKit

/// Transforme un chemin choisi en `Endpoint` : un dossier sur un partage réseau monté devient une destination « réseau »
/// (on garde l'adresse de remontage). La lecture du volume est injectable pour les tests.
public struct EndpointResolver: Sendable {
    public struct VolumeInfo: Equatable, Sendable {
        public var isLocal: Bool
        public var remountURL: URL?

        public init(isLocal: Bool, remountURL: URL?) {
            self.isLocal = isLocal
            self.remountURL = remountURL
        }
    }

    public let volumeInfo: @Sendable (URL) -> VolumeInfo

    public init(volumeInfo: @escaping @Sendable (URL) -> VolumeInfo) {
        self.volumeInfo = volumeInfo
    }

    public static let system = EndpointResolver { url in
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeURLForRemountingKey])
        return VolumeInfo(isLocal: values?.volumeIsLocal ?? true, remountURL: values?.volumeURLForRemounting)
    }

    public static let localOnly = EndpointResolver { _ in VolumeInfo(isLocal: true, remountURL: nil) }

    public func endpoint(forPath path: String) -> Endpoint {
        let info = volumeInfo(URL(fileURLWithPath: path))
        if !info.isLocal, let remount = info.remountURL {
            return .network(url: remount.absoluteString, mountPath: path)
        }
        return .local(path: path)
    }
}
