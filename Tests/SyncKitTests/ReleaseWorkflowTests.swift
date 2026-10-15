import XCTest

/// Sous-projet 8 : la publication joint un flux de mise à jour signé ; rien ne part sans les clés.
final class ReleaseWorkflowTests: IntegrationTestCase {
    static let root = AppBundleSparkleTests.root

    func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Le job de publication, de « publish: » à la fin du fichier.
    func publishJob() throws -> String {
        let workflow = try text(".github/workflows/release.yml")
        let start = try XCTUnwrap(workflow.range(of: "\n  publish:"))
        return String(workflow[start.lowerBound...])
    }

    func testPublicationProducesASignedFeed() throws {
        let job = try publishJob()
        XCTAssertTrue(job.contains("runs-on: macos-14"), "les outils de Sparkle sont des programmes macOS")
        XCTAssertTrue(job.contains("scripts/fetch-sparkle-tools.sh"))
        XCTAssertTrue(job.contains("scripts/make-appcast.sh"))
        XCTAssertTrue(job.contains("secrets.SPARKLE_ED_PRIVATE_KEY"))
        XCTAssertTrue(job.contains("umask 077"), "clé écrite dans un fichier privé")
        XCTAssertTrue(job.contains("rm -f \"$KEY\""), "fichier de la clé supprimé")
        XCTAssertTrue(job.contains("[ -n \"$SPARKLE_ED_PRIVATE_KEY\" ]"), "publication refusée sans clé")
        let create = try XCTUnwrap(job.components(separatedBy: "\n").first { $0.contains("gh release create") })
        XCTAssertTrue(create.contains("appcast.xml"), create)
    }

    func testCIFetchesTheTools() throws {
        XCTAssertTrue(try text(".github/workflows/ci.yml").contains("scripts/fetch-sparkle-tools.sh"))
    }

    func testReleaseBuildRefusesToStartWithoutThePublicKey() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.root.appendingPathComponent("scripts/make-release.sh").path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SPARKLE_PUBLIC_KEY": "", "SPARKLE_PUBLIC_KEY_FILE": sandbox.appendingPathComponent("absente.txt").path,
        ]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let started = Date()
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.lowercased().contains("clé publique"), output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "refus avant toute construction")
    }
}
