import CryptoKit
import XCTest

/// Sous-projet 8 : le flux de mise à jour produit à la publication (scripts/make-appcast.sh).
final class AppcastScriptTests: IntegrationTestCase {
    static let root = AppBundleSparkleTests.root
    var tools: URL { Self.root.appendingPathComponent(".build/sparkle-tools/bin") }

    func requireTools() throws {
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("sign_update").path) else {
            if ProcessInfo.processInfo.environment["CI"] != nil { XCTFail("outils de Sparkle absents : scripts/fetch-sparkle-tools.sh") }
            throw XCTSkip("outils de Sparkle absents : lancez scripts/fetch-sparkle-tools.sh")
        }
    }

    @discardableResult
    func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    /// DMG d'essai : une app factice (build 42, version 1.6.0), comme le DMG publié.
    func makeDMG() throws -> URL {
        let stage = sandbox.appendingPathComponent("stage")
        let contents = stage.appendingPathComponent("SyncMacPro.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/SyncMacPro"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.sylvain.syncmacpro", "CFBundleVersion": "42", "CFBundleShortVersionString": "1.6.0",
            "CFBundleExecutable": "SyncMacPro", "LSMinimumSystemVersion": "14.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let dmg = sandbox.appendingPathComponent("SyncMacPro-1.6.0.dmg")
        let (code, output) = try run("/usr/bin/hdiutil", ["create", "-volname", "SyncMacPro 1.6.0", "-srcfolder", stage.path, "-ov", "-format", "UDZO", dmg.path])
        XCTAssertEqual(code, 0, output)
        return dmg
    }

    func makeKey() throws -> (URL, Curve25519.Signing.PublicKey) {
        let key = Curve25519.Signing.PrivateKey()
        let file = sandbox.appendingPathComponent("cle.txt")
        try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: file)
        return (file, key.publicKey)
    }

    func makeAppcast(_ dmg: URL, _ key: URL?) throws -> (Int32, String, URL) {
        let out = sandbox.appendingPathComponent("appcast.xml")
        let script = Self.root.appendingPathComponent("scripts/make-appcast.sh").path
        let (code, output) = try run("/bin/bash", [script, dmg.path, key?.path ?? sandbox.appendingPathComponent("absente.txt").path, out.path],
                                     environment: ["SPARKLE_TOOLS": tools.path])
        return (code, output, out)
    }

    func value(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    func testFeedDescribesAndSignsThePublishedDMG() throws {
        try requireTools()
        let dmg = try makeDMG()
        let (key, publicKey) = try makeKey()
        let (code, output, out) = try makeAppcast(dmg, key)
        XCTAssertEqual(code, 0, output)
        let feed = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(value("<sparkle:version>([^<]+)</sparkle:version>", in: feed), "42")
        XCTAssertEqual(value("<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>", in: feed), "1.6.0")
        XCTAssertEqual(value("<sparkle:minimumSystemVersion>([^<]+)</sparkle:minimumSystemVersion>", in: feed), "14.0")
        XCTAssertEqual(value("url=\"([^\"]+)\"", in: feed),
                       "https://github.com/Sylmass95/SyncMacPro/releases/download/v1.6.0/SyncMacPro-1.6.0.dmg")
        let data = try Data(contentsOf: dmg)
        XCTAssertEqual(value("length=\"([0-9]+)\"", in: feed), String(data.count))
        let signature = try XCTUnwrap(value("sparkle:edSignature=\"([^\"]+)\"", in: feed).flatMap { Data(base64Encoded: $0) })
        XCTAssertTrue(publicKey.isValidSignature(signature, for: data), "signature EdDSA du DMG")
        XCTAssertTrue(feed.contains("edSignature:"), "flux signé (SURequireSignedFeed)")
        let tools = self.tools.appendingPathComponent("sign_update").path
        XCTAssertEqual(try run(tools, ["--verify", "--ed-key-file", key.path, out.path]).0, 0)
    }

    func testTamperedFeedOrDMGFailsVerification() throws {
        try requireTools()
        let dmg = try makeDMG()
        let (key, _) = try makeKey()
        let (code, output, out) = try makeAppcast(dmg, key)
        XCTAssertEqual(code, 0, output)
        let signUpdate = tools.appendingPathComponent("sign_update").path
        var feed = try String(contentsOf: out, encoding: .utf8)
        let signature = try XCTUnwrap(value("sparkle:edSignature=\"([^\"]+)\"", in: feed))
        let handle = try FileHandle(forWritingTo: dmg)
        handle.seekToEndOfFile(); handle.write(Data("falsifié".utf8)); try handle.close()
        XCTAssertNotEqual(try run(signUpdate, ["--verify", "--ed-key-file", key.path, dmg.path, signature]).0, 0)
        feed = feed.replacingOccurrences(of: "<sparkle:version>42", with: "<sparkle:version>99")
        try feed.write(to: out, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try run(signUpdate, ["--verify", "--ed-key-file", key.path, out.path]).0, 0)
    }

    func testMissingKeyStopsThePublication() throws {
        try requireTools()
        let (code, output, _) = try makeAppcast(try makeDMG(), nil)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(output.lowercased().contains("clé privée"), output)
    }
}
