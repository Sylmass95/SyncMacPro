import XCTest
@testable import SyncKit

/// 1.8.3 : ce qui se fait après la copie (vérification, réparation d'une copie vide, liste de l'archive) n'est plus arrêté
/// d'office. Avant, l'arrêt des processus annexes à la fin de la copie tuait aussi la vérification après copie, qui
/// passait pour réussie sans avoir rien vérifié.
final class Aux183Tests: IntegrationTestCase {
    func testTheVerificationAfterACopyReallyRuns() async throws {
        let real = try rsyncPath()
        let calls = sandbox.appendingPathComponent("calls.txt").path
        let wrapper = sandbox.appendingPathComponent("rsync").path
        // Sans `exec` : la ligne « fini » n'est écrite que si rsync est allé au bout.
        try "#!/bin/sh\n'\(real)' \"$@\"\ncode=$?\necho \"fini $*\" >> '\(calls)'\nexit $code\n".write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        let runner = TaskRunner(configuration: RunnerConfiguration(rsyncPath: wrapper, workDirectory: sandbox.appendingPathComponent("w"), sampleInterval: 0.05))
        let source = try folder("s"), destination = try folder("d")
        try write(source + "/a.txt", "a")
        var copy = SyncTask(name: "t", source: .local(path: source), destination: .local(path: destination))
        copy.options.excludes = []
        copy.options.verifyAfterCopy = true
        let result = try await runner.run(copy)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertTrue((read(calls) ?? "").split(separator: "\n").contains { $0.contains("-rcn") }, "la vérification est allée au bout")
    }

    func testAuxiliaryProcessesCanStartAgainAfterTheCopy() async throws {
        let control = RunControl()
        control.stopAuxiliary()
        control.allowAuxiliary()
        let process = try ProcessRunner.spawn(executable: "/bin/sh", arguments: ["-c", "sleep 0.3; exit 0"]) { _ in }
        control.registerAuxiliary(process)
        let code = await process.waitForExit()
        XCTAssertEqual(code, 0)
    }
}
