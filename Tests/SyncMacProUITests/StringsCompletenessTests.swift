import XCTest
@testable import SyncMacProUI

final class StringsCompletenessTests: XCTestCase {
    var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SyncMacProUI/Resources")
    }

    func strings(_ language: String) throws -> [String: String] {
        let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: String], "\(language) : fichier .strings illisible")
    }

    func testBothLanguagesHaveTheSameKeys() throws {
        let fr = try strings("fr"), en = try strings("en")
        XCTAssertEqual(Set(fr.keys).subtracting(en.keys).sorted(), [], "clés sans traduction anglaise")
        XCTAssertEqual(Set(en.keys).subtracting(fr.keys).sorted(), [], "clés sans texte français")
    }

    func testNoValueIsEmpty() throws {
        for language in ["fr", "en"] {
            for (key, value) in try strings(language) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) : « \(key) » est vide")
            }
        }
    }

    func testFormatPlaceholdersMatchBetweenLanguages() throws {
        func placeholders(_ text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dfs]")
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        let fr = try strings("fr"), en = try strings("en")
        for (key, value) in fr {
            XCTAssertEqual(placeholders(value), placeholders(en[key] ?? ""), "« \(key) » : arguments différents entre fr et en")
        }
    }

    func testEveryKeyUsedInTheCodeExists() throws {
        let fr = try strings("fr")
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SyncMacProUI")
        // Toute chaîne qui ressemble à une clé (préfixe connu + point), y compris celles passées à une fonction d'aide.
        let regex = try NSRegularExpression(
            pattern: #""((?:app|sidebar|state|status|mode|schedule|weekday|relative|next|last|summary|unit|progress|connection|banner|dashboard|card|menubar|history|settings|agent|onboarding|alert|editor|notify|warning|simulation|problem|template|tasks|log|copy|confirm|oneoff|connections|wizard|service|remote|update)\.[A-Za-z0-9._]+)""#
        )
        var used = Set<String>()
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                used.insert(String(code[Range(match.range(at: 1), in: code)!]))
            }
        }
        XCTAssertEqual(used.subtracting(fr.keys).sorted(), [], "clés utilisées mais absentes des fichiers de chaînes")
    }
}
