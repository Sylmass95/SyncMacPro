import Darwin
import Foundation
import SyncKit

// Agent d'arrière-plan de SyncMacPro.
//
//   syncmacpro-agent [--foreground] [--state-dir DOSSIER] [--mach-service NOM] [--startup-hold SECONDES]
//
// Lancé par launchd (SMAppService) il répond aux requêtes XPC. Avec --foreground il tourne dans le terminal
// sans XPC : un service Mach exige launchd (voir scripts/dev-launchd.sh pour le développement).

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[\(Date().formatted(.iso8601))] \(message)\n".utf8))
}

let foreground = arguments.contains("--foreground")
let paths = option("--state-dir").map { AgentPaths(root: URL(fileURLWithPath: $0)) } ?? .standard
let serviceName = option("--mach-service") ?? AgentIdentifiers.machService

try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
let history = try HistoryStore(path: paths.history.path)
let runnerConfiguration = RunnerConfiguration(
    rsyncPath: BinaryLocator.locate(.rsync), rclonePath: BinaryLocator.locate(.rclone), workDirectory: paths.work
)
var agentConfiguration = AgentConfiguration()
if let hold = option("--startup-hold").flatMap(Double.init) { agentConfiguration.startupHold = hold }

let core = AgentCore(
    configuration: agentConfiguration,
    taskStore: TaskStore(url: paths.tasks),
    stateStore: SchedulerStateStore(url: paths.state),
    history: history,
    clock: SystemClock(),
    conditions: MacSystemConditions(),
    notifier: UserNotifier(),
    activity: SleepActivity(),
    log: { log($0) },
    makeRunner: { TaskRunner(configuration: runnerConfiguration) }
)
await core.start()
log("agent démarré (données : \(paths.root.path), rsync : \(runnerConfiguration.rsyncPath ?? "introuvable"))")

// XPC : le service doit être déclaré par launchd ; sans lui, rien à écouter.
let delegate = AgentListenerDelegate(
    core: core, codeSigningRequirement: CodeSigning.ownTeamIdentifier().map(CodeSigning.requirement(forTeam:))
)
let listener = NSXPCListener(machServiceName: serviceName)
listener.delegate = delegate
if foreground {
    log("mode terminal : pas de service XPC")
} else {
    listener.resume()
}

// Évaluation : tout de suite, puis chaque minute. tasks.json est relu quand son horodatage change.
func modificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}
final class StampBox: @unchecked Sendable { var value: Date? }
let tasksStamp = StampBox()
tasksStamp.value = modificationDate(paths.tasks)

func evaluate() async {
    let stamp = modificationDate(paths.tasks)
    if stamp != tasksStamp.value {
        tasksStamp.value = stamp
        await core.reloadTasks()
    }
    await core.tick()
}

await evaluate()
let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task.detached { await evaluate() } }

// Arrêt propre : les copies en cours sont arrêtées, marquées « interrompues » et rattrapées au prochain démarrage.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
// File dédiée : appelée depuis le code asynchrone de main.swift, `RunLoop.main.run()` ne sert pas la file principale.
let signalQueue = DispatchQueue(label: "syncmacpro.signals")
let signalSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        // `Task.detached` : le code de main.swift est lié à l'acteur principal, bloqué dans RunLoop.main.run().
        Task.detached {
            log("arrêt demandé")
            await core.shutdown()
            exit(0)
        }
    }
    source.resume()
    return source
}

withExtendedLifetime((timer, signalSources, listener, delegate)) { RunLoop.main.run() }
