import XCTest

/// Sous-projet 8 : l'app assemblée embarque Sparkle, en mode strict (essai du 15/10 : sans lui, une mise à jour
/// falsifiée passe entre deux apps signées ad hoc).
final class AppBundleSparkleTests: IntegrationTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Dossier des produits compilés (celui du paquet de tests) : exécutables, ressources et `Sparkle.framework`.
    var productsDirectory: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    }

    @discardableResult
    func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], in directory: URL? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    func assemble(publicKey: String?, script: URL = AppBundleSparkleTests.root.appendingPathComponent("scripts/assemble-app.sh")) throws -> (Int32, String, URL) {
        let bin = productsDirectory
        for needed in ["SyncMacPro", "syncmacpro-ctl", "syncmacpro-agent", "Sparkle.framework"]
        where !FileManager.default.fileExists(atPath: bin.appendingPathComponent(needed).path) {
            throw XCTSkip("\(needed) absent de \(bin.path) : lancez « swift build » avant les tests")
        }
        let app = sandbox.appendingPathComponent("SyncMacPro.app")
        var environment = ["SPARKLE_PUBLIC_KEY": publicKey ?? ""]
        if publicKey == nil { environment["SPARKLE_PUBLIC_KEY_FILE"] = sandbox.appendingPathComponent("absente.txt").path }
        let (code, output) = try run("/bin/bash", [script.path, bin.path, app.path, "9.9.9", "1"], environment: environment)
        return (code, output, app)
    }

    func plist(_ app: URL, _ key: String) throws -> String {
        try run("/usr/libexec/PlistBuddy", ["-c", "Print :\(key)", app.appendingPathComponent("Contents/Info.plist").path]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAssembledAppEmbedsSparkleInStrictMode() throws {
        let (code, output, app) = try assemble(publicKey: "dGVzdA==")
        XCTAssertEqual(code, 0, output)
        let framework = app.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        XCTAssertTrue(FileManager.default.fileExists(atPath: framework.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: framework.appendingPathComponent("Versions/B/XPCServices").path),
                       "services XPC inutiles hors bac à sable")
        let loads = try run("/usr/bin/otool", ["-l", app.appendingPathComponent("Contents/MacOS/SyncMacPro").path]).1
        XCTAssertTrue(loads.contains("@executable_path/../Frameworks"))
        XCTAssertEqual(try plist(app, "SUVerifyUpdateBeforeExtraction"), "true")
        XCTAssertEqual(try plist(app, "SURequireSignedFeed"), "true")
        XCTAssertEqual(try plist(app, "SUEnableAutomaticChecks"), "true")
        XCTAssertEqual(try plist(app, "SUPublicEDKey"), "dGVzdA==")
        XCTAssertEqual(try plist(app, "SUFeedURL"), "https://github.com/Sylmass95/SyncMacPro/releases/latest/download/appcast.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/Licenses/Sparkle-LICENSE.txt").path))
        let verify = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        XCTAssertEqual(verify.0, 0, verify.1)
    }

    func testAssemblyRefusesAnAppWithoutThePublicKey() throws {
        let (code, output, _) = try assemble(publicKey: nil)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(output.lowercased().contains("clé publique"), output)
    }
}
