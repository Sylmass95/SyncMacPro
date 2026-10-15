import Foundation

/// Contrôle à distance d'une exécution rclone par une prise Unix privée : change sa limite de débit en route.
public enum RcloneRemoteControl {
    /// `<dossier temporaire de l'utilisateur>/smp-rc/<8 caractères>.sock` : sous la limite de 104 caractères des prises.
    /// Le dossier est réservé à l'utilisateur (0700) : la prise, ouverte sans authentification, n'est joignable que par lui.
    public static func socketPath() -> String {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("smp-rc")
        try? FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        return (folder as NSString).appendingPathComponent("\(UUID().uuidString.prefix(8)).sock")
    }

    /// `rclone rc core/bwlimit rate=…` ; faux si la prise ne répond pas (exécution qui démarre ou se termine).
    @discardableResult
    public static func setRate(rclone: String, socket: String, rate: BandwidthRate) async -> Bool {
        let value = RcloneCommandBuilder.bwlimitValue(rate) ?? "off"
        guard let process = try? ProcessRunner.spawn(
            executable: rclone, arguments: ["rc", "core/bwlimit", "rate=\(value)", "--unix-socket", socket], onLine: { _ in }
        ) else { return false }
        return await process.waitForExit() == 0
    }
}
