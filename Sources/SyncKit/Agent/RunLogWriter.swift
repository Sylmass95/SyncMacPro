import Foundation

/// Journal d'une exécution : les lignes du moteur, horodatées, plafonné pour ne pas remplir le disque.
public final class RunLogWriter: @unchecked Sendable {
    public static let defaultLimit = 5_000_000

    private let lock = NSLock()
    private let handle: FileHandle?
    private let limit: Int
    private let now: @Sendable () -> Date
    private var written = 0
    private var truncated = false
    private var closed = false
    private var failed = false

    public init(url: URL, limit: Int = RunLogWriter.defaultLimit, now: @escaping @Sendable () -> Date = { Date() }) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        self.limit = limit
        self.now = now
    }

    /// `force` : écrit même au-delà du plafond (la ligne de fin doit toujours y être).
    /// Les lignes de progression du moteur sont ignorées : elles rempliraient le journal sans rien apprendre.
    public func append(_ line: String, force: Bool = false) {
        if !force && Self.isProgress(line) { return }
        write("[\(Self.clock(now()))] \(line)\n", force: force)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle?.close()
    }

    private func write(_ text: String, force: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !closed, !failed else { return }
        let data = Data(text.utf8)
        if !force {
            if truncated { return }
            if written + data.count > limit {
                truncated = true
                put(Data("… journal tronqué (limite de \(limit) octets atteinte)\n".utf8), into: handle)
                return
            }
        }
        put(data, into: handle)
        written += data.count
    }

    /// `write(contentsOf:)` lève une erreur Swift (disque plein…) : l'ancienne API lèverait une exception
    /// Objective-C impossible à rattraper, qui tuerait l'agent et ses copies.
    private func put(_ data: Data, into handle: FileHandle) {
        do { try handle.write(contentsOf: data) } catch { failed = true }
    }

    /// Ligne de progression de rsync (« 3,145,728  42%  12.50MB/s  0:00:03 ») ou statistiques JSON de rclone.
    static func isProgress(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("\"stats\"") { return true }
        return trimmed.range(of: #"^[\d,.]+\s+\d{1,3}%\s"#, options: .regularExpression) != nil
    }

    static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Les `maxBytes` derniers octets, sans ligne coupée au début.
    public static func readTail(url: URL, maxBytes: Int) throws -> RunLogText {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let limit = UInt64(max(1, maxBytes))
        let start = size > limit ? size - limit : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return RunLogText(text: text, truncated: start > 0)
    }
}
