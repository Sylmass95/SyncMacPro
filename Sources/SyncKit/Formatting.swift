import Foundation

/// Mise en forme française des tailles, débits et durées.
public enum Formatting {
    /// 2048 → « 2 Ko », 5 242 880 → « 5,0 Mo », 1 Go → « 1,00 Go ».
    public static func bytes(_ value: Int64) -> String {
        let number = Double(value)
        switch number {
        case ..<1_024: return "\(value) o"
        case ..<1_048_576: return decimal(number / 1_024, digits: 0) + " Ko"
        case ..<1_073_741_824: return decimal(number / 1_048_576, digits: 1) + " Mo"
        default: return decimal(number / 1_073_741_824, digits: 2) + " Go"
        }
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// 65 → « 1:05 », 3725 → « 1:02:05 ».
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600, minutes = total % 3_600 / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Temps restant estimé : « 45 s », « ~3 min », « ~1 h 05 ».
    public static func eta(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) s" }
        if seconds < 3_600 { return "~\(Int((seconds / 60).rounded())) min" }
        let total = Int(seconds.rounded())
        return String(format: "~%d h %02d", total / 3_600, total % 3_600 / 60)
    }

    /// Une ligne résumant l'avancement : fichier en cours, puis total.
    public static func line(for snapshot: TransferSnapshot) -> String {
        var parts: [String] = []
        if let name = snapshot.currentName {
            var current = "\(name) \(snapshot.currentPercent) %"
            if snapshot.currentSize > 0 { current += "  \(bytes(snapshot.currentBytes)) / \(bytes(snapshot.currentSize))" }
            if snapshot.currentSpeed > 0 { current += "  \(speed(snapshot.currentSpeed))" }
            if let eta = snapshot.currentETA { current += "  restant \(clock(eta))" }
            parts.append(current)
        }
        if let totalFiles = snapshot.totalFiles, totalFiles > 1 {
            var total = "total \(snapshot.filesDone)/\(totalFiles) fichiers"
            if let percent = snapshot.overallPercent { total += " \(percent) %" }
            if let totalBytes = snapshot.totalBytes { total += "  \(bytes(snapshot.doneBytes)) / \(bytes(totalBytes))" }
            if snapshot.averageSpeed > 0 { total += "  moy. \(speed(snapshot.averageSpeed))" }
            if let eta = snapshot.totalETA { total += "  \(Formatting.eta(eta))" }
            parts.append(total)
        }
        return parts.joined(separator: "  |  ")
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }
}
