import Foundation
import SQLite3

public enum PiSQLiteToolError: Error, Equatable, LocalizedError {
    case missingStatement
    case missingOperations
    case missingLeadingComment
    case missingRequiredCommentMarker(String)
    case invalidBindings
    case invalidOperations
    case sqlite(String)
    case databaseNotOpen

    public var errorDescription: String? {
        switch self {
        case .missingStatement:
            return "SQL tool requires a non-empty statement."
        case .missingOperations:
            return "SQL transaction requires at least one operation."
        case .missingLeadingComment:
            return "SQL statement must start with a line or block comment."
        case .missingRequiredCommentMarker(let marker):
            return "SQL statement leading comment must include \(marker)."
        case .invalidBindings:
            return "SQL bindings must be a JSON array."
        case .invalidOperations:
            return "SQL transaction operations must be an array of objects with statement strings."
        case .sqlite(let message):
            return message
        case .databaseNotOpen:
            return "SQLite database is not open."
        }
    }
}

public struct PiSQLiteTransactionOperation: Equatable, Sendable {
    public var purpose: String?
    public var statement: String
    public var bindings: [PiJSONValue]
    public var mode: PiSQLiteToolRunner.Mode

    public init(
        purpose: String? = nil,
        statement: String,
        bindings: [PiJSONValue] = [],
        mode: PiSQLiteToolRunner.Mode = .auto
    ) {
        self.purpose = purpose
        self.statement = statement
        self.bindings = bindings
        self.mode = mode
    }
}

public final class PiSQLiteToolRunner: PiToolRunner {
    public enum Mode: String, Sendable {
        case auto
        case query
        case exec
        case schema
        case validate
    }

    public let databaseURL: URL
    public let requiresLeadingComment: Bool
    public let requiredLeadingCommentMarker: String?
    public let maxRows: Int

    public init(
        databaseURL: URL,
        requiresLeadingComment: Bool = false,
        requiredLeadingCommentMarker: String? = nil,
        maxRows: Int = 500
    ) {
        self.databaseURL = databaseURL
        self.requiredLeadingCommentMarker = requiredLeadingCommentMarker
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.requiresLeadingComment = requiresLeadingComment || self.requiredLeadingCommentMarker != nil
        self.maxRows = max(1, maxRows)
    }

    public func runTool(_ call: PiToolCall) throws -> PiToolResult {
        let args = call.arguments.objectValue ?? [:]
        let purpose = args["purpose"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let mode = Mode(rawValue: args["mode"]?.stringValue ?? "") ?? .auto
        let statement = (args["statement"]?.stringValue ?? args["sql"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            switch mode {
            case .schema:
                let tables = Self.stringArray(from: args["tables"])
                var output = try schema(tables: tables)
                output.objectValueAssign("purpose", value: purpose.map(PiJSONValue.string) ?? .null)
                return PiToolResult(callID: call.id, output: output)
            case .validate:
                guard !statement.isEmpty else {
                    return Self.failureResult(callID: call.id, error: PiSQLiteToolError.missingStatement, statement: statement, mode: mode)
                }
                try validateLeadingComment(statement)
                let bindings = try Self.bindings(from: args["bindings"])
                var output = try validate(statement, bindings: bindings)
                output.objectValueAssign("purpose", value: purpose.map(PiJSONValue.string) ?? .null)
                return PiToolResult(callID: call.id, output: output)
            case .auto, .query, .exec:
                guard !statement.isEmpty else {
                    return Self.failureResult(callID: call.id, error: PiSQLiteToolError.missingStatement, statement: statement, mode: mode)
                }
                try validateLeadingComment(statement)
                let bindings = try Self.bindings(from: args["bindings"])
                let output: PiJSONValue
                switch resolvedMode(mode, statement: statement) {
                case .query:
                    let result = try query(statement, bindings: bindings)
                    output = [
                        "purpose": purpose.map(PiJSONValue.string) ?? .null,
                        "mode": "query",
                        "ok": true,
                        "rowCount": .number(Double(result.count)),
                        "rows": .array(result)
                    ]
                case .exec:
                    let changes = try exec(statement, bindings: bindings)
                    output = [
                        "purpose": purpose.map(PiJSONValue.string) ?? .null,
                        "mode": "exec",
                        "ok": true,
                        "changes": .number(Double(changes))
                    ]
                case .auto, .schema, .validate:
                    preconditionFailure("mode should be resolved before execution")
                }
                return PiToolResult(callID: call.id, output: output)
            }
        } catch {
            return Self.failureResult(callID: call.id, error: error, statement: statement, mode: mode)
        }
    }

    public func query(_ statement: String, bindings: [PiJSONValue] = []) throws -> [PiJSONValue] {
        try validateLeadingComment(statement)
        return try withDatabase { db in
            try query(statement, bindings: bindings, db: db)
        }
    }

    @discardableResult
    public func exec(_ statement: String, bindings: [PiJSONValue] = []) throws -> Int {
        try validateLeadingComment(statement)
        return try withDatabase { db in
            try exec(statement, bindings: bindings, db: db)
        }
    }

    public func validate(_ statement: String, bindings: [PiJSONValue] = []) throws -> PiJSONValue {
        try validateLeadingComment(statement)
        return try withDatabase { db in
            try validate(statement, bindings: bindings, db: db)
        }
    }

    public func schema(tables requestedTables: [String] = []) throws -> PiJSONValue {
        try withDatabase { db in
            let tableNames = try resolvedSchemaTables(requestedTables, db: db)
            let tables = try tableNames.map { tableName -> PiJSONValue in
                let columns = try query("PRAGMA table_info(\(Self.quotedIdentifier(tableName)))", bindings: [], db: db)
                let foreignKeys = try query("PRAGMA foreign_key_list(\(Self.quotedIdentifier(tableName)))", bindings: [], db: db)
                let indexes = try query("PRAGMA index_list(\(Self.quotedIdentifier(tableName)))", bindings: [], db: db)
                return [
                    "name": .string(tableName),
                    "columns": .array(columns),
                    "foreignKeys": .array(foreignKeys),
                    "indexes": .array(indexes)
                ]
            }
            return [
                "ok": true,
                "mode": "schema",
                "tables": .array(tables),
                "notes": .array([
                    .string("Recipes are food_library_items rows with kind='recipe'."),
                    .string("recipe_components.recipe_id references food_library_items.id."),
                    .string("meal_templates are reusable meal templates, not saved recipes.")
                ])
            ]
        }
    }

    public func transaction(
        _ operations: [PiSQLiteTransactionOperation],
        dryRun: Bool = false
    ) throws -> PiJSONValue {
        guard !operations.isEmpty else {
            throw PiSQLiteToolError.missingOperations
        }
        for operation in operations {
            try validateLeadingComment(operation.statement)
        }

        return try withDatabase { db in
            if dryRun {
                try Self.execRaw("SAVEPOINT macrodex_dry_run", db: db)
            } else {
                try Self.execRaw("BEGIN IMMEDIATE", db: db)
            }

            var results: [PiJSONValue] = []
            do {
                for (index, operation) in operations.enumerated() {
                    let mode = resolvedMode(operation.mode, statement: operation.statement)
                    switch mode {
                    case .query:
                        let rows = try query(operation.statement, bindings: operation.bindings, db: db)
                        results.append([
                            "index": .number(Double(index)),
                            "purpose": operation.purpose.map(PiJSONValue.string) ?? .null,
                            "mode": "query",
                            "statementPreview": .string(Self.statementPreview(operation.statement)),
                            "rowCount": .number(Double(rows.count)),
                            "rows": .array(rows)
                        ])
                    case .exec:
                        let changes = try exec(operation.statement, bindings: operation.bindings, db: db)
                        results.append([
                            "index": .number(Double(index)),
                            "purpose": operation.purpose.map(PiJSONValue.string) ?? .null,
                            "mode": "exec",
                            "statementPreview": .string(Self.statementPreview(operation.statement)),
                            "changes": .number(Double(changes))
                        ])
                    case .validate:
                        let validation = try validate(operation.statement, bindings: operation.bindings, db: db)
                        results.append([
                            "index": .number(Double(index)),
                            "purpose": operation.purpose.map(PiJSONValue.string) ?? .null,
                            "mode": "validate",
                            "statementPreview": .string(Self.statementPreview(operation.statement)),
                            "validation": validation
                        ])
                    case .auto, .schema:
                        preconditionFailure("transaction mode should be executable")
                    }
                }

                if dryRun {
                    try Self.execRaw("ROLLBACK TO macrodex_dry_run", db: db)
                    try Self.execRaw("RELEASE macrodex_dry_run", db: db)
                } else {
                    try Self.execRaw("COMMIT", db: db)
                }

                return [
                    "ok": true,
                    "mode": "transaction",
                    "dryRun": .bool(dryRun),
                    "operationCount": .number(Double(operations.count)),
                    "operations": .array(results)
                ]
            } catch {
                if dryRun {
                    try? Self.execRaw("ROLLBACK TO macrodex_dry_run", db: db)
                    try? Self.execRaw("RELEASE macrodex_dry_run", db: db)
                } else {
                    try? Self.execRaw("ROLLBACK", db: db)
                }
                throw error
            }
        }
    }

    public static func transactionOperations(from value: PiJSONValue?) throws -> [PiSQLiteTransactionOperation] {
        guard let array = value?.arrayValue else {
            throw PiSQLiteToolError.invalidOperations
        }
        return try array.map { item in
            guard let object = item.objectValue,
                  let statement = (object["statement"]?.stringValue ?? object["sql"]?.stringValue)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !statement.isEmpty
            else {
                throw PiSQLiteToolError.invalidOperations
            }
            let purpose = object["purpose"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let bindings = try bindings(from: object["bindings"])
            let mode = Mode(rawValue: object["mode"]?.stringValue ?? "") ?? .auto
            return PiSQLiteTransactionOperation(
                purpose: purpose,
                statement: statement,
                bindings: bindings,
                mode: mode
            )
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            let message = db.map(Self.lastError) ?? "Failed to open SQLite database."
            if let db {
                sqlite3_close(db)
            }
            throw PiSQLiteToolError.sqlite(message)
        }
        guard let db else {
            throw PiSQLiteToolError.databaseNotOpen
        }
        defer {
            sqlite3_close(db)
        }

        sqlite3_busy_timeout(db, 5_000)
        guard sqlite3_exec(db, "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;", nil, nil, nil) == SQLITE_OK else {
            throw PiSQLiteToolError.sqlite(Self.lastError(db))
        }
        return try body(db)
    }

    private func query(_ statement: String, bindings: [PiJSONValue], db: OpaquePointer) throws -> [PiJSONValue] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &prepared, nil) == SQLITE_OK else {
            throw PiSQLiteToolError.sqlite(Self.lastError(db))
        }
        guard let prepared else {
            throw PiSQLiteToolError.sqlite("SQLite did not return a prepared statement.")
        }
        defer {
            sqlite3_finalize(prepared)
        }

        try Self.bind(bindings, to: prepared)
        var rows: [PiJSONValue] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            if rows.count >= maxRows {
                break
            }
            rows.append(Self.row(from: prepared))
        }
        return rows
    }

    @discardableResult
    private func exec(_ statement: String, bindings: [PiJSONValue], db: OpaquePointer) throws -> Int {
        if bindings.isEmpty && statement.contains(";") {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw PiSQLiteToolError.sqlite(Self.lastError(db))
            }
            return Int(sqlite3_changes(db))
        }

        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &prepared, nil) == SQLITE_OK else {
            throw PiSQLiteToolError.sqlite(Self.lastError(db))
        }
        guard let prepared else {
            throw PiSQLiteToolError.sqlite("SQLite did not return a prepared statement.")
        }
        defer {
            sqlite3_finalize(prepared)
        }

        try Self.bind(bindings, to: prepared)
        guard sqlite3_step(prepared) == SQLITE_DONE else {
            throw PiSQLiteToolError.sqlite(Self.lastError(db))
        }
        return Int(sqlite3_changes(db))
    }

    private func validate(_ statement: String, bindings: [PiJSONValue], db: OpaquePointer) throws -> PiJSONValue {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &prepared, nil) == SQLITE_OK else {
            throw PiSQLiteToolError.sqlite(Self.lastError(db))
        }
        guard let prepared else {
            throw PiSQLiteToolError.sqlite("SQLite did not return a prepared statement.")
        }
        defer {
            sqlite3_finalize(prepared)
        }

        try Self.bind(bindings, to: prepared)
        return [
            "ok": true,
            "mode": "validate",
            "statementPreview": .string(Self.statementPreview(statement)),
            "firstKeyword": .string(Self.firstKeyword(in: statement)),
            "bindingsCount": .number(Double(bindings.count)),
            "columnCount": .number(Double(sqlite3_column_count(prepared))),
            "readOnly": .bool(sqlite3_stmt_readonly(prepared) != 0)
        ]
    }

    private func resolvedSchemaTables(_ requestedTables: [String], db: OpaquePointer) throws -> [String] {
        let requested = requestedTables
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !requested.isEmpty {
            return requested
        }

        let common = [
            "food_log_items",
            "food_log_entries",
            "food_library_items",
            "recipe_components",
            "meal_templates",
            "meal_template_items",
            "canonical_food_items",
            "food_aliases",
            "serving_units",
            "nutrition_sources",
            "user_preference_memory"
        ]
        let existing = try query(
            "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name COLLATE NOCASE",
            bindings: [],
            db: db
        )
        let names = Set(existing.compactMap { $0.objectValue?["name"]?.stringValue })
        let known = common.filter(names.contains)
        if !known.isEmpty {
            return known
        }
        return Array(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func resolvedMode(_ mode: Mode, statement: String) -> Mode {
        switch mode {
        case .query, .exec, .validate, .schema:
            return mode
        case .auto:
            return Self.isRowReturningStatement(statement) ? .query : .exec
        }
    }

    private func validateLeadingComment(_ statement: String) throws {
        guard requiresLeadingComment else {
            return
        }
        guard let comment = Self.leadingSQLComment(statement) else {
            throw PiSQLiteToolError.missingLeadingComment
        }
        if let requiredLeadingCommentMarker,
           !comment.localizedCaseInsensitiveContains(requiredLeadingCommentMarker) {
            throw PiSQLiteToolError.missingRequiredCommentMarker(requiredLeadingCommentMarker)
        }
    }

    private static func bindings(from value: PiJSONValue?) throws -> [PiJSONValue] {
        guard let value else {
            return []
        }
        guard let array = value.arrayValue else {
            throw PiSQLiteToolError.invalidBindings
        }
        return array
    }

    private static func stringArray(from value: PiJSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func failureResult(callID: String, error: Error, statement: String? = nil, mode: Mode? = nil) -> PiToolResult {
        var output: [String: PiJSONValue] = [
            "ok": false,
            "error": .string(error.localizedDescription),
            "errorType": .string(Self.errorType(for: error)),
            "recoverable": true,
            "hint": .string(Self.hint(for: error, statement: statement))
        ]
        if let mode {
            output["mode"] = .string(mode.rawValue)
        }
        if let statement, !statement.isEmpty {
            output["statementPreview"] = .string(Self.statementPreview(statement))
            output["firstKeyword"] = .string(Self.firstKeyword(in: statement))
        }
        return PiToolResult(callID: callID, output: .object(output), isError: true)
    }

    private static func errorType(for error: Error) -> String {
        if case PiSQLiteToolError.sqlite = error {
            return "sqlite"
        }
        if let toolError = error as? PiSQLiteToolError {
            switch toolError {
            case .missingStatement, .missingOperations, .missingLeadingComment, .missingRequiredCommentMarker,
                 .invalidBindings, .invalidOperations:
                return "validation"
            case .databaseNotOpen:
                return "database"
            case .sqlite:
                return "sqlite"
            }
        }
        return String(describing: type(of: error))
    }

    private static func hint(for error: Error, statement: String?) -> String {
        if case PiSQLiteToolError.missingLeadingComment = error {
            return "Start the SQL text with a /* macrodex: Label */ or -- macrodex: Label comment."
        }
        if case PiSQLiteToolError.missingRequiredCommentMarker(let marker) = error {
            return "Put \(marker) in the first SQL comment so the UI can label the tool call."
        }
        if case PiSQLiteToolError.invalidBindings = error {
            return "Pass bindings as a JSON array matching positional ? placeholders."
        }
        if let statement, !statement.isEmpty {
            let keyword = firstKeyword(in: statement)
            if keyword == "insert" || keyword == "update" || keyword == "delete" {
                return "Run schema or validate mode, then retry the write inside db_transaction or sql.transaction if multiple steps are involved."
            }
        }
        return "Inspect the table schema with mode=schema or run mode=validate before retrying."
    }

    private static func bind(_ values: [PiJSONValue], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case .bool(let value):
                result = sqlite3_bind_int(statement, position, value ? 1 : 0)
            case .number(let value):
                result = sqlite3_bind_double(statement, position, value)
            case .string(let value):
                result = sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case .array, .object:
                let data = try JSONEncoder().encode(value)
                let string = String(data: data, encoding: .utf8) ?? "null"
                result = sqlite3_bind_text(statement, position, string, -1, SQLITE_TRANSIENT)
            }
            guard result == SQLITE_OK else {
                throw PiSQLiteToolError.sqlite("Failed to bind SQL value at position \(position).")
            }
        }
    }

    private static func row(from statement: OpaquePointer) -> PiJSONValue {
        let columnCount = sqlite3_column_count(statement)
        var object: [String: PiJSONValue] = [:]
        for index in 0..<columnCount {
            let name = sqlite3_column_name(statement, index).map(String.init(cString:)) ?? "column_\(index)"
            object[name] = value(from: statement, column: index)
        }
        return .object(object)
    }

    private static func value(from statement: OpaquePointer, column index: Int32) -> PiJSONValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .number(Double(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT:
            return .number(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else {
                return .string("")
            }
            return .string(String(cString: text))
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(statement, index))
            guard let bytes = sqlite3_column_blob(statement, index), byteCount > 0 else {
                return .string("")
            }
            return .string(Data(bytes: bytes, count: byteCount).base64EncodedString())
        default:
            return .null
        }
    }

    private static func leadingSQLComment(_ statement: String) -> String? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("--") {
            let end = trimmed.firstIndex(of: "\n") ?? trimmed.endIndex
            return String(trimmed[..<end])
        }
        if trimmed.hasPrefix("/*"),
           let end = trimmed.range(of: "*/") {
            return String(trimmed[..<end.upperBound])
        }
        return nil
    }

    private static func isRowReturningStatement(_ statement: String) -> Bool {
        let keyword = firstKeyword(in: statement)
        return ["select", "with", "pragma", "explain"].contains(keyword)
    }

    private static func firstKeyword(in statement: String) -> String {
        var remaining = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            if remaining.hasPrefix("--") {
                guard let newline = remaining.firstIndex(of: "\n") else {
                    return ""
                }
                remaining = String(remaining[remaining.index(after: newline)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if remaining.hasPrefix("/*") {
                guard let end = remaining.range(of: "*/") else {
                    return ""
                }
                remaining = String(remaining[end.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            break
        }

        let keyword = remaining.prefix { $0.isLetter }
        return keyword.lowercased()
    }

    private static func statementPreview(_ statement: String) -> String {
        let compact = statement
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
        guard compact.count > 240 else {
            return compact
        }
        return String(compact.prefix(237)) + "..."
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func execRaw(_ statement: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw PiSQLiteToolError.sqlite(Self.lastError(db))
        }
    }

    private static func lastError(_ db: OpaquePointer) -> String {
        let code = sqlite3_errcode(db)
        let message = sqlite3_errmsg(db).map(String.init(cString:)) ?? "Unknown SQLite error."
        return "SQLite \(code): \(message)"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension PiJSONValue {
    mutating func objectValueAssign(_ key: String, value: PiJSONValue) {
        guard case .object(var object) = self else {
            return
        }
        object[key] = value
        self = .object(object)
    }
}
