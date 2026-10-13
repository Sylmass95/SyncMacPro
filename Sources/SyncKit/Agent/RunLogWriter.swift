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

    public init(url: URL, limit: Int = RunLogWriter.defaultLimit, now: @escaping @Sendable () -> Date = { Date() }) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        self.limit = limit
        self.now = now
    }

    public func append(_ line: String) {
        write("[\(Self.clock(now()))] \(line)\n")
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
    }

    private func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !truncated else { return }
        let data = Data(text.utf8)
        if written + data.count > limit {
            truncated = true
            handle.write(Data("… journal tronqué (limite de \(limit) octets atteinte)\n".utf8))
            return
        }
        handle.write(data)
        written += data.count
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
