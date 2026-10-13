import Foundation

public struct DirectoryItem: Identifiable, Hashable, Sendable {
    public var url: URL
    public var name: String
    /// Vrai pour un dossier dans lequel on peut entrer ; un paquet (.app) est un fichier.
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    public var isHidden: Bool
    public var id: URL { url }

    public init(url: URL, name: String, isDirectory: Bool, size: Int64?, modified: Date?, isHidden: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isHidden = isHidden
    }
}

public enum DirectoryLister {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
    ]

    /// Dossiers d'abord, puis fichiers, par nom (ordre du Finder).
    public static func list(_ folder: URL, showHidden: Bool) throws -> [DirectoryItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles]
        )
        let items = urls.map { url -> DirectoryItem in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            return DirectoryItem(
                url: url, name: url.lastPathComponent, isDirectory: isDirectory,
                size: isDirectory ? nil : values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                isHidden: values?.isHidden ?? url.lastPathComponent.hasPrefix(".")
            )
        }
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
