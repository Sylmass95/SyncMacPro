import DiskArbitration
import Foundation

/// Allées et venues des disques par DiskArbitration (fonctionne dans un agent launchd, sans fenêtre).
public final class DiskArbitrationMonitor: DriveMonitor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "syncmacpro.disques")
    private var session: DASession?
    private let handler = Locked<(@Sendable () -> Void)?>(nil)

    public init() {}

    public func mountedVolumes() -> [String: String] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []   // un volume caché reste trouvé par son UUID
        ) ?? []
        var result: [String: String] = [:]
        for url in urls {
            if let uuid = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString {
                result[uuid] = VolumeLookup.canonical(url.path)
            }
        }
        return result
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        handler.set(onChange)
        guard session == nil, let created = DASessionCreate(kCFAllocatorDefault) else { return }
        session = created
        let context = Unmanaged.passUnretained(self).toOpaque()
        let fired: DADiskAppearedCallback = { _, context in
            guard let context else { return }
            Unmanaged<DiskArbitrationMonitor>.fromOpaque(context).takeUnretainedValue().fire()
        }
        DARegisterDiskAppearedCallback(created, nil, fired, context)
        DARegisterDiskDisappearedCallback(created, nil, fired, context)
        let changed: DADiskDescriptionChangedCallback = { _, _, context in
            guard let context else { return }
            Unmanaged<DiskArbitrationMonitor>.fromOpaque(context).takeUnretainedValue().fire()
        }
        DARegisterDiskDescriptionChangedCallback(created, nil, [kDADiskDescriptionVolumePathKey] as CFArray, changed, context)
        DASessionSetDispatchQueue(created, queue)
    }

    private func fire() { handler.get()?() }

    /// `diskutil eject` : démonte tous les volumes du disque puis l'éjecte.
    public func eject(mountPath: String) async -> String? {
        let output = LineBox()
        guard let process = try? ProcessRunner.spawn(
            executable: "/usr/sbin/diskutil", arguments: ["eject", mountPath], onLine: { output.add($0.text) }
        ) else { return "diskutil introuvable" }
        let code = await process.waitForExit()
        return code == 0 ? nil : (output.joined.isEmpty ? "Éjection refusée (code \(code))." : output.joined)
    }
}
