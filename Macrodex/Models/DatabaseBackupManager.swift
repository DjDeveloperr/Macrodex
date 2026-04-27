import CryptoKit
import Foundation
import SQLite3

struct DatabaseBackupSummary: Identifiable, Codable, Hashable {
    struct Delta: Codable, Hashable {
        var fileName: String
        var createdAt: Date
        var fromSequence: Int64
        var toSequence: Int64
        var byteCount: Int64
        var checksum: String
        var cloudUploadedAt: Date?
    }

    var id: UUID
    var createdAt: Date
    var baseFileName: String
    var baseByteCount: Int64
    var baseChecksum: String
    var schemaVersion: Int
    var appBuild: String
    var highWaterSequence: Int64
    var deltas: [Delta]
    var note: String?
    var cloudRecordName: String?
    var cloudUploadedAt: Date?

    var totalByteCount: Int64 {
        baseByteCount + deltas.reduce(Int64(0)) { $0 + $1.byteCount }
    }

    var displayName: String {
        Self.displayFormatter.string(from: createdAt)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct DatabaseBackupOverview: Equatable {
    var backups: [DatabaseBackupSummary] = []
    var automaticBackupsEnabled: Bool = true
    var cloudBackupsEnabled: Bool = false
    var lastBackupDate: Date?
    var storageBytes: Int64 = 0
    var status: String = "Ready"
}

enum DatabaseBackupError: LocalizedError {
    case missingDatabase
    case missingBackup
    case sqlite(String)
    case cloudUnavailable

    var errorDescription: String? {
        switch self {
        case .missingDatabase:
            return "The database has not been created yet."
        case .missingBackup:
            return "The selected backup could not be found."
        case .sqlite(let message):
            return message
        case .cloudUnavailable:
            return "iCloud is not available for this account or build."
        }
    }
}

actor DatabaseBackupManager {
    static let shared = DatabaseBackupManager()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let defaults = UserDefaults.standard

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    var databaseURL: URL {
        codexDirectory.appendingPathComponent("db.sqlite")
    }

    var codexDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("home", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
    }

    private var backupDirectory: URL {
        codexDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    private var baseDirectory: URL {
        backupDirectory.appendingPathComponent("base", isDirectory: true)
    }

    private var deltaDirectory: URL {
        backupDirectory.appendingPathComponent("deltas", isDirectory: true)
    }

    private var indexURL: URL {
        backupDirectory.appendingPathComponent("backup-index.json")
    }

    private var automaticDefaultsKey: String { "databaseBackups.automaticEnabled" }
    func overview() async -> DatabaseBackupOverview {
        do {
            let backups = try loadIndex()
            return DatabaseBackupOverview(
                backups: backups.sorted { $0.createdAt > $1.createdAt },
                automaticBackupsEnabled: automaticBackupsEnabled,
                cloudBackupsEnabled: cloudBackupsEnabled,
                lastBackupDate: backups.map(\.createdAt).max(),
                storageBytes: storageBytes(),
                status: "Ready"
            )
        } catch {
            return DatabaseBackupOverview(status: error.localizedDescription)
        }
    }

    var automaticBackupsEnabled: Bool {
        get {
            if defaults.object(forKey: automaticDefaultsKey) == nil { return true }
            return defaults.bool(forKey: automaticDefaultsKey)
        }
        set { defaults.set(newValue, forKey: automaticDefaultsKey) }
    }

    var cloudBackupsEnabled: Bool {
        get { false }
        set {}
    }

    func setAutomaticBackupsEnabled(_ enabled: Bool) {
        automaticBackupsEnabled = enabled
    }

    func setCloudBackupsEnabled(_ enabled: Bool) {
        cloudBackupsEnabled = false
    }

    func configureIfNeeded() async {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }
        do {
            try prepareDirectories()
            try installChangeLogging()
            if automaticBackupsEnabled {
                try await createBackupIfNeeded(reason: "Launch", minimumInterval: 24 * 60 * 60)
            }
        } catch {
            LLog.warn("backup", "backup configuration failed", fields: ["error": error.localizedDescription])
        }
    }

    func handleBackground() async {
        guard automaticBackupsEnabled else { return }
        do {
            try await createIncrementalBackup(reason: "Background")
            if cloudBackupsEnabled {
                try await uploadPendingBackups()
            }
        } catch {
            LLog.warn("backup", "background backup failed", fields: ["error": error.localizedDescription])
        }
    }

    @discardableResult
    func createBackup(reason: String) async throws -> DatabaseBackupSummary {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw DatabaseBackupError.missingDatabase
        }
        try installChangeLogging()

        var backups = try loadIndex()
        let createdAt = Date()
        let id = UUID()
        let baseName = "base-\(timestamp(createdAt))-\(id.uuidString).sqlite"
        let baseURL = baseDirectory.appendingPathComponent(baseName)
        try copyConsistentDatabase(to: baseURL)

        let summary = DatabaseBackupSummary(
            id: id,
            createdAt: createdAt,
            baseFileName: baseName,
            baseByteCount: byteCount(at: baseURL),
            baseChecksum: try checksum(of: baseURL),
            schemaVersion: try schemaVersion(),
            appBuild: appBuild,
            highWaterSequence: try currentChangeSequence(),
            deltas: [],
            note: reason,
            cloudRecordName: nil,
            cloudUploadedAt: nil
        )
        backups.append(summary)
        backups = prune(backups)
        try saveIndex(backups)
        return summary
    }

    @discardableResult
    func createIncrementalBackup(reason: String) async throws -> DatabaseBackupSummary {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw DatabaseBackupError.missingDatabase
        }
        try installChangeLogging()

        var backups = try loadIndex()
        guard var latest = backups.sorted(by: { $0.createdAt > $1.createdAt }).first else {
            return try await createBackup(reason: reason)
        }

        let currentSequence = try currentChangeSequence()
        guard currentSequence > latest.highWaterSequence else {
            return latest
        }

        let rows = try changeRows(after: latest.highWaterSequence, through: currentSequence)
        let createdAt = Date()
        let deltaName = "delta-\(timestamp(createdAt))-\(latest.id.uuidString).jsonl"
        let deltaURL = deltaDirectory.appendingPathComponent(deltaName)
        let payload = rows.map { row -> String in
            let data = try! encoder.encode(row)
            return String(data: data, encoding: .utf8) ?? "{}"
        }.joined(separator: "\n")
        try payload.write(to: deltaURL, atomically: true, encoding: .utf8)

        let delta = DatabaseBackupSummary.Delta(
            fileName: deltaName,
            createdAt: createdAt,
            fromSequence: latest.highWaterSequence + 1,
            toSequence: currentSequence,
            byteCount: byteCount(at: deltaURL),
            checksum: try checksum(of: deltaURL),
            cloudUploadedAt: nil
        )
        latest.highWaterSequence = currentSequence
        latest.deltas.append(delta)
        latest.note = reason

        backups.removeAll { $0.id == latest.id }
        backups.append(latest)
        try saveIndex(backups)

        if latest.deltas.count >= 24 || latest.totalByteCount > 8_000_000 {
            return try await createBackup(reason: "Compacted")
        }
        return latest
    }

    func createBackupIfNeeded(reason: String, minimumInterval: TimeInterval) async throws {
        let backups = try loadIndex()
        if let last = backups.map(\.createdAt).max(), Date().timeIntervalSince(last) < minimumInterval {
            try await createIncrementalBackup(reason: reason)
        } else {
            try await createBackup(reason: reason)
        }
    }

    func deleteBackup(id: DatabaseBackupSummary.ID) async throws {
        var backups = try loadIndex()
        guard let backup = backups.first(where: { $0.id == id }) else {
            throw DatabaseBackupError.missingBackup
        }
        try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(backup.baseFileName))
        for delta in backup.deltas {
            try? fileManager.removeItem(at: deltaDirectory.appendingPathComponent(delta.fileName))
        }
        backups.removeAll { $0.id == id }
        try saveIndex(backups)
    }

    func resetDatabase() async throws -> DatabaseBackupSummary {
        let backup = try await createBackup(reason: "Before reset")
        let quarantine = codexDirectory
            .appendingPathComponent("db-reset-\(timestamp(Date())).sqlite")
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.moveItem(at: databaseURL, to: quarantine)
        }
        try createEmptyDatabase()
        return backup
    }

    func restoreBackup(id: DatabaseBackupSummary.ID) async throws {
        let backups = try loadIndex()
        guard let backup = backups.first(where: { $0.id == id }) else {
            throw DatabaseBackupError.missingBackup
        }
        _ = try await createBackup(reason: "Before restore")

        let restoreURL = backupDirectory
            .appendingPathComponent("restore-\(timestamp(Date())).sqlite")
        try? fileManager.removeItem(at: restoreURL)
        try fileManager.copyItem(
            at: baseDirectory.appendingPathComponent(backup.baseFileName),
            to: restoreURL
        )
        try replayDeltas(backup.deltas, into: restoreURL)
        try validateDatabase(at: restoreURL)

        let oldURL = codexDirectory
            .appendingPathComponent("db-replaced-\(timestamp(Date())).sqlite")
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.moveItem(at: databaseURL, to: oldURL)
        }
        try fileManager.moveItem(at: restoreURL, to: databaseURL)
        try installChangeLogging()
    }

    func uploadPendingBackups() async throws {
        throw DatabaseBackupError.cloudUnavailable
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: deltaDirectory, withIntermediateDirectories: true)
    }

    private func loadIndex() throws -> [DatabaseBackupSummary] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let data = try Data(contentsOf: indexURL)
        return try decoder.decode([DatabaseBackupSummary].self, from: data)
    }

    private func saveIndex(_ backups: [DatabaseBackupSummary]) throws {
        let data = try encoder.encode(backups.sorted { $0.createdAt < $1.createdAt })
        try data.write(to: indexURL, options: [.atomic])
    }

    private func prune(_ backups: [DatabaseBackupSummary]) -> [DatabaseBackupSummary] {
        let sorted = backups.sorted { $0.createdAt > $1.createdAt }
        let retained = Array(sorted.prefix(14))
        let retainedIDs = Set(retained.map(\.id))
        for backup in sorted where !retainedIDs.contains(backup.id) {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(backup.baseFileName))
            for delta in backup.deltas {
                try? fileManager.removeItem(at: deltaDirectory.appendingPathComponent(delta.fileName))
            }
        }
        return retained
    }

    private func storageBytes() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: backupDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.compactMap { item -> Int64? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize
            else { return nil }
            return Int64(size)
        }.reduce(0, +)
    }

    private func copyConsistentDatabase(to destination: URL) throws {
        try? fileManager.removeItem(at: destination)
        try withDatabase(at: databaseURL) { source in
            var destinationDB: OpaquePointer?
            guard sqlite3_open(destination.path, &destinationDB) == SQLITE_OK, let destinationDB else {
                throw DatabaseBackupError.sqlite("Could not open backup destination.")
            }
            defer { sqlite3_close(destinationDB) }
            guard let backup = sqlite3_backup_init(destinationDB, "main", source, "main") else {
                throw DatabaseBackupError.sqlite(Self.lastError(destinationDB))
            }
            defer { sqlite3_backup_finish(backup) }
            let result = sqlite3_backup_step(backup, -1)
            guard result == SQLITE_DONE else {
                throw DatabaseBackupError.sqlite(Self.lastError(destinationDB))
            }
        }
    }

    private func createEmptyDatabase() throws {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            throw DatabaseBackupError.sqlite("Could not create database.")
        }
        sqlite3_close(db)
    }

    private func validateDatabase(at url: URL) throws {
        try withDatabase(at: url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseBackupError.sqlite(Self.lastError(db))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0),
                  String(cString: text) == "ok"
            else {
                throw DatabaseBackupError.sqlite("Restored database did not pass integrity check.")
            }
        }
    }

    private func installChangeLogging() throws {
        try withDatabase(at: databaseURL) { db in
            try exec(db, """
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS backup_change_log (
                sequence_id INTEGER PRIMARY KEY AUTOINCREMENT,
                table_name TEXT NOT NULL,
                row_id TEXT NOT NULL,
                operation TEXT NOT NULL,
                changed_at_ms INTEGER NOT NULL,
                row_json TEXT
            );
            CREATE TABLE IF NOT EXISTS backup_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );
            """)

            for table in try userTables(db) {
                let columns = try tableColumns(db, table: table)
                guard columns.contains("id") else { continue }
                try installTriggers(db, table: table, columns: columns)
            }
        }
    }

    private func installTriggers(_ db: OpaquePointer, table: String, columns: [String]) throws {
        let quotedTable = quoteIdentifier(table)
        let rowJSONNew = jsonObjectExpression(alias: "NEW", columns: columns)
        let rowJSONOld = jsonObjectExpression(alias: "OLD", columns: columns)
        let safeName = table.replacingOccurrences(of: "\"", with: "")
        try exec(db, """
        DROP TRIGGER IF EXISTS backup_\(safeName)_ai;
        DROP TRIGGER IF EXISTS backup_\(safeName)_au;
        DROP TRIGGER IF EXISTS backup_\(safeName)_ad;
        CREATE TRIGGER IF NOT EXISTS backup_\(safeName)_ai AFTER INSERT ON \(quotedTable)
        BEGIN
            INSERT INTO backup_change_log (table_name, row_id, operation, changed_at_ms, row_json)
            VALUES ('\(escapeLiteral(table))', NEW.id, 'insert', CAST(strftime('%s','now') AS INTEGER) * 1000, \(rowJSONNew));
        END;
        CREATE TRIGGER IF NOT EXISTS backup_\(safeName)_au AFTER UPDATE ON \(quotedTable)
        BEGIN
            INSERT INTO backup_change_log (table_name, row_id, operation, changed_at_ms, row_json)
            VALUES ('\(escapeLiteral(table))', NEW.id, 'update', CAST(strftime('%s','now') AS INTEGER) * 1000, \(rowJSONNew));
        END;
        CREATE TRIGGER IF NOT EXISTS backup_\(safeName)_ad AFTER DELETE ON \(quotedTable)
        BEGIN
            INSERT INTO backup_change_log (table_name, row_id, operation, changed_at_ms, row_json)
            VALUES ('\(escapeLiteral(table))', OLD.id, 'delete', CAST(strftime('%s','now') AS INTEGER) * 1000, \(rowJSONOld));
        END;
        """)
    }

    private func replayDeltas(_ deltas: [DatabaseBackupSummary.Delta], into database: URL) throws {
        guard !deltas.isEmpty else { return }
        try withDatabase(at: database) { db in
            try exec(db, "BEGIN IMMEDIATE;")
            do {
                for delta in deltas.sorted(by: { $0.fromSequence < $1.fromSequence }) {
                    let url = deltaDirectory.appendingPathComponent(delta.fileName)
                    guard fileManager.fileExists(atPath: url.path) else { continue }
                    let lines = try String(contentsOf: url, encoding: .utf8)
                        .split(separator: "\n")
                    for line in lines {
                        let row = try decoder.decode(BackupChangeRow.self, from: Data(String(line).utf8))
                        try apply(row: row, db: db)
                    }
                }
                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                throw error
            }
        }
    }

    private func apply(row: BackupChangeRow, db: OpaquePointer) throws {
        if row.operation == "delete" {
            try exec(db, "DELETE FROM \(quoteIdentifier(row.tableName)) WHERE id = '\(escapeLiteral(row.rowID))';")
            return
        }
        guard let rowJSON = row.rowJSON,
              let data = rowJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let columns = object.keys.sorted()
        let columnList = columns.map(quoteIdentifier).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let sql = "INSERT OR REPLACE INTO \(quoteIdentifier(row.tableName)) (\(columnList)) VALUES (\(placeholders));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseBackupError.sqlite(Self.lastError(db))
        }
        defer { sqlite3_finalize(statement) }
        for (index, column) in columns.enumerated() {
            bind(object[column], to: statement, at: Int32(index + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseBackupError.sqlite(Self.lastError(db))
        }
    }

    private func changeRows(after lowerBound: Int64, through upperBound: Int64) throws -> [BackupChangeRow] {
        try withDatabase(at: databaseURL) { db in
            var statement: OpaquePointer?
            let sql = """
            SELECT sequence_id, table_name, row_id, operation, changed_at_ms, row_json
            FROM backup_change_log
            WHERE sequence_id > ? AND sequence_id <= ?
            ORDER BY sequence_id ASC;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseBackupError.sqlite(Self.lastError(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, sqlite3_int64(lowerBound))
            sqlite3_bind_int64(statement, 2, sqlite3_int64(upperBound))
            var rows: [BackupChangeRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(BackupChangeRow(
                    sequenceID: Int64(sqlite3_column_int64(statement, 0)),
                    tableName: Self.text(statement, 1),
                    rowID: Self.text(statement, 2),
                    operation: Self.text(statement, 3),
                    changedAtMs: Int64(sqlite3_column_int64(statement, 4)),
                    rowJSON: Self.optionalText(statement, 5)
                ))
            }
            return rows
        }
    }

    private func currentChangeSequence() throws -> Int64 {
        try scalarInt64("SELECT COALESCE(MAX(sequence_id), 0) FROM backup_change_log;")
    }

    private func schemaVersion() throws -> Int {
        Int(try scalarInt64("PRAGMA user_version;"))
    }

    private func scalarInt64(_ sql: String) throws -> Int64 {
        try withDatabase(at: databaseURL) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseBackupError.sqlite(Self.lastError(db))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int64(sqlite3_column_int64(statement, 0))
        }
    }

    private func userTables(_ db: OpaquePointer) throws -> [String] {
        let skipped: Set<String> = ["backup_change_log", "backup_metadata", "sqlite_sequence"]
        return try queryStrings(db, """
        SELECT name FROM sqlite_master
        WHERE type = 'table'
          AND name NOT LIKE 'sqlite_%'
          AND name NOT LIKE 'backup_%'
        ORDER BY name;
        """).filter { !skipped.contains($0) }
    }

    private func tableColumns(_ db: OpaquePointer, table: String) throws -> [String] {
        try queryStrings(db, "PRAGMA table_info(\(quoteIdentifier(table)));", column: 1)
    }

    private func queryStrings(_ db: OpaquePointer, _ sql: String, column: Int32 = 0) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseBackupError.sqlite(Self.lastError(db))
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(Self.text(statement, column))
        }
        return values
    }

    private func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw DatabaseBackupError.sqlite("Could not open database.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        return try body(db)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? Self.lastError(db)
            if let error { sqlite3_free(error) }
            throw DatabaseBackupError.sqlite(message)
        }
    }

    private func bind(_ value: Any?, to statement: OpaquePointer?, at index: Int32) {
        switch value {
        case nil, is NSNull:
            sqlite3_bind_null(statement, index)
        case let value as Bool:
            sqlite3_bind_int(statement, index, value ? 1 : 0)
        case let value as Int:
            sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case let value as Int64:
            sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case let value as Double:
            sqlite3_bind_double(statement, index, value)
        case let value as String:
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        default:
            sqlite3_bind_text(statement, index, "\(value!)", -1, SQLITE_TRANSIENT)
        }
    }

    private func jsonObjectExpression(alias: String, columns: [String]) -> String {
        let pairs = columns.map { column in
            "'\(escapeLiteral(column))', \(alias).\(quoteIdentifier(column))"
        }
        return "json_object(\(pairs.joined(separator: ", ")))"
    }

    private func quoteIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func byteCount(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func checksum(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func timestamp(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    private var appBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private static func lastError(_ db: OpaquePointer) -> String {
        sqlite3_errmsg(db).map(String.init(cString:)) ?? "Unknown SQLite error."
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
    }

    private static func optionalText(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

private struct BackupChangeRow: Codable {
    var sequenceID: Int64
    var tableName: String
    var rowID: String
    var operation: String
    var changedAtMs: Int64
    var rowJSON: String?
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
