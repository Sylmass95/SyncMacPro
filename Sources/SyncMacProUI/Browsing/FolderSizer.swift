import Foundation

public struct SizeTotal: Equatable, Sendable {
    public var bytes: Int64 = 0
    public var files = 0
    public var folders = 0

    public init(bytes: Int64 = 0, files: Int = 0, folders: Int = 0) {
        self.bytes = bytes
        self.files = files
        self.folders = folders
    }
}

/// Taille d'une sélection. À appeler hors du fil principal ; s'arrête dès que la tâche courante est annulée.
/// Les liens symboliques ne sont ni suivis ni comptés (rsync les copie comme liens).
public enum FolderSizer {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    public static func total(of urls: [URL]) throws -> SizeTotal {
        var total = SizeTotal()
        for url in urls {
            try Task.checkCancellation()
            add(url, to: &total)
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                  let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
            else { continue }
            var count = 0
            for case let child as URL in enumerator {
                count += 1
                if count % 200 == 0 { try Task.checkCancellation() }
                add(child, to: &total)
            }
        }
        return total
    }

    private static func add(_ url: URL, to total: inout SizeTotal) {
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isSymbolicLink == true { return }
        if values?.isDirectory == true {
            total.folders += 1
        } else {
            total.files += 1
            total.bytes += Int64(values?.fileSize ?? 0)
        }
    }
}
