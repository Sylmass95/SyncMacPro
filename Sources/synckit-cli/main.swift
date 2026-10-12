import Darwin
import Foundation
import SyncKit

// Outil de développement : lance une tâche avec rsync ou rclone et affiche l'avancement.
//
//   synckit-cli run --source DOSSIER --dest DOSSIER [--mode copy|mirror|bidirectional|move|versioned|verify]
//                   [--engine rsync|rclone] [--dry-run] [--exclude MOTIF]... [--bwlimit KO_PAR_SECONDE]
//                   [--threshold POURCENT] [--state-dir DOSSIER]
//   synckit-cli history [--state-dir DOSSIER]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Erreur : \(message)\n".utf8))
    exit(64)
}

func parseOptions(_ arguments: [String]) -> (values: [String: [String]], flags: Set<String>) {
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        guard argument.hasPrefix("--") else { fail("argument inattendu : \(argument)") }
        let name = String(argument.dropFirst(2))
        if name == "dry-run" {
            flags.insert(name)
            index += 1
        } else {
            guard index + 1 < arguments.count else { fail("--\(name) attend une valeur") }
            values[name, default: []].append(arguments[index + 1])
            index += 2
        }
    }
    return (values, flags)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("commande attendue : run ou history") }
let (values, flags) = parseOptions(Array(arguments.dropFirst()))

let stateDirectory = URL(fileURLWithPath: values["state-dir"]?.last
    ?? NSString(string: "~/Library/Application Support/SyncMacPro-dev").expandingTildeInPath)
try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
let history = try HistoryStore(path: stateDirectory.appendingPathComponent("history.sqlite").path)

if command == "history" {
    for record in try history.list(limit: 20) {
        let when = record.startedAt.formatted(date: .abbreviated, time: .standard)
        let message = record.summary?.message.map { " — \($0)" } ?? ""
        print("\(when)  \(record.status.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))  \(record.taskName)\(message)")
    }
    exit(0)
}
guard command == "run" else { fail("commande inconnue : \(command)") }

guard let source = values["source"]?.last, let destination = values["dest"]?.last else {
    fail("--source et --dest sont obligatoires")
}
guard let mode = SyncMode(rawValue: values["mode"]?.last ?? "copy") else { fail("mode inconnu") }
var options = TaskOptions(excludes: values["exclude"] ?? TaskOptions.defaultExcludes)
options.bandwidthLimitKBps = values["bwlimit"]?.last.flatMap(Int.init)
options.deleteThresholdPercent = values["threshold"]?.last.flatMap(Int.init) ?? options.deleteThresholdPercent
options.forcedEngine = values["engine"]?.last.flatMap(EngineKind.init(rawValue:))

let task = SyncTask(
    name: URL(fileURLWithPath: source).lastPathComponent + " → " + URL(fileURLWithPath: destination).lastPathComponent,
    source: .local(path: source), destination: .local(path: destination), mode: mode, options: options
)
let runner = TaskRunner(configuration: RunnerConfiguration(
    rsyncPath: BinaryLocator.locate(.rsync), rclonePath: BinaryLocator.locate(.rclone),
    workDirectory: stateDirectory.appendingPathComponent("work")
))

// Ctrl-C arrête proprement la copie au lieu de tuer l'outil.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { runner.stop() }
interrupt.resume()

let dryRun = flags.contains("dry-run")
let engine = try EngineSelector.engine(for: task)
var record = RunRecord(taskID: task.id, taskName: task.name, engine: engine, mode: mode, dryRun: dryRun, startedAt: Date())
try history.save(record)
print("\(task.name)  [\(engine.rawValue), \(mode.rawValue)\(dryRun ? ", simulation" : "")]")

do {
    let result = try await runner.run(task, dryRun: dryRun) { update in
        switch update {
        case .phase(let phase): print("• \(phase)")
        case .snapshot(let snapshot):
            let line = Formatting.line(for: snapshot)
            if !line.isEmpty { print("\r\u{1B}[2K\(line)", terminator: ""); fflush(stdout) }
        case .line: break
        }
    }
    print("\n\(result.status.rawValue) : \(result.summary.message ?? "")")
    print("\(result.summary.filesTransferred) fichier(s), \(Formatting.bytes(result.summary.bytesTransferred)), "
        + "\(result.summary.deletions) suppression(s), \(result.summary.errors) erreur(s), "
        + "\(Formatting.clock(result.summary.durationSeconds))")
    record.status = result.status
    record.summary = result.summary
    record.finishedAt = Date()
    try history.save(record)
    switch result.status {
    case .succeeded: exit(0)
    case .blocked: exit(2)
    case .stopped, .quotaReached, .interrupted: exit(3)
    case .failed, .running: exit(1)
    }
} catch {
    print("\nÉchec : \(error)")
    record.status = .failed
    record.summary = RunSummary(message: "\(error)")
    record.finishedAt = Date()
    try? history.save(record)
    exit(1)
}
