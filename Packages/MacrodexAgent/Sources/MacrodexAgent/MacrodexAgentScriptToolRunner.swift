import Foundation
import JavaScriptCore

public enum MacrodexAgentScriptToolError: Error, Equatable, LocalizedError {
    case missingScript
    case javaScriptException(String)
    case sqlUnavailable
    case invalidBindings
    case invalidTables
    case invalidTransactionOperations

    public var errorDescription: String? {
        switch self {
        case .missingScript:
            return "JSC tool requires a non-empty script."
        case .javaScriptException(let message):
            return message
        case .sqlUnavailable:
            return "SQL helper is not configured for this JSC runner."
        case .invalidBindings:
            return "JSC SQL bindings must be a JSON array."
        case .invalidTables:
            return "JSC SQL schema tables must be a JSON array of strings."
        case .invalidTransactionOperations:
            return "JSC SQL transaction operations must be a JSON array of objects."
        }
    }
}

public final class MacrodexAgentScriptToolRunner: MacrodexAgentToolRunner {
    private let sqlRunner: MacrodexAgentSQLiteToolRunner?

    public init(sqlRunner: MacrodexAgentSQLiteToolRunner? = nil) {
        self.sqlRunner = sqlRunner
    }

    public func runTool(_ call: MacrodexAgentToolCall) throws -> MacrodexAgentToolResult {
        let args = call.arguments.objectValue ?? [:]
        let script = (args["script"]?.stringValue ?? args["code"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else {
            return Self.failureResult(callID: call.id, error: MacrodexAgentScriptToolError.missingScript)
        }

        do {
            let argv = (args["argv"]?.arrayValue ?? []).compactMap(\.stringValue)
            let execution = try run(script: script, argv: argv)
            return MacrodexAgentToolResult(callID: call.id, output: execution)
        } catch {
            return Self.failureResult(callID: call.id, error: error)
        }
    }

    public func run(script: String, argv: [String] = []) throws -> MacrodexAgentJSONValue {
        guard let context = JSContext() else {
            throw MacrodexAgentScriptToolError.javaScriptException("Failed to create JavaScriptCore context.")
        }

        var stdout: [String] = []
        var stderr: [String] = []
        context.exceptionHandler = { _, exception in
            context.exception = exception
        }

        let consoleLog: @convention(block) (String) -> Void = { message in
            stdout.append(message)
        }
        let consoleWarn: @convention(block) (String) -> Void = { message in
            stderr.append(message)
        }
        let uuid: @convention(block) () -> String = {
            UUID().uuidString.lowercased()
        }
        let nowMilliseconds: @convention(block) () -> Double = {
            Date().timeIntervalSince1970 * 1000
        }
        let todayKey: @convention(block) () -> String = {
            Self.dateFormatter.string(from: Date())
        }

        context.setObject(consoleLog, forKeyedSubscript: "__piConsoleLog" as NSString)
        context.setObject(consoleWarn, forKeyedSubscript: "__piConsoleWarn" as NSString)
        context.setObject(uuid, forKeyedSubscript: "__piUUID" as NSString)
        context.setObject(nowMilliseconds, forKeyedSubscript: "__piNowMs" as NSString)
        context.setObject(todayKey, forKeyedSubscript: "__piTodayKey" as NSString)

        installSQLBridge(in: context)
        installPrelude(in: context, argv: argv)

        let result = context.evaluateScript(script)
        if let exception = context.exception, !exception.isUndefined, !exception.isNull {
            throw MacrodexAgentScriptToolError.javaScriptException(exception.toString() ?? "JavaScriptCore exception")
        }

        return [
            "ok": true,
            "stdout": .string(stdout.joined(separator: "\n")),
            "stderr": .string(stderr.joined(separator: "\n")),
            "result": Self.jsonValue(from: result)
        ]
    }

    private func installSQLBridge(in context: JSContext) {
        let query: @convention(block) (String, String) -> String = { [weak self] statement, bindingsJSON in
            do {
                guard let sqlRunner = self?.sqlRunner else {
                    throw MacrodexAgentScriptToolError.sqlUnavailable
                }
                let bindings = try Self.bindings(from: bindingsJSON)
                let rows = try sqlRunner.query(statement, bindings: bindings)
                return try Self.jsonString(.array(rows))
            } catch {
                return Self.errorJSONString(error)
            }
        }

        let exec: @convention(block) (String, String) -> String = { [weak self] statement, bindingsJSON in
            do {
                guard let sqlRunner = self?.sqlRunner else {
                    throw MacrodexAgentScriptToolError.sqlUnavailable
                }
                let bindings = try Self.bindings(from: bindingsJSON)
                let changes = try sqlRunner.exec(statement, bindings: bindings)
                return try Self.jsonString([
                    "ok": true,
                    "changes": .number(Double(changes))
                ])
            } catch {
                return Self.errorJSONString(error)
            }
        }

        let schema: @convention(block) (String) -> String = { [weak self] tablesJSON in
            do {
                guard let sqlRunner = self?.sqlRunner else {
                    throw MacrodexAgentScriptToolError.sqlUnavailable
                }
                let tables = try Self.tables(from: tablesJSON)
                return try Self.jsonString(try sqlRunner.schema(tables: tables))
            } catch {
                return Self.errorJSONString(error)
            }
        }

        let validate: @convention(block) (String, String) -> String = { [weak self] statement, bindingsJSON in
            do {
                guard let sqlRunner = self?.sqlRunner else {
                    throw MacrodexAgentScriptToolError.sqlUnavailable
                }
                let bindings = try Self.bindings(from: bindingsJSON)
                return try Self.jsonString(try sqlRunner.validate(statement, bindings: bindings))
            } catch {
                return Self.errorJSONString(error)
            }
        }

        let transaction: @convention(block) (String, String) -> String = { [weak self] operationsJSON, optionsJSON in
            do {
                guard let sqlRunner = self?.sqlRunner else {
                    throw MacrodexAgentScriptToolError.sqlUnavailable
                }
                let operationsValue = try Self.jsonValue(from: operationsJSON)
                let operations = try MacrodexAgentSQLiteToolRunner.transactionOperations(from: operationsValue)
                let options = try? Self.jsonValue(from: optionsJSON).objectValue
                let dryRun = options?["dryRun"]?.boolValue ?? false
                return try Self.jsonString(try sqlRunner.transaction(operations, dryRun: dryRun))
            } catch {
                return Self.errorJSONString(error)
            }
        }

        context.setObject(query, forKeyedSubscript: "__piSQLQuery" as NSString)
        context.setObject(exec, forKeyedSubscript: "__piSQLExec" as NSString)
        context.setObject(schema, forKeyedSubscript: "__piSQLSchema" as NSString)
        context.setObject(validate, forKeyedSubscript: "__piSQLValidate" as NSString)
        context.setObject(transaction, forKeyedSubscript: "__piSQLTransaction" as NSString)
    }

    private func installPrelude(in context: JSContext, argv: [String]) {
        let argvJSON = (try? String(data: JSONEncoder().encode(argv), encoding: .utf8)) ?? "[]"
        context.evaluateScript(
            """
            var argv = \(argvJSON);
            var scriptArgs = argv;
            var console = {
              log: function () { __piConsoleLog(Array.prototype.slice.call(arguments).join(" ")); },
              warn: function () { __piConsoleWarn(Array.prototype.slice.call(arguments).join(" ")); },
              error: function () { __piConsoleWarn(Array.prototype.slice.call(arguments).join(" ")); }
            };
            var crypto = { randomUUID: function () { return __piUUID(); } };
            function nowMs() { return Math.floor(__piNowMs()); }
            function todayKey() { return __piTodayKey(); }
            function __piSQLCall(raw) {
              var parsed = JSON.parse(raw);
              if (parsed && parsed.ok === false) {
                throw new Error(parsed.error || "SQL bridge failed");
              }
              return parsed;
            }
            var sql = {
              schema: function (tables) {
                return __piSQLCall(__piSQLSchema(JSON.stringify(tables || [])));
              },
              validate: function (statement, bindings) {
                return __piSQLCall(__piSQLValidate(String(statement), JSON.stringify(bindings || [])));
              },
              query: function (statement, bindings) {
                return __piSQLCall(__piSQLQuery(String(statement), JSON.stringify(bindings || [])));
              },
              exec: function (statement, bindings) {
                return __piSQLCall(__piSQLExec(String(statement), JSON.stringify(bindings || [])));
              },
              transaction: function (operations, options) {
                return __piSQLCall(__piSQLTransaction(
                  JSON.stringify(operations || []),
                  JSON.stringify(options || {})
                ));
              },
              dryRun: function (operations) {
                return sql.transaction(operations, { dryRun: true });
              }
            };
            var db = sql;
            """
        )
    }

    private static func bindings(from json: String) throws -> [MacrodexAgentJSONValue] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(MacrodexAgentJSONValue.self, from: data),
              let array = value.arrayValue
        else {
            throw MacrodexAgentScriptToolError.invalidBindings
        }
        return array
    }

    private static func tables(from json: String) throws -> [String] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(MacrodexAgentJSONValue.self, from: data),
              let array = value.arrayValue
        else {
            throw MacrodexAgentScriptToolError.invalidTables
        }
        return array.compactMap(\.stringValue)
    }

    private static func jsonValue(from json: String) throws -> MacrodexAgentJSONValue {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(MacrodexAgentJSONValue.self, from: data)
        else {
            throw MacrodexAgentScriptToolError.invalidTransactionOperations
        }
        return value
    }

    private static func jsonString(_ value: MacrodexAgentJSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private static func errorJSONString(_ error: Error) -> String {
        let value: MacrodexAgentJSONValue = [
            "ok": false,
            "error": .string(error.localizedDescription),
            "errorType": .string(String(describing: type(of: error)))
        ]
        return (try? jsonString(value)) ?? "{\"ok\":false,\"error\":\"SQL bridge failed\"}"
    }

    private static func failureResult(callID: String, error: Error) -> MacrodexAgentToolResult {
        MacrodexAgentToolResult(
            callID: callID,
            output: [
                "ok": false,
                "error": .string(error.localizedDescription),
                "recoverable": true,
                "hint": "Fix the script or inspect SQL schemas, then continue the turn."
            ],
            isError: true
        )
    }

    private static func jsonValue(from value: JSValue?) -> MacrodexAgentJSONValue {
        guard let value, !value.isUndefined, !value.isNull else {
            return .null
        }
        if value.isBoolean {
            return .bool(value.toBool())
        }
        if value.isNumber {
            return .number(value.toDouble())
        }
        if value.isString {
            return .string(value.toString() ?? "")
        }
        if let object = value.toObject(),
           JSONSerialization.isValidJSONObject(object),
           let jsonValue = try? MacrodexAgentJSONValue(jsonObject: object) {
            return jsonValue
        }
        return .string(value.toString() ?? "")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
