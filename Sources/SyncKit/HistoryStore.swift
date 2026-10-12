import Foundation
import SQLite3

public enum HistoryError: Error, Equatable {
    case openFailed(String)
    case queryFailed(String)
}

/// Historique des exécutions, dans une base SQLite. Sûr à utiliser depuis plusieurs threads.
public final class HistoryStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        if sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "inconnue"
            sqlite3_close(database)
            throw HistoryError.openFailed(message)
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                task_name TEXT NOT NULL,
                engine TEXT NOT NULL,
                mode TEXT NOT NULL,
                dry_run INTEGER NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL,
                status TEXT NOT NULL,
                summary TEXT,
                log_path TEXT
            );
            CREATE INDEX IF NOT EXISTS runs_task ON runs(task_id, started_at DESC);
            """)
    }

    deinit { sqlite3_close(database) }

    // MARK: écriture

    /// Ajoute l'exécution, ou la remplace si son identifiant existe déjà.
    public func save(_ record: RunRecord) throws {
        let summary = try record.summary.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try withStatement("""
            INSERT OR REPLACE INTO runs
            (id, task_id, task_name, engine, mode, dry_run, started_at, finished_at, status, summary, log_path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(statement, 1, record.id.uuidString)
            bind(statement, 2, record.taskID.uuidString)
            bind(statement, 3, record.taskName)
            bind(statement, 4, record.engine.rawValue)
            bind(statement, 5, record.mode.rawValue)
            sqlite3_bind_int(statement, 6, record.dryRun ? 1 : 0)
            sqlite3_bind_double(statement, 7, record.startedAt.timeIntervalSince1970)
            bind(statement, 8, record.finishedAt?.timeIntervalSince1970)
            bind(statement, 9, record.status.rawValue)
            bind(statement, 10, summary)
            bind(statement, 11, record.logPath)
            try step(statement)
        }
    }

    /// Au démarrage de l'agent : tout ce qui était « en cours » a été interrompu. Retourne le nombre de lignes.
    @discardableResult
    public func markRunningAsInterrupted(at date: Date = Date()) throws -> Int {
        try withStatement("UPDATE runs SET status = 'interrupted', finished_at = ? WHERE status = 'running'") { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try step(statement)
            return Int(sqlite3_changes(database))
        }
    }

    /// Supprime les exécutions terminées avant `date`. Retourne le nombre de lignes supprimées.
    @discardableResult
    public func purge(finishedBefore date: Date) throws -> Int {
        try withStatement("DELETE FROM runs WHERE finished_at IS NOT NULL AND finished_at < ?") { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try step(statement)
            return Int(sqlite3_changes(database))
        }
    }

    // MARK: lecture

    public func record(id: UUID) throws -> RunRecord? {
        try query("SELECT * FROM runs WHERE id = ?") { bind($0, 1, id.uuidString) }.first
    }

    /// Les plus récentes d'abord.
    public func list(taskID: UUID? = nil, limit: Int = 100) throws -> [RunRecord] {
        if let taskID {
            return try query("SELECT * FROM runs WHERE task_id = ? ORDER BY started_at DESC LIMIT ?") {
                bind($0, 1, taskID.uuidString)
                sqlite3_bind_int($0, 2, Int32(limit))
            }
        }
        return try query("SELECT * FROM runs ORDER BY started_at DESC LIMIT ?") { sqlite3_bind_int($0, 1, Int32(limit)) }
    }

    // MARK: SQLite

    private func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "inconnue"
            sqlite3_free(error)
            throw HistoryError.queryFailed(message)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw HistoryError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, HistoryStore.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func query(_ sql: String, binding: (OpaquePointer) -> Void) throws -> [RunRecord] {
        try withStatement(sql) { statement in
            binding(statement)
            var records: [RunRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let record = decode(statement) { records.append(record) }
            }
            return records
        }
    }

    private func decode(_ statement: OpaquePointer) -> RunRecord? {
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        guard let id = text(0).flatMap(UUID.init(uuidString:)), let taskID = text(1).flatMap(UUID.init(uuidString:)),
              let name = text(2), let engine = text(3).flatMap(EngineKind.init(rawValue:)),
              let mode = text(4).flatMap(SyncMode.init(rawValue:)), let status = text(8).flatMap(RunStatus.init(rawValue:))
        else { return nil }
        let finished: Date? = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let summary = text(9).flatMap { try? JSONDecoder().decode(RunSummary.self, from: Data($0.utf8)) }
        return RunRecord(
            id: id, taskID: taskID, taskName: name, engine: engine, mode: mode,
            dryRun: sqlite3_column_int(statement, 5) != 0,
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            finishedAt: finished, status: status, summary: summary, logPath: text(10)
        )
    }
}
