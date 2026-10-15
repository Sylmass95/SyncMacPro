import Darwin
import Foundation
import SyncKit

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("Erreur : \(message)\n".utf8))
    exit(code)
}

let invocation: CtlInvocation
do {
    invocation = try CtlParser.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error.localizedDescription)", code: 64)
}

let paths = invocation.stateDirectory.map { AgentPaths(root: URL(fileURLWithPath: $0)) } ?? .standard
let client = AgentClient.machService(invocation.service ?? AgentIdentifiers.machService)

func show<T: Encodable>(_ value: T, lines: [String]) {
    print(invocation.json ? CtlFormatter.json(value) : lines.joined(separator: "\n"))
}

func printBandwidth(_ limits: BandwidthLimits) {
    func text(_ value: Double?) -> String { value.map { "\($0.formatted()) Mbit/s" } ?? "sans plafond" }
    print("Réception internet : \(text(limits.downloadMbps))")
    print("Envoi internet : \(text(limits.uploadMbps))")
    print("Réseau local : \(text(limits.localMbps))")
}

func resolve(_ text: String) async throws -> SyncTask {
    try TaskReference.resolve(text, in: try await client.listTasks())
}

do {
    switch invocation.command {
    case .help:
        print(CtlParser.usage)

    case .status:
        let status = try await client.status()
        show(status, lines: CtlFormatter.statusLines(status))

    case .list:
        let tasks = try await client.listTasks()
        show(tasks, lines: CtlFormatter.taskLines(tasks))

    case .run(let text):
        let task = try await resolve(text)
        try await client.perform(.runNow(task.id))
        print("« \(task.name) » lancée.")

    case .pause(let text):
        let task = try await resolve(text)
        try await client.perform(.pause(task.id))
        print("« \(task.name) » en pause.")

    case .resume(let text):
        let task = try await resolve(text)
        try await client.perform(.resume(task.id))
        print("« \(task.name) » reprise.")

    case .stop(let text):
        let task = try await resolve(text)
        try await client.perform(.stop(task.id))
        print("« \(task.name) » arrêtée.")

    case .approve(let text):
        let task = try await resolve(text)
        try await client.perform(.approveDeletion(task.id))
        print("Suppressions acceptées : « \(task.name) » relancée.")

    case .pauseAll:
        try await client.perform(.setGlobalPause(true))
        print("Pause globale activée (conservée après un redémarrage).")

    case .resumeAll:
        try await client.perform(.setGlobalPause(false))
        print("Pause globale levée.")

    case .history(let text, let limit):
        var id: UUID?
        if let text { id = try await resolve(text).id }
        let records = try await client.history(taskID: id, limit: limit)
        show(records, lines: CtlFormatter.historyLines(records))

    case .watch:
        let names = Dictionary(uniqueKeysWithValues: try await client.listTasks().map { ($0.id, $0.name) })
        let watch = try await client.watch { event in
            if let line = CtlFormatter.eventLine(event, names: names) { print(line); fflush(stdout) }
        }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { watch.cancel(); exit(0) }
        interrupt.resume()
        print("Suivi en direct (Ctrl-C pour quitter)…")
        withExtendedLifetime(interrupt) { RunLoop.main.run() }

    case .add(let new):
        var task = SyncTask(
            name: new.name, source: new.source, destination: new.destination, mode: new.mode, schedule: new.schedule
        )
        task.conditions.requiresACPower = new.requiresACPower
        do {
            try await client.perform(.saveTask(task))
            print("Tâche « \(task.name) » ajoutée (\(CtlFormatter.scheduleDescription(task.schedule))).")
        } catch AgentClientError.unreachable {
            // Sans agent (pas encore installé) : on écrit le fichier, l'agent le lira au démarrage.
            if let problem = TaskValidator.problems(in: task).first { fail(problem.message) }
            try TaskStore(url: paths.tasks).upsert(task)
            print("Tâche « \(task.name) » ajoutée dans tasks.json (agent injoignable : il la lira au démarrage).")
        }

    case .copy(let request):
        let source = URL(fileURLWithPath: request.source), destination = URL(fileURLWithPath: request.destination)
        let what = request.items.isEmpty ? source.lastPathComponent : request.items.joined(separator: ", ")
        var task = SyncTask(
            name: (request.mirror ? "Synchronisation de " : "Copie de ") + "\(what) vers \(destination.lastPathComponent)",
            source: .local(path: source.standardizedFileURL.path), destination: .local(path: destination.standardizedFileURL.path),
            sourceItems: request.items, mode: request.mirror ? .mirror : .copy
        )
        task.notifications = .always
        try await client.perform(.runOnce(task))
        print("« \(task.name) » lancée (suivre avec : syncmacpro-ctl watch).")

    case .version:
        print("SyncMacPro \(AppInfo.version())")

    case .doctor:
        print("SyncMacPro \(AppInfo.version())")
        for engine in [EngineKind.rsync, .rclone] {
            if let path = BinaryLocator.locateForProcess(engine) {
                let line = BinaryLocator.firstLine(of: path, arguments: engine == .rsync ? ["--version"] : ["version"]) ?? ""
                print("\(engine.rawValue) : \(path) — \(line)")
            } else {
                print("\(engine.rawValue) : introuvable")
            }
        }
        do {
            let status = try await client.status()
            print("Agent : répond (\(status.tasks.count) tâche(s), pause globale : \(status.globalPause ? "oui" : "non"))")
        } catch {
            print("Agent : ne répond pas (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))")
        }

    case .remotes:
        let remotes = try await client.listRemotes()
        show(remotes, lines: remotes.isEmpty ? ["Aucune connexion."] : remotes.map { "\($0.name)  (\($0.type))" })

    case .remoteTest(let name):
        let result = try await client.testRemote(name)
        print(result.ok ? "« \(name) » répond." : "« \(name) » ne répond pas : \(result.message ?? "")")
        if !result.ok { exit(1) }

    case .remoteDelete(let name):
        try await client.perform(.deleteRemote(name))
        print("Connexion « \(name) » supprimée.")

    case .remove(let text):
        do {
            let task = try await resolve(text)
            try await client.perform(.removeTask(task.id))
            print("Tâche « \(task.name) » supprimée.")
        } catch AgentClientError.unreachable {
            let store = TaskStore(url: paths.tasks)
            let task = try TaskReference.resolve(text, in: try store.load())
            try store.remove(id: task.id)
            print("Tâche « \(task.name) » supprimée de tasks.json (agent injoignable).")
        }

    case .simulate(let text):
        let task = try await resolve(text)
        print("Simulation de « \(task.name) »…")
        let result = try await client.simulate(task)
        print("\(CtlFormatter.statusLabel(result.status)) : \(result.filesToTransfer) fichier(s) à transférer "
            + "(\(Formatting.bytes(result.bytesToTransfer))), \(result.deletions) suppression(s)."
            + (result.message.map { "\n\($0)" } ?? ""))

    case .queue:
        let status = try await client.status()
        guard let queue = status.queue else { fail("Cet agent ne connaît pas encore la file d'attente (mettez l'app à jour).") }
        let names = Dictionary(status.tasks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        print("File : \(queue.running ? "lancée" : "suspendue")")
        if let current = queue.current { print("En cours : \(names[current] ?? current.uuidString)") }
        if queue.items.isEmpty { print("Aucune tâche en file.") }
        for (index, id) in queue.items.enumerated() { print("\(index + 1). \(names[id] ?? id.uuidString)") }

    case .queueAdd(let text):
        let task = try await resolve(text)
        try await client.perform(.enqueue(task.id))
        print("« \(task.name) » mise en file.")

    case .queueRemove(let text):
        let task = try await resolve(text)
        try await client.perform(.dequeue(task.id))
        print("« \(task.name) » retirée de la file.")

    case .queueMove(let text, let up):
        let task = try await resolve(text)
        guard let items = try await client.status().queue?.items, let index = items.firstIndex(of: task.id) else {
            fail("« \(task.name) » n'est pas dans la file.")
        }
        let target = max(0, min(items.count - 1, index + (up ? -1 : 1)))
        try await client.perform(.moveInQueue(task.id, to: target))
        print("« \(task.name) » : place \(target + 1) sur \(items.count).")

    case .queueRun(let running):
        try await client.perform(.setQueueRunning(running))
        print(running ? "File lancée." : "File suspendue (l'élément en cours se termine).")

    case .bandwidth:
        printBandwidth(try await client.status().bandwidth ?? BandwidthLimits())

    case .setBandwidth(let down, let up, let local):
        var limits = try await client.status().bandwidth ?? BandwidthLimits()
        if let down { limits.downloadMbps = try CtlParser.mbps(down) }
        if let up { limits.uploadMbps = try CtlParser.mbps(up) }
        if let local { limits.localMbps = try CtlParser.mbps(local) }
        try await client.perform(.setBandwidth(limits))
        printBandwidth(limits)

    case .clearHistory(let text):
        var taskID: UUID?
        if let text { taskID = try await resolve(text).id }
        let count = try await client.clearHistory(taskID: taskID)
        print("\(count) exécution(s) supprimée(s) de l'historique (journaux compris).")

    case .log(let text):
        let last: RunRecord
        switch TaskReference.logTarget(text, in: try await client.listTasks()) {
        case .success(let task):
            guard let record = try await client.history(taskID: task.id, limit: 1).first else {
                fail("« \(task.name) » n'a encore jamais tourné.")
            }
            last = record
        case .failure(.notFound):
            // Copie manuelle : pas de tâche, mais une exécution de ce nom.
            guard let record = TaskReference.latestRun(named: text, in: try await client.history(taskID: nil, limit: 500)) else {
                fail("Aucune tâche ni exécution ne correspond à « \(text) ».")
            }
            last = record
        case .failure(let error):
            throw error
        }
        let log = try await client.runLog(runID: last.id)
        if log.truncated { print("(début du journal non affiché)") }
        print(log.text, terminator: "")

    case .agentInstall: print("Agent : \(try AgentRegistration.install())")
    case .agentUninstall: print("Agent : \(try AgentRegistration.uninstall())")
    case .agentStatus: print("Agent : \(try AgentRegistration.status())")
    }
} catch let error as AgentClientError where error == .unreachable {
    fail(error.localizedDescription, code: 69)
} catch {
    fail(error.localizedDescription)
}
