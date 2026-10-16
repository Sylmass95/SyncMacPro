import Foundation

public enum TaskReferenceError: Error, Equatable, LocalizedError {
    case notFound(String)
    case ambiguous(String, [String])

    public var errorDescription: String? {
        switch self {
        case .notFound(let text): return "Aucune tâche ne correspond à « \(text) »."
        case .ambiguous(let text, let names):
            return "« \(text) » correspond à plusieurs tâches : \(names.joined(separator: ", "))."
        }
    }
}

public enum TaskReference {
    /// La dernière exécution dont le nom commence par `text` : une copie manuelle n'a pas de tâche à retrouver.
    public static func latestRun(named text: String, in records: [RunRecord]) -> RunRecord? {
        let wanted = text.lowercased()
        return records.filter { $0.taskName.lowercased().hasPrefix(wanted) }.max { $0.startedAt < $1.startedAt }
    }

    /// Tâche visée par « log » : seule l'absence de tâche permet de chercher une copie ponctuelle du même nom ; un nom
    /// ambigu le reste (sinon le journal d'une autre exécution serait affiché sans prévenir).
    public static func logTarget(_ text: String, in tasks: [SyncTask]) -> Result<SyncTask, TaskReferenceError> {
        do { return .success(try resolve(text, in: tasks)) } catch let error as TaskReferenceError {
            return .failure(error)
        } catch {
            return .failure(.notFound(text))
        }
    }

    /// Nom exact, début de nom, identifiant complet ou début d'identifiant (4 caractères au moins).
    public static func resolve(_ text: String, in tasks: [SyncTask]) throws -> SyncTask {
        let wanted = text.lowercased()
        if let byID = tasks.first(where: { $0.id.uuidString.lowercased() == wanted }) { return byID }
        let exact = tasks.filter { $0.name.lowercased() == wanted }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw TaskReferenceError.ambiguous(text, exact.map(\.name)) }
        let candidates = tasks.filter {
            $0.name.lowercased().hasPrefix(wanted) || (wanted.count >= 4 && $0.id.uuidString.lowercased().hasPrefix(wanted))
        }
        switch candidates.count {
        case 0: throw TaskReferenceError.notFound(text)
        case 1: return candidates[0]
        default: throw TaskReferenceError.ambiguous(text, candidates.map(\.name))
        }
    }
}

public enum CtlFormatter {
    static func date(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter.string(from: date)
    }

    public static func scheduleDescription(_ schedule: Schedule) -> String {
        func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
        switch schedule {
        case .manual: return "manuelle"
        case .whenAvailable: return "dès que disponible"
        case .everyMinutes(let minutes): return "toutes les \(minutes) min"
        case .daily(let hour, let minute): return "tous les jours à \(clock(hour, minute))"
        case .weekdays(let days, let hour, let minute):
            let names = ["dim", "lun", "mar", "mer", "jeu", "ven", "sam"]
            let list = days.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }
            return "\(list.joined(separator: ", ")) à \(clock(hour, minute))"
        }
    }

    public static func stateLabel(_ state: TaskRunState) -> String {
        switch state {
        case .idle: return "au repos"
        case .queued: return "en file"
        case .running: return "en cours"
        case .paused: return "en pause"
        case .waiting(let reason): return "en attente (\(reason))"
        case .awaitingApproval: return "validation requise"
        case .disabled: return "désactivée"
        }
    }

    public static func statusLabel(_ status: RunStatus) -> String {
        switch status {
        case .running: return "en cours"
        case .succeeded: return "réussie"
        case .failed: return "échec"
        case .blocked: return "bloquée"
        case .quotaReached: return "quota atteint"
        case .interrupted: return "interrompue"
        case .stopped: return "arrêtée"
        }
    }

    public static func statusLines(_ status: AgentStatus, timeZone: TimeZone = .current) -> [String] {
        var lines = ["Pause globale : \(status.globalPause ? "oui" : "non")"]
        if status.stateRecovered {
            lines.append("⚠︎ Le fichier d'état était illisible : l'agent est reparti en pause.")
        }
        if let error = status.taskLoadError {
            lines.append("⚠︎ tasks.json illisible (les tâches précédentes sont conservées) : \(error)")
        }
        for task in status.tasks {
            let next = task.nextDue.map { date($0, timeZone: timeZone) } ?? "—"
            let last = task.lastRun.map { "\(statusLabel($0.status)) \(date($0.startedAt, timeZone: timeZone))" } ?? "—"
            if task.driveSuspendedSince != nil, task.driveMounted == true {
                lines.append("• \(task.name)  [en pause : disque branché, reprise en attente (\(stateLabel(task.state)))]  dernière : \(last)")
                continue
            }
            if let since = task.driveSuspendedSince {
                lines.append("• \(task.name)  [en pause : disque débranché depuis \(date(since, timeZone: timeZone))]  "
                    + "reprend au rebranchement (ou « abandon \(task.name) »)  dernière : \(last)")
                continue
            }
            lines.append("• \(task.name)  [\(stateLabel(task.state))]  prochaine : \(next)  dernière : \(last)")
        }
        if status.tasks.isEmpty { lines.append("Aucune tâche.") }
        return lines
    }

    public static func taskLines(_ tasks: [SyncTask]) -> [String] {
        tasks.map { "• \($0.name)  [\($0.mode.rawValue)]  \(scheduleDescription($0.schedule))  \($0.id.uuidString.prefix(8))" }
    }

    public static func historyLines(_ records: [RunRecord], timeZone: TimeZone = .current) -> [String] {
        records.map { record in
            let message = record.summary?.message.map { " — \($0)" } ?? ""
            return "\(date(record.startedAt, timeZone: timeZone))  \(statusLabel(record.status).padding(toLength: 13, withPad: " ", startingAt: 0))  \(record.taskName)\(message)"
        }
    }

    public static func eventLine(_ event: AgentEvent, names: [UUID: String]) -> String? {
        switch event {
        case .taskStarted(let id): return "▶ \(names[id] ?? id.uuidString) démarre"
        case .taskFinished(let id, let status, let message):
            return "■ \(names[id] ?? id.uuidString) : \(statusLabel(status))" + (message.map { " — \($0)" } ?? "")
        case .progress(let id, let info):
            let percent = info.overallPercent.map { "\($0) %" } ?? "…"
            return "  \(names[id] ?? id.uuidString) : \(percent) \(info.currentName ?? "")"
        case .stateChanged: return "↻ état modifié"
        }
    }

    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "{}"
    }
}
