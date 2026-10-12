import Foundation

/// Accès aux fichiers de référence (sorties réelles de rsync 3.5.1 et rclone 1.75).
enum Fixture {
    static func text(_ name: String, ext: String = "txt") throws -> String {
        let url = try XCTUnwrapURL(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func XCTUnwrapURL(_ url: URL?) throws -> URL {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
}
