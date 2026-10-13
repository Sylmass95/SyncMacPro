import XCTest
@testable import SyncKit

final class CtlParserTests: XCTestCase {
    func parse(_ arguments: String...) throws -> CtlInvocation { try CtlParser.parse(arguments) }

    func testRemoteCommands() throws {
        XCTAssertEqual(try parse("remotes").command, .remotes)
        XCTAssertEqual(try parse("connexions").command, .remotes)
        XCTAssertEqual(try parse("remote", "test", "Drive").command, .remoteTest("Drive"))
        XCTAssertEqual(try parse("remote", "delete", "Mon Drive").command, .remoteDelete("Mon Drive"))
        XCTAssertThrowsError(try parse("remote", "test"))
        XCTAssertThrowsError(try parse("remote", "rename", "x"))
    }

    func testCopyCommand() throws {
        let invocation = try parse("copy", "--source", "/a", "--dest", "/b", "--item", "x.txt", "--item", "photos")
        XCTAssertEqual(invocation.command, .copy(OneOffRequest(source: "/a", destination: "/b", items: ["x.txt", "photos"], mirror: false)))
        let mirror = try parse("copier", "--source", "/a", "--dest", "/b", "--mirror").command
        XCTAssertEqual(mirror, .copy(OneOffRequest(source: "/a", destination: "/b", items: [], mirror: true)))
        XCTAssertThrowsError(try parse("copy", "--source", "/a"))
    }

    func testSimpleCommandsAndGlobalOptionsAnywhere() throws {
        let invocation = try parse("--json", "status", "--state-dir", "/tmp/x", "--service", "svc")
        XCTAssertEqual(invocation.command, .status)
        XCTAssertTrue(invocation.json)
        XCTAssertEqual(invocation.stateDirectory, "/tmp/x")
        XCTAssertEqual(invocation.service, "svc")
    }

    func testFrenchAliases() throws {
        XCTAssertEqual(try parse("statut").command, .status)
        XCTAssertEqual(try parse("liste").command, .list)
        XCTAssertEqual(try parse("lancer", "nuit").command, .run("nuit"))
        XCTAssertEqual(try parse("reprendre", "nuit").command, .resume("nuit"))
        XCTAssertEqual(try parse("arreter", "nuit").command, .stop("nuit"))
        XCTAssertEqual(try parse("valider", "nuit").command, .approve("nuit"))
        XCTAssertEqual(try parse("pause-tout").command, .pauseAll)
        XCTAssertEqual(try parse("reprendre-tout").command, .resumeAll)
        XCTAssertEqual(try parse("aide").command, .help)
    }

    func testTaskCommandsNeedATask() {
        XCTAssertThrowsError(try parse("run")) { XCTAssertEqual($0 as? CtlParseError, .missingValue("tâche")) }
        XCTAssertThrowsError(try parse("pause"))
    }

    func testHistoryTakesAnOptionalTaskAndLimit() throws {
        XCTAssertEqual(try parse("history").command, .history(nil, limit: 20))
        XCTAssertEqual(try parse("history", "nuit", "--limit", "5").command, .history("nuit", limit: 5))
    }

    func testAgentSubcommands() throws {
        XCTAssertEqual(try parse("agent", "install").command, .agentInstall)
        XCTAssertEqual(try parse("agent", "uninstall").command, .agentUninstall)
        XCTAssertEqual(try parse("agent", "status").command, .agentStatus)
        XCTAssertThrowsError(try parse("agent"))
        XCTAssertThrowsError(try parse("agent", "danser"))
    }

    func testAddBuildsATask() throws {
        let invocation = try parse(
            "add", "--name", "Nuit", "--source", "/a", "--dest", "/b", "--mode", "mirror", "--daily", "03:30", "--ac-power"
        )
        guard case .add(let task) = invocation.command else { return XCTFail("attendu : add") }
        XCTAssertEqual(task.name, "Nuit")
        XCTAssertEqual(task.source, .local(path: "/a"))
        XCTAssertEqual(task.destination, .local(path: "/b"))
        XCTAssertEqual(task.mode, .mirror)
        XCTAssertEqual(task.schedule, .daily(hour: 3, minute: 30))
        XCTAssertTrue(task.requiresACPower)
    }

    func testAddParsesCloudEndpointsAndIntervals() throws {
        let invocation = try parse("add", "--name", "n", "--source", "/a", "--dest", "drive:Sauvegardes/NAS", "--every", "15")
        guard case .add(let task) = invocation.command else { return XCTFail("attendu : add") }
        XCTAssertEqual(task.destination, .cloud(remote: "drive", path: "Sauvegardes/NAS"))
        XCTAssertEqual(task.schedule, .everyMinutes(15))
    }

    func testAddRejectsInvalidInput() {
        XCTAssertThrowsError(try parse("add", "--name", "n", "--source", "/a"))
        XCTAssertThrowsError(try parse("add", "--name", "n", "--source", "/a", "--dest", "/b", "--daily", "25:99"))
        XCTAssertThrowsError(try parse("add", "--name", "n", "--source", "/a", "--dest", "/b", "--every", "5", "--daily", "03:00"))
        XCTAssertThrowsError(try parse("add", "--name", "n", "--source", "/a", "--dest", "/b", "--mode", "inconnu"))
    }

    func testSimulateAndLogCommands() throws {
        XCTAssertEqual(try parse("simulate", "nuit").command, .simulate("nuit"))
        XCTAssertEqual(try parse("simuler", "nuit").command, .simulate("nuit"))
        XCTAssertEqual(try parse("log", "nuit").command, .log("nuit"))
        XCTAssertEqual(try parse("journal", "nuit").command, .log("nuit"))
        XCTAssertThrowsError(try parse("log"))
    }

    func testUnknownCommandAndOption() {
        XCTAssertThrowsError(try parse("danser")) { XCTAssertEqual($0 as? CtlParseError, .unknownCommand("danser")) }
        XCTAssertThrowsError(try parse("status", "--bizarre"))
        XCTAssertThrowsError(try CtlParser.parse([])) { XCTAssertEqual($0 as? CtlParseError, .missingCommand) }
    }
}

final class TaskReferenceTests: XCTestCase {
    let tasks = [makeTask("Archives NAS"), makeTask("Archives Drive"), makeTask("Photos")]

    func testExactNameIgnoringCase() throws {
        XCTAssertEqual(try TaskReference.resolve("photos", in: tasks).name, "Photos")
    }

    func testUniquePrefix() throws {
        XCTAssertEqual(try TaskReference.resolve("pho", in: tasks).name, "Photos")
    }

    func testAmbiguousPrefix() {
        XCTAssertThrowsError(try TaskReference.resolve("arch", in: tasks)) {
            guard case .ambiguous = $0 as? TaskReferenceError else { return XCTFail("attendu : ambiguë") }
        }
    }

    func testNotFound() {
        XCTAssertThrowsError(try TaskReference.resolve("zzz", in: tasks)) {
            XCTAssertEqual($0 as? TaskReferenceError, .notFound("zzz"))
        }
    }

    func testByFullIdentifierAndIdentifierPrefix() throws {
        let id = tasks[2].id.uuidString
        XCTAssertEqual(try TaskReference.resolve(id, in: tasks).name, "Photos")
        XCTAssertEqual(try TaskReference.resolve(String(id.prefix(8)), in: tasks).name, "Photos")
    }
}

final class CtlFormatterTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testScheduleDescriptions() {
        XCTAssertEqual(CtlFormatter.scheduleDescription(.manual), "manuelle")
        XCTAssertEqual(CtlFormatter.scheduleDescription(.daily(hour: 3, minute: 5)), "tous les jours à 03:05")
        XCTAssertEqual(CtlFormatter.scheduleDescription(.everyMinutes(15)), "toutes les 15 min")
        XCTAssertEqual(CtlFormatter.scheduleDescription(.weekdays(days: [2, 6], hour: 8, minute: 0)), "lun, ven à 08:00")
        XCTAssertEqual(CtlFormatter.scheduleDescription(.whenAvailable), "dès que disponible")
    }

    func testStatusShowsPauseWarningsAndTasks() {
        let task = makeTask("Nuit")
        let record = RunRecord(
            taskID: task.id, taskName: "Nuit", engine: .rsync, mode: .copy,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000), status: .succeeded
        )
        let status = AgentStatus(
            globalPause: true, stateRecovered: true, taskLoadError: "boum",
            tasks: [AgentTaskInfo(
                id: task.id, name: "Nuit", state: .waiting(reason: "réseau indisponible"),
                nextDue: Date(timeIntervalSince1970: 1_760_086_400), lastRun: record
            )]
        )
        let text = CtlFormatter.statusLines(status, timeZone: utc).joined(separator: "\n")
        XCTAssertTrue(text.contains("Pause globale : oui"))
        XCTAssertTrue(text.contains("illisible"))
        XCTAssertTrue(text.contains("boum"))
        XCTAssertTrue(text.contains("Nuit"))
        XCTAssertTrue(text.contains("en attente (réseau indisponible)"))
        XCTAssertTrue(text.contains("réussie"))
    }

    func testEventLines() {
        let id = UUID()
        let names = [id: "Nuit"]
        XCTAssertEqual(CtlFormatter.eventLine(.taskStarted(id), names: names), "▶ Nuit démarre")
        XCTAssertEqual(CtlFormatter.eventLine(.taskFinished(id, .failed, "disque plein"), names: names), "■ Nuit : échec — disque plein")
        XCTAssertNotNil(CtlFormatter.eventLine(.stateChanged, names: names))
    }

    func testJSONOutputIsStable() {
        let text = CtlFormatter.json(AgentTaskInfo(id: UUID(), name: "a", state: .idle))
        XCTAssertTrue(text.contains("\"name\" : \"a\""))
    }
}
