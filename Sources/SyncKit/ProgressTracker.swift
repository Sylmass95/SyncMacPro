import Foundation

/// Photo de l'avancement d'une exécution : fichier en cours et total.
public struct TransferSnapshot: Equatable, Sendable {
    public var currentName: String?
    public var currentBytes: Int64 = 0
    public var currentSize: Int64 = 0
    public var currentPercent: Int = 0
    public var currentSpeed: Double = 0
    public var currentElapsed: TimeInterval = 0
    public var currentETA: TimeInterval?

    public var totalBytes: Int64?
    public var doneBytes: Int64 = 0
    public var totalFiles: Int?
    public var filesDone: Int = 0
    public var totalDirs: Int?
    public var dirsDone: Int = 0
    /// Pourcentage global ; reste à 99 tant que l'exécution n'est pas terminée.
    public var overallPercent: Int?
    public var averageSpeed: Double = 0
    public var totalETA: TimeInterval?
    /// Temps passé à copier, pauses exclues.
    public var activeTime: TimeInterval = 0

    public init() {}
}

/// Calcule l'avancement à partir des événements de rsync ou de rclone.
///
/// Règles qui évitent les totaux faux :
/// - les octets terminés sont comptés **une fois par nom de fichier**, même si une reprise le retransfère ;
/// - le total est l'union de la simulation initiale et de ce qui a été copié : il **grandit** si de nouveaux
///   fichiers apparaissent en cours de route, donc le fait ne dépasse jamais le total ;
/// - le pourcentage global ne dépasse pas 99 tant que `finish()` n'a pas été appelé.
///
/// Non thread-safe : l'appelant sérialise les accès.
public final class ProgressTracker {
    private let now: () -> Date
    private let fileInfo: (String) -> (size: Int64, live: Bool)

    private var doneFiles: [String: Int64] = [:]
    private var doneDirs: Set<String> = []
    private var planFiles: [String: Int64]?
    private var planDirs: Set<String> = []

    // Totaux tenus à jour au fil des événements : `snapshot()` est appelé quatre fois par seconde, et le recalcul de
    // l'union du plan et des fichiers copiés coûtait proportionnellement au nombre de fichiers (un million de fichiers
    // ralentissait la copie jusqu'à freiner rsync, qui attendait que l'agent lise sa sortie).
    private var doneBytesSum: Int64 = 0
    private var planBytes: Int64 = 0
    /// Σ (taille copiée − taille prévue, 0 si absent du plan) sur les fichiers copiés.
    private var unionBytesDelta: Int64 = 0
    /// Fichiers copiés absents du plan, dossiers vus absents du plan.
    private var extraFiles = 0
    private var extraDirs = 0

    private var currentName: String?
    private var currentSize: Int64 = 0
    private var currentBytes: Int64 = 0
    private var currentPercent = 0
    private var currentSpeed: Double = 0
    /// Temps actif écoulé au moment où le fichier en cours a commencé / s'est terminé (les pauses n'y comptent pas).
    private var currentStartActive: TimeInterval = 0
    private var currentEndActive: TimeInterval?
    private var currentHasStarted = false
    private var currentCounted = true
    private var currentLive = false
    private var samples: [(date: Date, bytes: Int64)] = []

    private var activeAccumulated: TimeInterval = 0
    private var activeSince: Date?
    private var finished = false
    private var rclone: RcloneStats?
    /// Dossiers faits / à faire d'une exécution rclone (voir `RcloneDirectoryProgress`).
    private var rcloneDirs: (done: Int, total: Int)?

    /// - Parameter fileInfo: pour un nom de fichier, sa taille (0 si inconnue) et si sa progression peut être
    ///   mesurée en direct sur la destination (fichier nouveau).
    public init(
        now: @escaping () -> Date = Date.init,
        fileInfo: @escaping (String) -> (size: Int64, live: Bool) = { _ in (0, false) }
    ) {
        self.now = now
        self.fileInfo = fileInfo
    }

    // MARK: temps actif

    public func start() { if activeSince == nil { activeSince = now() } }

    public func pause() {
        if let since = activeSince { activeAccumulated += now().timeIntervalSince(since) }
        activeSince = nil
    }

    public func resume() { start() }

    /// L'exécution est terminée. Sans simulation initiale, le total est alors ce qui a été copié.
    public func finish() {
        pause()
        finished = true
        if planFiles == nil, rclone == nil { setPlan(files: [:], directories: []) }
    }

    // MARK: rsync

    /// Résultat de la simulation initiale (peut arriver après le début de la copie).
    public func setPlan(files: [String: Int64], directories: Set<String>) {
        planFiles = files
        planDirs = directories
        // Une fois par exécution : on rapproche le plan de ce qui a déjà été copié.
        planBytes = files.values.reduce(0, +)
        unionBytesDelta = 0
        extraFiles = 0
        for (name, size) in doneFiles {
            let planned = files[name]
            unionBytesDelta += size - (planned ?? 0)
            if planned == nil { extraFiles += 1 }
        }
        extraDirs = doneDirs.subtracting(directories).count
    }

    public func apply(_ event: RsyncEvent) {
        switch event {
        case .fileStarted(let name, let isNew):
            let info = fileInfo(name)
            currentName = name
            currentSize = info.size
            currentLive = isNew ?? info.live
            currentBytes = 0
            currentPercent = 0
            currentSpeed = 0
            currentStartActive = activeTime()
            currentEndActive = nil
            currentHasStarted = true
            currentCounted = false
            samples = []
        case .directory(let name):
            if doneDirs.insert(name).inserted, planFiles != nil, !planDirs.contains(name) { extraDirs += 1 }
        case .progress(let bytes, let percent, let speed, let fileFinished):
            guard !currentCounted else { return }
            if !currentLive {
                currentPercent = percent
                currentSpeed = speed
            }
            currentBytes = max(currentBytes, bytes)
            if currentSize == 0, percent > 0 { currentSize = bytes * 100 / Int64(percent) }
            if fileFinished { completeCurrentFile() }
        case .deleting, .message, .error:
            break
        }
    }

    /// Mesure directe de la taille du fichier en cours sur la destination (plus fine que la sortie de rsync,
    /// qui n'affiche qu'environ une ligne par seconde).
    public func observeCurrentFileBytes(_ bytes: Int64) {
        guard currentLive, !currentCounted, activeSince != nil else { return }
        let value = currentSize > 0 ? min(bytes, currentSize) : bytes
        guard value >= currentBytes else { return }
        currentBytes = value
        let date = now()
        samples.append((date, value))
        if samples.count > 14 { samples.removeFirst(samples.count - 14) }
        if currentSize > 0 { currentPercent = min(99, Int(value * 100 / currentSize)) }
        if let first = samples.first, let last = samples.last {
            let elapsed = last.date.timeIntervalSince(first.date)
            if elapsed > 0.4 { currentSpeed = Double(last.bytes - first.bytes) / elapsed }
        }
    }

    private func completeCurrentFile() {
        guard let name = currentName else { return }
        let size = currentSize > 0 ? currentSize : currentBytes
        // Affectation : un fichier retransféré n'est compté qu'une fois.
        if let previous = doneFiles.updateValue(size, forKey: name) {
            doneBytesSum += size - previous
            unionBytesDelta += size - previous
        } else {
            doneBytesSum += size
            if let plan = planFiles {
                let planned = plan[name]
                unionBytesDelta += size - (planned ?? 0)
                if planned == nil { extraFiles += 1 }
            }
        }
        currentBytes = size
        currentPercent = 100
        currentCounted = true
        currentEndActive = activeTime()    // le chronomètre du fichier s'arrête ici
    }

    /// Temps passé à copier jusqu'à maintenant : s'arrête pendant une pause et à la fin.
    private func activeTime() -> TimeInterval {
        activeAccumulated + (activeSince.map { now().timeIntervalSince($0) } ?? 0)
    }

    // MARK: rclone

    public func apply(_ stats: RcloneStats) {
        rclone = stats
    }

    public func setRcloneDirectories(done: Int, total: Int) { rcloneDirs = (done, total) }

    // MARK: résultat

    public func snapshot() -> TransferSnapshot {
        var snap = TransferSnapshot()
        let date = now()
        snap.activeTime = activeTime()

        if let stats = rclone {
            fillFromRclone(&snap, stats)
        } else {
            fillFromRsync(&snap, date: date)
        }
        if currentHasStarted, snap.currentName != nil, rclone == nil {
            snap.currentElapsed = max(0, (currentEndActive ?? snap.activeTime) - currentStartActive)
        }
        if snap.averageSpeed == 0, snap.activeTime > 2, snap.doneBytes > 0 {
            snap.averageSpeed = Double(snap.doneBytes) / snap.activeTime
        }
        if let total = snap.totalBytes {
            snap.overallPercent = finished ? 100 : min(99, total > 0 ? Int(snap.doneBytes * 100 / total) : 0)
            if snap.averageSpeed > 0, total > snap.doneBytes, !finished {
                snap.totalETA = Double(total - snap.doneBytes) / snap.averageSpeed
            }
        }
        return snap
    }

    private func fillFromRsync(_ snap: inout TransferSnapshot, date: Date) {
        snap.currentName = currentName
        snap.currentBytes = currentBytes
        snap.currentSize = currentSize
        snap.currentPercent = currentPercent
        snap.currentSpeed = currentSpeed
        if !currentCounted, currentSpeed > 0, currentSize > currentBytes {
            snap.currentETA = Double(currentSize - currentBytes) / currentSpeed
        }

        snap.filesDone = doneFiles.count
        snap.dirsDone = doneDirs.count
        snap.doneBytes = doneBytesSum + (currentCounted ? 0 : currentBytes)

        // Union du plan et des fichiers copiés (un fichier copié remplace sa taille prévue), plus le fichier en cours.
        if let plan = planFiles {
            var files = plan.count + extraFiles
            var bytes = planBytes + unionBytesDelta
            if !currentCounted, let name = currentName {
                if let known = doneFiles[name] ?? plan[name] {
                    bytes += max(known, currentSize) - known
                } else {
                    files += 1
                    bytes += currentSize
                }
            }
            snap.totalFiles = files
            snap.totalBytes = bytes
            snap.totalDirs = planDirs.count + extraDirs
        }
    }

    private func fillFromRclone(_ snap: inout TransferSnapshot, _ stats: RcloneStats) {
        snap.doneBytes = stats.bytes
        snap.totalBytes = stats.totalBytes
        snap.filesDone = stats.transfers
        snap.totalFiles = stats.totalTransfers
        snap.averageSpeed = stats.speed
        if let active = stats.transferring.first {
            snap.currentName = active.name
            snap.currentBytes = active.bytes
            snap.currentSize = active.size
            snap.currentPercent = active.percentage
            snap.currentSpeed = active.speed
            if active.speed > 0, active.size > active.bytes {
                snap.currentETA = Double(active.size - active.bytes) / active.speed
            }
        }
        snap.totalETA = stats.eta
        if let dirs = rcloneDirs {
            snap.dirsDone = dirs.done
            snap.totalDirs = dirs.total
        }
    }
}
