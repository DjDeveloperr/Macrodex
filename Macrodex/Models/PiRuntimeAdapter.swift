import Foundation
import PiJSC

enum PiHealthKitToolError: Error, LocalizedError {
    case missingCommand
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "HealthKit tool requires a command."
        case .commandFailed(let code, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "HealthKit command failed with exit code \(code)." : trimmed
        }
    }
}

final class PiHealthKitToolRunner: PiToolRunner {
    private let workingDirectoryPath: String

    init(workingDirectoryPath: String) {
        self.workingDirectoryPath = workingDirectoryPath
    }

    func runTool(_ call: PiToolCall) throws -> PiToolResult {
        let args = call.arguments.objectValue ?? [:]
        let purpose = args["purpose"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        let command = args["command"]?.stringValue ?? args["action"]?.stringValue ?? ""
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return Self.failureResult(callID: call.id, error: PiHealthKitToolError.missingCommand)
        }

        let shellCommand = "healthkit " + shellJoinedArguments([normalized] + commandArguments(from: args))
        var outputPointer: UnsafeMutablePointer<CChar>?
        var outputLength = 0
        let exitCode = macrodex_command_bridge_run(shellCommand, workingDirectoryPath, &outputPointer, &outputLength)
        let output: String
        if let outputPointer, outputLength > 0 {
            let data = Data(bytes: outputPointer, count: outputLength)
            output = String(data: data, encoding: .utf8) ?? ""
        } else {
            output = ""
        }
        if let outputPointer {
            free(outputPointer)
        }

        if exitCode != 0 {
            return Self.failureResult(callID: call.id, error: PiHealthKitToolError.commandFailed(exitCode, output))
        }

        if let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            var value = try PiJSONValue(jsonObject: object)
            if let purpose, case .object(var payload) = value {
                payload["purpose"] = .string(purpose)
                value = .object(payload)
            }
            return PiToolResult(callID: call.id, output: value)
        }

        if let purpose {
            return PiToolResult(callID: call.id, output: ["purpose": .string(purpose), "output": .string(output)])
        }
        return PiToolResult(callID: call.id, output: .string(output))
    }

    private static func failureResult(callID: String, error: Error) -> PiToolResult {
        PiToolResult(
            callID: callID,
            output: [
                "ok": false,
                "error": .string(error.localizedDescription),
                "recoverable": true
            ],
            isError: true
        )
    }

    private func commandArguments(from args: [String: PiJSONValue]) -> [String] {
        if let explicit = args["args"]?.arrayValue {
            return explicit.compactMap(\.stringValue)
        }

        return args
            .filter { key, _ in key != "command" && key != "action" }
            .sorted { $0.key < $1.key }
            .flatMap { key, value -> [String] in
                let option = "--" + key
                switch value {
                case .null:
                    return []
                case .bool(let bool):
                    return bool ? [option] : [option, "false"]
                case .number(let number):
                    return [option, number.rounded() == number ? String(Int64(number)) : String(number)]
                case .string(let string):
                    return string.isEmpty ? [] : [option, string]
                case .array(let values):
                    return values.compactMap(\.stringValue).flatMap { [option, $0] }
                case .object:
                    let object = value.jsonObject()
                    guard JSONSerialization.isValidJSONObject(object),
                          let data = try? JSONSerialization.data(withJSONObject: object),
                          let json = String(data: data, encoding: .utf8) else {
                        return []
                    }
                    return [option, json]
                }
            }
    }

    private func shellJoinedArguments(_ arguments: [String]) -> String {
        arguments.map(shellEscaped).joined(separator: " ")
    }

    private func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class PiFoodSearchToolRunner: PiToolRunner {
    private let sqlRunner: PiSQLiteToolRunner

    init(databaseURL: URL) {
        self.sqlRunner = PiSQLiteToolRunner(databaseURL: databaseURL, maxRows: 25)
    }

    func runTool(_ call: PiToolCall) throws -> PiToolResult {
        let args = call.arguments.objectValue ?? [:]
        let purpose = args["purpose"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        let query = (args["query"]?.stringValue ?? args["q"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, min(args["limit"]?.intValue ?? 10, 25))
        let normalizedTokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { "%\($0)%" }
        let predicates = normalizedTokens.isEmpty
            ? "1 = 1"
            : normalizedTokens.map { _ in "(search_name LIKE ? OR search_brand LIKE ?)" }.joined(separator: " AND ")
        let bindings = normalizedTokens.flatMap { token in [PiJSONValue.string(token), .string(token)] } + [.number(Double(limit))]
        let rows = try sqlRunner.query(
            """
            /* macrodex: Searching foods */
            WITH library AS (
                SELECT fli.id, 'library' AS source, fli.kind, fli.name, COALESCE(fli.brand, '') AS brand,
                       fli.calories_kcal, COALESCE(fli.protein_g, 0) AS protein_g,
                       COALESCE(fli.carbs_g, 0) AS carbs_g, COALESCE(fli.fat_g, 0) AS fat_g,
                       fli.default_serving_qty, fli.default_serving_unit, ns.title AS source_title, ns.url AS source_url,
                       lower(fli.name || ' ' || COALESCE(fli.brand, '') || ' ' || fli.kind || ' ' || COALESCE(fa.aliases, '') || ' ' || COALESCE(rc.components, '')) AS search_name,
                       lower(COALESCE(fli.brand, '')) AS search_brand,
                       COALESCE(fli.updated_at_ms, 0) AS rank_time
                FROM food_library_items fli
                LEFT JOIN nutrition_sources ns ON ns.id = fli.source_id AND ns.deleted_at_ms IS NULL
                LEFT JOIN (
                    SELECT library_item_id, GROUP_CONCAT(alias, ' ') AS aliases
                    FROM food_aliases
                    WHERE deleted_at_ms IS NULL
                    GROUP BY library_item_id
                ) fa ON fa.library_item_id = fli.id
                LEFT JOIN (
                    SELECT recipe_id, GROUP_CONCAT(component_name, ' ') AS components
                    FROM recipe_components
                    WHERE deleted_at_ms IS NULL
                    GROUP BY recipe_id
                ) rc ON rc.recipe_id = fli.id
                WHERE fli.deleted_at_ms IS NULL
                UNION ALL
                SELECT cfi.id, 'canonical' AS source, 'food' AS kind, cfi.display_name AS name, COALESCE(cfi.brand, '') AS brand,
                       cfi.calories_kcal, COALESCE(cfi.protein_g, 0), COALESCE(cfi.carbs_g, 0), COALESCE(cfi.fat_g, 0),
                       cfi.default_serving_qty, cfi.default_serving_unit, NULL, NULL,
                       lower(cfi.canonical_name || ' ' || cfi.display_name || ' ' || COALESCE(cfi.brand, '')) AS search_name,
                       lower(COALESCE(cfi.brand, '')) AS search_brand,
                       COALESCE(cfi.last_used_at_ms, cfi.updated_at_ms, 0) AS rank_time
                FROM canonical_food_items cfi
                WHERE cfi.deleted_at_ms IS NULL
            )
            SELECT id, source, kind, name, brand, calories_kcal, protein_g, carbs_g, fat_g,
                   default_serving_qty, default_serving_unit, source_title, source_url
            FROM library
            WHERE \(predicates)
            ORDER BY rank_time DESC, name COLLATE NOCASE
            LIMIT ?
            """,
            bindings: bindings
        )
        var output: [String: PiJSONValue] = ["query": .string(query), "results": .array(rows)]
        if let purpose {
            output["purpose"] = .string(purpose)
        }
        return PiToolResult(callID: call.id, output: .object(output))
    }
}

enum PiMacrodexDatabaseToolError: Error, LocalizedError {
    case missingRecipeItems
    case missingRecipeName
    case invalidRecipeId
    case missingCanonicalRecipe

    var errorDescription: String? {
        switch self {
        case .missingRecipeItems:
            return "No matching meal items were found to save as a recipe."
        case .missingRecipeName:
            return "Recipe helper requires a non-empty recipe name."
        case .invalidRecipeId:
            return "Recipe id cannot be blank."
        case .missingCanonicalRecipe:
            return "No valid non-blank recipe row was found or created for the requested recipe."
        }
    }
}

final class PiDatabaseSchemaToolRunner: PiToolRunner {
    private let sqlRunner: PiSQLiteToolRunner

    init(databaseURL: URL) {
        self.sqlRunner = PiSQLiteToolRunner(databaseURL: databaseURL)
    }

    func runTool(_ call: PiToolCall) throws -> PiToolResult {
        let args = call.arguments.objectValue ?? [:]
        var output = try sqlRunner.schema(tables: args["tables"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if let purpose = args["purpose"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
           case .object(var object) = output {
            object["purpose"] = .string(purpose)
            output = .object(object)
        }
        return PiToolResult(callID: call.id, output: output)
    }
}

final class PiDatabaseTransactionToolRunner: PiToolRunner {
    private let sqlRunner: PiSQLiteToolRunner

    init(databaseURL: URL) {
        self.sqlRunner = PiSQLiteToolRunner(
            databaseURL: databaseURL,
            requiredLeadingCommentMarker: "macrodex:"
        )
    }

    func runTool(_ call: PiToolCall) throws -> PiToolResult {
        let args = call.arguments.objectValue ?? [:]
        do {
            let operations = try PiSQLiteToolRunner.transactionOperations(from: args["operations"])
            var output = try sqlRunner.transaction(operations, dryRun: args["dryRun"]?.boolValue ?? false)
            if let purpose = args["purpose"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
               case .object(var object) = output {
                object["purpose"] = .string(purpose)
                output = .object(object)
            }
            return PiToolResult(callID: call.id, output: output)
        } catch {
            return Self.failureResult(callID: call.id, error: error)
        }
    }

    private static func failureResult(callID: String, error: Error) -> PiToolResult {
        PiToolResult(
            callID: callID,
            output: [
                "ok": false,
                "error": .string(error.localizedDescription),
                "recoverable": true,
                "hint": "Use db_schema first, then retry the operations with leading /* macrodex: Label */ SQL comments."
            ],
            isError: true
        )
    }
}

final class PiLogFoodToolRunner: PiToolRunner {
    private struct FoodMatch {
        var id: String
        var source: String
        var canonicalFoodId: String?
        var libraryItemId: String?
        var name: String
        var brand: String?
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var defaultServingQty: Double?
        var defaultServingUnit: String?
        var defaultServingWeight: Double?
    }

    private let sqlRunner: PiSQLiteToolRunner

    init(databaseURL: URL) {
        self.sqlRunner = PiSQLiteToolRunner(
            databaseURL: databaseURL,
            requiredLeadingCommentMarker: "macrodex:"
        )
    }

    func runTool(_ call: PiToolCall) throws -> PiToolResult {
        let args = call.arguments.objectValue ?? [:]
        let purpose = args["purpose"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank ?? "Logging food"
        let foodName = Self.firstString(args["foodName"], args["name"], args["query"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !foodName.isEmpty else {
            return Self.failureResult(callID: call.id, message: "log_food requires foodName.")
        }

        do {
            let match = try resolveFood(args: args, foodName: foodName)
            let explicitCalories = args["calories"]?.numberValue ?? args["caloriesKcal"]?.numberValue
            guard match != nil || explicitCalories != nil else {
                return Self.failureResult(
                    callID: call.id,
                    message: "No clear local food match was found and no calories were supplied.",
                    hint: "Use food_search for ambiguity. If local memory is missing, use web_search once for reliable nutrition data, then retry log_food with explicit calories/protein/carbs/fat totals or ask the user to confirm the serving."
                )
            }

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let logDate = args["logDate"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? Self.dateFormatter.string(from: Date())
            let mealType = Self.normalizedMealType(
                args["mealType"]?.stringValue ?? args["meal"]?.stringValue
            )
            let entryTitle = Self.mealTitle(mealType)
            let entryId = try existingEntryId(logDate: logDate, mealType: mealType) ?? UUID().uuidString.lowercased()
            let shouldInsertEntry = try existingEntryId(logDate: logDate, mealType: mealType) == nil
            let serving = normalizedServing(args: args, match: match)
            let scale = nutritionScale(serving: serving, match: match)
            let calories = explicitCalories ?? (match?.calories ?? 0) * scale
            let protein = args["protein"]?.numberValue ?? args["proteinG"]?.numberValue ?? (match?.protein ?? 0) * scale
            let carbs = args["carbs"]?.numberValue ?? args["carbsG"]?.numberValue ?? (match?.carbs ?? 0) * scale
            let fat = args["fat"]?.numberValue ?? args["fatG"]?.numberValue ?? (match?.fat ?? 0) * scale
            let zeroCaloriesConfirmed = args["confirmedZeroCalories"]?.boolValue
                ?? args["zeroCaloriesConfirmed"]?.boolValue
                ?? false
            if calories <= 0, !Self.isNaturallyZeroCalorie(foodName), !zeroCaloriesConfirmed {
                return Self.failureResult(
                    callID: call.id,
                    message: "The food resolved to zero calories, so logging was blocked until zero calories are confirmed.",
                    hint: "Zero-calorie logs are allowed. If this is truly zero calories, verify from an exact local item, official nutrition source, or the user, then retry with confirmedZeroCalories: true. For normal foods, use web_search once for reliable nutrition data and retry with explicit calories/protein/carbs/fat."
                )
            }
            let notes = args["notes"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            let logItemId = UUID().uuidString.lowercased()

            var operations: [PiSQLiteTransactionOperation] = []
            if shouldInsertEntry {
                operations.append(PiSQLiteTransactionOperation(
                    purpose: "Opening meal",
                    statement: """
                    /* macrodex: Opening meal */
                    INSERT INTO food_log_entries (
                        id, log_date, meal_type, title, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .string(entryId),
                        .string(logDate),
                        .string(mealType),
                        .string(entryTitle),
                        .number(Double(nowMs)),
                        .number(Double(nowMs))
                    ],
                    mode: .exec
                ))
            }
            operations.append(PiSQLiteTransactionOperation(
                purpose: "Logging food",
                statement: """
                /* macrodex: Logging food */
                INSERT INTO food_log_items (
                    id, entry_id, canonical_food_id, library_item_id, log_date, logged_at_ms,
                    name, serving_count, unit, weight_g, calories_kcal, protein_g, carbs_g, fat_g,
                    notes, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .string(logItemId),
                    .string(entryId),
                    match?.canonicalFoodId.map(PiJSONValue.string) ?? .null,
                    match?.libraryItemId.map(PiJSONValue.string) ?? .null,
                    .string(logDate),
                    .number(Double(nowMs)),
                    .string(match?.name ?? foodName),
                    .number(serving.quantity),
                    .string(serving.unit),
                    serving.weightGrams.map(PiJSONValue.number) ?? .null,
                    .number(calories),
                    .number(protein),
                    .number(carbs),
                    .number(fat),
                    notes.map(PiJSONValue.string) ?? .null,
                    .number(Double(nowMs)),
                    .number(Double(nowMs))
                ],
                mode: .exec
            ))
            operations.append(PiSQLiteTransactionOperation(
                purpose: "Confirming log",
                statement: """
                /* macrodex: Confirming log */
                SELECT fli.id, fli.name, fle.meal_type, fli.serving_count, fli.unit, fli.weight_g,
                       fli.calories_kcal, COALESCE(fli.protein_g, 0) AS protein_g,
                       COALESCE(fli.carbs_g, 0) AS carbs_g, COALESCE(fli.fat_g, 0) AS fat_g,
                       fli.library_item_id, fli.canonical_food_id
                FROM food_log_items fli
                LEFT JOIN food_log_entries fle ON fle.id = fli.entry_id AND fle.deleted_at_ms IS NULL
                WHERE fli.id = ? AND fli.deleted_at_ms IS NULL
                LIMIT 1
                """,
                bindings: [.string(logItemId)],
                mode: .query
            ))

            var output = try sqlRunner.transaction(operations)
            if case .object(var object) = output {
                object["purpose"] = .string(purpose)
                object["logItemId"] = .string(logItemId)
                object["entryId"] = .string(entryId)
                object["logDate"] = .string(logDate)
                object["mealType"] = .string(mealType)
                object["serving"] = [
                    "quantity": .number(serving.quantity),
                    "unit": .string(serving.unit),
                    "weightGrams": serving.weightGrams.map(PiJSONValue.number) ?? .null,
                    "display": .string(Self.servingDisplay(quantity: serving.quantity, unit: serving.unit))
                ]
                object["nutrition"] = [
                    "calories_kcal": .number(calories),
                    "protein_g": .number(protein),
                    "carbs_g": .number(carbs),
                    "fat_g": .number(fat),
                    "confirmed_zero_calories": .bool(calories <= 0 && (zeroCaloriesConfirmed || Self.isNaturallyZeroCalorie(foodName)))
                ]
                if let match {
                    object["matchedFood"] = [
                        "id": .string(match.id),
                        "source": .string(match.source),
                        "libraryItemId": match.libraryItemId.map(PiJSONValue.string) ?? .null,
                        "canonicalFoodId": match.canonicalFoodId.map(PiJSONValue.string) ?? .null,
                        "name": .string(match.name),
                        "brand": match.brand.map(PiJSONValue.string) ?? .null
                    ]
                }
                object["notes"] = .array(serving.notes.map(PiJSONValue.string))
                output = .object(object)
            }
            return PiToolResult(callID: call.id, output: output)
        } catch {
            return Self.failureResult(callID: call.id, message: error.localizedDescription)
        }
    }

    private func resolveFood(args: [String: PiJSONValue], foodName: String) throws -> FoodMatch? {
        if let libraryItemId = args["libraryItemId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            return try foodMatch(whereClause: "source = 'library' AND id = ?", bindings: [.string(libraryItemId)]).first
        }
        if let canonicalFoodId = args["canonicalFoodId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            return try foodMatch(whereClause: "source = 'canonical' AND id = ?", bindings: [.string(canonicalFoodId)]).first
        }
        let tokens = foodName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        let whereClause = tokens.map { _ in "search_name LIKE ?" }.joined(separator: " AND ")
        return try foodMatch(
            whereClause: whereClause,
            bindings: tokens.map { .string("%\($0)%") },
            exactName: foodName.lowercased()
        ).first
    }

    private func foodMatch(whereClause: String, bindings: [PiJSONValue], exactName: String? = nil) throws -> [FoodMatch] {
        let exactBinding = exactName.map(PiJSONValue.string) ?? .string("")
        let rows = try sqlRunner.query(
            """
            /* macrodex: Matching food */
            WITH candidates AS (
                SELECT fli.id, 'library' AS source, fli.canonical_food_id, fli.id AS library_item_id,
                       fli.name, fli.brand, fli.calories_kcal,
                       COALESCE(fli.protein_g, 0) AS protein_g,
                       COALESCE(fli.carbs_g, 0) AS carbs_g,
                       COALESCE(fli.fat_g, 0) AS fat_g,
                       fli.default_serving_qty, fli.default_serving_unit, fli.default_serving_weight_g,
                       lower(fli.name || ' ' || COALESCE(fli.brand, '') || ' ' || COALESCE(fa.aliases, '')) AS search_name,
                       COALESCE(fli.updated_at_ms, 0) AS rank_time
                FROM food_library_items fli
                LEFT JOIN (
                    SELECT library_item_id, GROUP_CONCAT(alias, ' ') AS aliases
                    FROM food_aliases
                    WHERE deleted_at_ms IS NULL
                    GROUP BY library_item_id
                ) fa ON fa.library_item_id = fli.id
                WHERE fli.deleted_at_ms IS NULL
                UNION ALL
                SELECT cfi.id, 'canonical' AS source, cfi.id AS canonical_food_id, NULL AS library_item_id,
                       cfi.display_name AS name, cfi.brand, cfi.calories_kcal,
                       COALESCE(cfi.protein_g, 0), COALESCE(cfi.carbs_g, 0), COALESCE(cfi.fat_g, 0),
                       cfi.default_serving_qty, cfi.default_serving_unit, cfi.default_serving_weight_g,
                       lower(cfi.canonical_name || ' ' || cfi.display_name || ' ' || COALESCE(cfi.brand, '')) AS search_name,
                       COALESCE(cfi.last_used_at_ms, cfi.updated_at_ms, 0) AS rank_time
                FROM canonical_food_items cfi
                WHERE cfi.deleted_at_ms IS NULL
            )
            SELECT id, source, canonical_food_id, library_item_id, name, brand, calories_kcal, protein_g,
                   carbs_g, fat_g, default_serving_qty, default_serving_unit, default_serving_weight_g
            FROM candidates
            WHERE \(whereClause)
            ORDER BY CASE WHEN lower(name) = ? THEN 0 WHEN source = 'library' THEN 1 ELSE 2 END,
                     rank_time DESC, name COLLATE NOCASE
            LIMIT 5
            """,
            bindings: bindings + [exactBinding]
        )
        return rows.compactMap { row in
            guard let object = row.objectValue else { return nil }
            return FoodMatch(
                id: object["id"]?.stringValue ?? "",
                source: object["source"]?.stringValue ?? "",
                canonicalFoodId: object["canonical_food_id"]?.stringValue?.nilIfBlank,
                libraryItemId: object["library_item_id"]?.stringValue?.nilIfBlank,
                name: object["name"]?.stringValue ?? "",
                brand: object["brand"]?.stringValue?.nilIfBlank,
                calories: object["calories_kcal"]?.numberValue ?? 0,
                protein: object["protein_g"]?.numberValue ?? 0,
                carbs: object["carbs_g"]?.numberValue ?? 0,
                fat: object["fat_g"]?.numberValue ?? 0,
                defaultServingQty: object["default_serving_qty"]?.numberValue,
                defaultServingUnit: object["default_serving_unit"]?.stringValue?.nilIfBlank,
                defaultServingWeight: object["default_serving_weight_g"]?.numberValue
            )
        }
    }

    private func existingEntryId(logDate: String, mealType: String) throws -> String? {
        try sqlRunner.query(
            """
            /* macrodex: Finding meal */
            SELECT id
            FROM food_log_entries
            WHERE log_date = ? AND meal_type = ? AND deleted_at_ms IS NULL
            LIMIT 1
            """,
            bindings: [.string(logDate), .string(mealType)]
        ).first?.objectValue?["id"]?.stringValue
    }

    private struct Serving {
        var quantity: Double
        var unit: String
        var weightGrams: Double?
        var notes: [String]
    }

    private func normalizedServing(args: [String: PiJSONValue], match: FoodMatch?) -> Serving {
        let hasExplicitQuantity = args["quantity"]?.numberValue != nil
            || args["servingCount"]?.numberValue != nil
            || args["amount"]?.numberValue != nil
        let quantity = args["quantity"]?.numberValue
            ?? args["servingCount"]?.numberValue
            ?? args["amount"]?.numberValue
            ?? match?.defaultServingQty
            ?? 1
        var unit = Self.firstString(args["unit"], args["servingUnit"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if unit.isEmpty {
            unit = match?.defaultServingUnit ?? (hasExplicitQuantity ? Self.countUnitGuess(from: match?.name ?? Self.foodNameFallback(args: args)) : "serving")
        }
        var weight = args["weightGrams"]?.numberValue
            ?? args["weight_g"]?.numberValue
            ?? args["weight"]?.numberValue
        var notes: [String] = []
        let lowerUnit = unit.lowercased()
        let isMassOrVolume = ["g", "gram", "grams", "ml", "milliliter", "milliliters"].contains(lowerUnit)
        let matchDefaultUnit = match?.defaultServingUnit?.lowercased()
        let defaultIsMassOrVolume = matchDefaultUnit.map { ["g", "gram", "grams", "ml", "milliliter", "milliliters"].contains($0) } ?? false
        if isMassOrVolume, quantity > 0, quantity < 10, weight == nil, !defaultIsMassOrVolume, let defaultWeight = match?.defaultServingWeight {
            notes.append("Normalized a small mass-looking amount to serving because it looked like a fractional serving.")
            unit = "serving"
            weight = defaultWeight * quantity
        } else if isMassOrVolume, weight == nil {
            weight = quantity
        } else if !isMassOrVolume, weight == nil, let defaultWeight = match?.defaultServingWeight {
            let defaultQty = max(match?.defaultServingQty ?? 1, 0.0001)
            weight = defaultWeight * (quantity / defaultQty)
        }
        return Serving(quantity: quantity, unit: unit, weightGrams: weight, notes: notes)
    }

    private static func foodNameFallback(args: [String: PiJSONValue]) -> String {
        firstString(args["foodName"], args["name"], args["query"])
    }

    private static func countUnitGuess(from foodName: String) -> String {
        let lowercased = foodName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowercased.hasSuffix("s"), lowercased.count > 2 {
            return lowercased
        }
        return "serving"
    }

    private static func isNaturallyZeroCalorie(_ foodName: String) -> Bool {
        let normalized = foodName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let naturallyZeroNames: Set<String> = [
            "water",
            "sparkling water",
            "club soda",
            "seltzer",
            "black coffee",
            "unsweetened tea",
            "tea",
            "green tea",
            "diet soda",
            "diet coke",
            "coke zero",
            "zero sugar soda"
        ]
        return naturallyZeroNames.contains(normalized)
    }

    private func nutritionScale(serving: Serving, match: FoodMatch?) -> Double {
        guard let match else { return 1 }
        let lowerUnit = serving.unit.lowercased()
        if ["g", "gram", "grams", "ml", "milliliter", "milliliters"].contains(lowerUnit),
           let defaultWeight = match.defaultServingWeight,
           defaultWeight > 0 {
            return serving.quantity / defaultWeight
        }
        let defaultUnit = match.defaultServingUnit?.lowercased()
        if let defaultUnit, defaultUnit == lowerUnit, let defaultQty = match.defaultServingQty, defaultQty > 0 {
            return serving.quantity / defaultQty
        }
        if ["serving", "servings", "unit", "units", "piece", "pieces", "count"].contains(lowerUnit) {
            let defaultQty = max(match.defaultServingQty ?? 1, 0.0001)
            return serving.quantity / defaultQty
        }
        return 1
    }

    private static func firstString(_ values: PiJSONValue?...) -> String {
        for value in values {
            if let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                return string
            }
        }
        return ""
    }

    private static func normalizedMealType(_ value: String?) -> String {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "breakfast", "lunch", "dinner", "snack", "drink", "pre_workout", "post_workout", "other":
            return normalized!
        case "preworkout":
            return "pre_workout"
        case "postworkout":
            return "post_workout"
        default:
            let hour = Calendar.current.component(.hour, from: Date())
            switch hour {
            case 5..<11: return "breakfast"
            case 11..<16: return "lunch"
            case 16..<22: return "dinner"
            default: return "snack"
            }
        }
    }

    private static func mealTitle(_ mealType: String) -> String {
        switch mealType {
        case "breakfast": return "Breakfast"
        case "lunch": return "Lunch"
        case "dinner": return "Dinner"
        case "snack": return "Snack"
        case "drink": return "Drinks"
        case "pre_workout": return "Pre-workout"
        case "post_workout": return "Post-workout"
        default: return "Other"
        }
    }

    private static func servingDisplay(quantity: Double, unit: String) -> String {
        if unit.lowercased() == "serving", quantity == 1 {
            return "1 serving"
        }
        return "\(cleanString(quantity)) \(unit)"
    }

    private static func cleanString(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    private static func failureResult(callID: String, message: String, hint: String? = nil) -> PiToolResult {
        var output: [String: PiJSONValue] = [
            "ok": false,
            "error": .string(message),
            "recoverable": true
        ]
        if let hint {
            output["hint"] = .string(hint)
        }
        return PiToolResult(callID: callID, output: .object(output), isError: true)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

final class PiSaveRecipeFromMealToolRunner: PiToolRunner {
    private struct MealItem {
        var id: String
        var libraryItemId: String?
        var name: String
        var quantity: Double
        var unit: String
        var weight: Double?
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var logDate: String
        var mealType: String?
    }

    private let sqlRunner: PiSQLiteToolRunner

    init(databaseURL: URL) {
        self.sqlRunner = PiSQLiteToolRunner(
            databaseURL: databaseURL,
            requiredLeadingCommentMarker: "macrodex:"
        )
    }

    func runTool(_ call: PiToolCall) throws -> PiToolResult {
        let args = call.arguments.objectValue ?? [:]
        let purpose = args["purpose"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        let recipeName = (args["recipeName"]?.stringValue ?? args["name"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipeName.isEmpty else {
            return Self.failureResult(callID: call.id, error: PiMacrodexDatabaseToolError.missingRecipeName)
        }
        let ignoredBlankRecipeId = Self.hasBlankString(args["recipeId"], args["canonicalRecipeId"], args["replaceExistingRecipeId"])

        do {
            let items = try fetchMealItems(args: args)
            guard !items.isEmpty else {
                return Self.failureResult(callID: call.id, error: PiMacrodexDatabaseToolError.missingRecipeItems)
            }

            let now = Date().timeIntervalSince1970 * 1000
            let requestedRecipeId = Self.firstNonBlankString(args["recipeId"], args["replaceExistingRecipeId"])
            let activeRecipeIds = try activeRecipeIds(named: recipeName)
            let recipeId: String
            if let requestedRecipeId {
                recipeId = requestedRecipeId
            } else if let existingRecipeId = activeRecipeIds.first {
                recipeId = existingRecipeId
            } else {
                recipeId = UUID().uuidString.lowercased()
            }
            guard !recipeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.failureResult(callID: call.id, error: PiMacrodexDatabaseToolError.invalidRecipeId)
            }
            let dryRun = args["dryRun"]?.boolValue ?? args["preview"]?.boolValue ?? false
            let linkLogItems = args["linkLogItems"]?.boolValue ?? true
            let totals = items.reduce((calories: 0.0, protein: 0.0, carbs: 0.0, fat: 0.0)) { partial, item in
                (
                    calories: partial.calories + item.calories,
                    protein: partial.protein + item.protein,
                    carbs: partial.carbs + item.carbs,
                    fat: partial.fat + item.fat
                )
            }

            let exists = try existingRecipeId(id: recipeId) != nil
            let duplicateRecipeIds = activeRecipeIds.filter { $0 != recipeId }
            var operations: [PiSQLiteTransactionOperation] = []
            if exists {
                operations.append(PiSQLiteTransactionOperation(
                    purpose: "Updating recipe",
                    statement: """
                    /* macrodex: Updating recipe */
                    UPDATE food_library_items
                    SET kind = 'recipe', name = ?, calories_kcal = ?, protein_g = ?, carbs_g = ?,
                        fat_g = ?, default_serving_qty = 1, default_serving_unit = 'recipe',
                        updated_at_ms = ?, deleted_at_ms = NULL
                    WHERE id = ?
                    """,
                    bindings: [
                        .string(recipeName),
                        .number(totals.calories),
                        .number(totals.protein),
                        .number(totals.carbs),
                        .number(totals.fat),
                        .number(now),
                        .string(recipeId)
                    ],
                    mode: .exec
                ))
            } else {
                operations.append(PiSQLiteTransactionOperation(
                    purpose: "Creating recipe",
                    statement: """
                    /* macrodex: Creating recipe */
                    INSERT INTO food_library_items (
                        id, kind, name, default_serving_qty, default_serving_unit,
                        calories_kcal, protein_g, carbs_g, fat_g, created_at_ms, updated_at_ms
                    ) VALUES (?, 'recipe', ?, 1, 'recipe', ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .string(recipeId),
                        .string(recipeName),
                        .number(totals.calories),
                        .number(totals.protein),
                        .number(totals.carbs),
                        .number(totals.fat),
                        .number(now),
                        .number(now)
                    ],
                    mode: .exec
                ))
            }

            operations.append(PiSQLiteTransactionOperation(
                purpose: "Replacing components",
                statement: """
                /* macrodex: Replacing components */
                UPDATE recipe_components
                SET deleted_at_ms = ?, updated_at_ms = ?
                WHERE recipe_id = ? AND deleted_at_ms IS NULL
                """,
                bindings: [.number(now), .number(now), .string(recipeId)],
                mode: .exec
            ))

            for (index, item) in items.enumerated() {
                let componentItemId = item.libraryItemId == recipeId ? nil : item.libraryItemId
                operations.append(PiSQLiteTransactionOperation(
                    purpose: "Adding component",
                    statement: """
                    /* macrodex: Adding component */
                    INSERT INTO recipe_components (
                        id, recipe_id, component_item_id, component_name, quantity, unit, weight_g,
                        calories_kcal, protein_g, carbs_g, fat_g, sort_order, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .string(UUID().uuidString.lowercased()),
                        .string(recipeId),
                        componentItemId.map(PiJSONValue.string) ?? .null,
                        .string(item.name),
                        .number(item.quantity),
                        .string(item.unit),
                        item.weight.map(PiJSONValue.number) ?? .null,
                        .number(item.calories),
                        .number(item.protein),
                        .number(item.carbs),
                        .number(item.fat),
                        .number(Double(index)),
                        .number(now),
                        .number(now)
                    ],
                    mode: .exec
                ))
            }

            if linkLogItems {
                let placeholders = items.map { _ in "?" }.joined(separator: ", ")
                operations.append(PiSQLiteTransactionOperation(
                    purpose: "Linking meal",
                    statement: """
                    /* macrodex: Linking meal */
                    UPDATE food_log_items
                    SET library_item_id = ?, updated_at_ms = ?
                    WHERE id IN (\(placeholders)) AND deleted_at_ms IS NULL
                    """,
                    bindings: [.string(recipeId), .number(now)] + items.map { .string($0.id) },
                    mode: .exec
                ))
            }

            operations.append(PiSQLiteTransactionOperation(
                purpose: "Confirming recipe",
                statement: """
                /* macrodex: Confirming recipe */
                SELECT id, kind, name, calories_kcal, protein_g, carbs_g, fat_g
                FROM food_library_items
                WHERE id = ? AND kind = 'recipe' AND deleted_at_ms IS NULL
                """,
                bindings: [.string(recipeId)],
                mode: .query
            ))

            var transaction = try sqlRunner.transaction(operations, dryRun: dryRun)
            if case .object(var object) = transaction {
                object["purpose"] = purpose.map(PiJSONValue.string) ?? .string("Saving recipe")
                object["recipeId"] = .string(recipeId)
                object["recipe_id"] = .string(recipeId)
                object["canonicalRecipeId"] = .string(recipeId)
                object["canonical_recipe_id"] = .string(recipeId)
                object["active_item_id"] = .string(recipeId)
                object["created_new"] = .bool(!exists)
                object["updated_existing"] = .bool(exists)
                object["archived_conflict"] = .bool(false)
                object["preview"] = .bool(dryRun)
                object["ignored_blank_recipe_id"] = .bool(ignoredBlankRecipeId)
                object["duplicate_recipe_ids"] = .array(duplicateRecipeIds.map(PiJSONValue.string))
                object["notes"] = .array(Self.statusNotes(
                    ignoredBlankRecipeId: ignoredBlankRecipeId,
                    duplicateRecipeIds: duplicateRecipeIds,
                    dryRun: dryRun,
                    archivedConflict: false
                ))
                object["recipe"] = [
                    "id": .string(recipeId),
                    "recipeId": .string(recipeId),
                    "name": .string(recipeName),
                    "calories_kcal": .number(totals.calories),
                    "protein_g": .number(totals.protein),
                    "carbs_g": .number(totals.carbs),
                    "fat_g": .number(totals.fat)
                ]
                object["source"] = [
                    "logDate": .string(items.first?.logDate ?? ""),
                    "mealType": items.first?.mealType.map(PiJSONValue.string) ?? .null,
                    "logItemIds": .array(items.map { .string($0.id) })
                ]
                object["components"] = .array(items.map { item in
                    let componentItemId = item.libraryItemId == recipeId ? nil : item.libraryItemId
                    return [
                        "logItemId": .string(item.id),
                        "componentItemId": componentItemId.map(PiJSONValue.string) ?? .null,
                        "name": .string(item.name),
                        "quantity": .number(item.quantity),
                        "unit": .string(item.unit),
                        "calories_kcal": .number(item.calories),
                        "protein_g": .number(item.protein),
                        "carbs_g": .number(item.carbs),
                        "fat_g": .number(item.fat)
                    ]
                })
                transaction = .object(object)
            }
            return PiToolResult(callID: call.id, output: transaction)
        } catch {
            return Self.failureResult(callID: call.id, error: error)
        }
    }

    private func fetchMealItems(args: [String: PiJSONValue]) throws -> [MealItem] {
        let explicitIds = (args["logItemIds"]?.arrayValue ?? args["itemIds"]?.arrayValue)?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
            ?? []
        var predicates: [String] = ["fli.deleted_at_ms IS NULL"]
        var bindings: [PiJSONValue] = []
        if !explicitIds.isEmpty {
            predicates.append("fli.id IN (\(explicitIds.map { _ in "?" }.joined(separator: ", ")))")
            bindings.append(contentsOf: explicitIds.map { .string($0) })
        } else if let entryId = args["entryId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            predicates.append("fli.entry_id = ?")
            bindings.append(.string(entryId))
        } else {
            let date = args["logDate"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? Self.dateFormatter.string(from: Date())
            predicates.append("fli.log_date = ?")
            bindings.append(.string(date))
            if let mealType = args["mealType"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
                predicates.append("fle.meal_type = ?")
                bindings.append(.string(mealType))
            }
        }

        let rows = try sqlRunner.query(
            """
            /* macrodex: Reading meal */
            SELECT fli.id, fli.library_item_id, fli.name,
                   COALESCE(fli.serving_count, fli.quantity, 1) AS quantity,
                   COALESCE(fli.unit, 'serving') AS unit,
                   fli.weight_g,
                   fli.calories_kcal,
                   COALESCE(fli.protein_g, 0) AS protein_g,
                   COALESCE(fli.carbs_g, 0) AS carbs_g,
                   COALESCE(fli.fat_g, 0) AS fat_g,
                   fli.log_date,
                   fle.meal_type
            FROM food_log_items fli
            LEFT JOIN food_log_entries fle ON fle.id = fli.entry_id AND fle.deleted_at_ms IS NULL
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY fli.logged_at_ms ASC, fli.created_at_ms ASC
            """,
            bindings: bindings
        )
        return rows.compactMap { row in
            guard let object = row.objectValue,
                  let id = object["id"]?.stringValue,
                  let name = object["name"]?.stringValue,
                  let calories = object["calories_kcal"]?.numberValue,
                  let logDate = object["log_date"]?.stringValue
            else {
                return nil
            }
            return MealItem(
                id: id,
                libraryItemId: object["library_item_id"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfBlank,
                name: name,
                quantity: object["quantity"]?.numberValue ?? 1,
                unit: object["unit"]?.stringValue ?? "serving",
                weight: object["weight_g"]?.numberValue,
                calories: calories,
                protein: object["protein_g"]?.numberValue ?? 0,
                carbs: object["carbs_g"]?.numberValue ?? 0,
                fat: object["fat_g"]?.numberValue ?? 0,
                logDate: logDate,
                mealType: object["meal_type"]?.stringValue
            )
        }
    }

    private func activeRecipeIds(named name: String) throws -> [String] {
        try sqlRunner.query(
            """
            /* macrodex: Finding recipe */
            SELECT id
            FROM food_library_items
            WHERE kind = 'recipe' AND deleted_at_ms IS NULL AND lower(name) = lower(?)
              AND id IS NOT NULL AND trim(id) <> ''
            ORDER BY updated_at_ms DESC
            """,
            bindings: [.string(name)]
        ).compactMap { $0.objectValue?["id"]?.stringValue }
    }

    private func existingRecipeId(id: String) throws -> String? {
        try sqlRunner.query(
            """
            /* macrodex: Checking recipe */
            SELECT id
            FROM food_library_items
            WHERE id = ? AND kind = 'recipe' AND deleted_at_ms IS NULL
              AND id IS NOT NULL AND trim(id) <> ''
            LIMIT 1
            """,
            bindings: [.string(id)]
        ).first?.objectValue?["id"]?.stringValue
    }

    fileprivate static func firstNonBlankString(_ values: PiJSONValue?...) -> String? {
        values.lazy
            .compactMap(\.?.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    fileprivate static func hasBlankString(_ values: PiJSONValue?...) -> Bool {
        values.contains { value in
            guard let string = value?.stringValue else {
                return false
            }
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    fileprivate static func statusNotes(
        ignoredBlankRecipeId: Bool,
        duplicateRecipeIds: [String],
        dryRun: Bool,
        archivedConflict: Bool
    ) -> [PiJSONValue] {
        var notes: [PiJSONValue] = []
        if ignoredBlankRecipeId {
            notes.append(.string("Ignored a blank recipe id and resolved the recipe automatically."))
        }
        if !duplicateRecipeIds.isEmpty {
            notes.append(.string("Found duplicate active recipe rows for the same name: \(duplicateRecipeIds.joined(separator: ", "))."))
        }
        if dryRun {
            notes.append(.string("Preview only; no database changes were committed."))
        }
        if archivedConflict {
            notes.append(.string("Archived a blank-id recipe artifact after resolving the canonical recipe."))
        }
        return notes
    }

    private static func failureResult(callID: String, error: Error) -> PiToolResult {
        PiToolResult(
            callID: callID,
            output: [
                "ok": false,
                "error": .string(error.localizedDescription),
                "recoverable": true,
                "hint": "Use db_schema to inspect food_log_items, food_library_items, and recipe_components before retrying."
            ],
            isError: true
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

final class PiFinalizeRecipeSaveToolRunner: PiToolRunner {
    private struct RecipeResolution {
        var id: String
        var creationOperation: PiSQLiteTransactionOperation?
        var duplicateIds: [String]

        var createdNew: Bool {
            creationOperation != nil
        }
    }

    private let sqlRunner: PiSQLiteToolRunner

    init(databaseURL: URL) {
        self.sqlRunner = PiSQLiteToolRunner(
            databaseURL: databaseURL,
            requiredLeadingCommentMarker: "macrodex:"
        )
    }

    func runTool(_ call: PiToolCall) throws -> PiToolResult {
        let args = call.arguments.objectValue ?? [:]
        let purpose = args["purpose"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        let recipeName = (args["recipeName"]?.stringValue ?? args["name"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipeName.isEmpty else {
            return Self.failureResult(callID: call.id, error: PiMacrodexDatabaseToolError.missingRecipeName)
        }
        let ignoredBlankRecipeId = PiSaveRecipeFromMealToolRunner.hasBlankString(args["recipeId"], args["canonicalRecipeId"], args["replaceExistingRecipeId"])

        do {
            let dryRun = args["dryRun"]?.boolValue ?? args["preview"]?.boolValue ?? false
            let now = Date().timeIntervalSince1970 * 1000
            let recipeResolution = try canonicalRecipeResolution(args: args, recipeName: recipeName, now: now)
            let canonicalRecipeId = recipeResolution.id
            guard !canonicalRecipeId.isEmpty else {
                return Self.failureResult(callID: call.id, error: PiMacrodexDatabaseToolError.missingCanonicalRecipe)
            }
            let hadBlankRecipeArtifact = try blankRecipeArtifactExists()

            var operations: [PiSQLiteTransactionOperation] = []
            if let creationOperation = recipeResolution.creationOperation {
                operations.append(creationOperation)
            }
            operations.append(
                PiSQLiteTransactionOperation(
                    purpose: "Moving components",
                    statement: """
                    /* macrodex: Moving components */
                    UPDATE recipe_components
                    SET recipe_id = ?, updated_at_ms = ?
                    WHERE recipe_id = '' AND deleted_at_ms IS NULL
                    """,
                    bindings: [.string(canonicalRecipeId), .number(now)],
                    mode: .exec
                )
            )

            if let logItemFilter = Self.logItemFilter(args: args) {
                operations.append(PiSQLiteTransactionOperation(
                    purpose: "Relinking meal",
                    statement: """
                    /* macrodex: Relinking meal */
                    UPDATE food_log_items
                    SET library_item_id = ?, updated_at_ms = ?
                    WHERE library_item_id = '' AND deleted_at_ms IS NULL AND \(logItemFilter.sql)
                    """,
                    bindings: [.string(canonicalRecipeId), .number(now)] + logItemFilter.bindings,
                    mode: .exec
                ))
            }

            operations.append(contentsOf: [
                PiSQLiteTransactionOperation(
                    purpose: "Archiving blank recipe",
                    statement: """
                    /* macrodex: Archiving blank recipe */
                    UPDATE food_library_items
                    SET deleted_at_ms = ?, updated_at_ms = ?
                    WHERE id = '' AND kind = 'recipe' AND deleted_at_ms IS NULL
                    """,
                    bindings: [.number(now), .number(now)],
                    mode: .exec
                ),
                PiSQLiteTransactionOperation(
                    purpose: "Confirming recipe",
                    statement: """
                    /* macrodex: Confirming recipe */
                    SELECT fli.id, fli.kind, fli.name, fli.calories_kcal, fli.protein_g, fli.carbs_g, fli.fat_g,
                           COUNT(rc.id) AS component_count
                    FROM food_library_items fli
                    LEFT JOIN recipe_components rc ON rc.recipe_id = fli.id AND rc.deleted_at_ms IS NULL
                    WHERE fli.id = ? AND fli.kind = 'recipe' AND fli.deleted_at_ms IS NULL
                    GROUP BY fli.id
                    """,
                    bindings: [.string(canonicalRecipeId)],
                    mode: .query
                )
            ])

            var transaction = try sqlRunner.transaction(operations, dryRun: dryRun)
            if case .object(var object) = transaction {
                object["purpose"] = purpose.map(PiJSONValue.string) ?? .string("Finalizing recipe")
                object["recipeId"] = .string(canonicalRecipeId)
                object["recipe_id"] = .string(canonicalRecipeId)
                object["canonicalRecipeId"] = .string(canonicalRecipeId)
                object["canonical_recipe_id"] = .string(canonicalRecipeId)
                object["recipeName"] = .string(recipeName)
                object["active_item_id"] = .string(canonicalRecipeId)
                object["created_new"] = .bool(recipeResolution.createdNew)
                object["updated_existing"] = .bool(!recipeResolution.createdNew)
                object["archived_conflict"] = .bool(!dryRun && hadBlankRecipeArtifact)
                object["would_archive_conflict"] = .bool(hadBlankRecipeArtifact)
                object["preview"] = .bool(dryRun)
                object["ignored_blank_recipe_id"] = .bool(ignoredBlankRecipeId)
                object["duplicate_recipe_ids"] = .array(recipeResolution.duplicateIds.map(PiJSONValue.string))
                object["notes"] = .array(PiSaveRecipeFromMealToolRunner.statusNotes(
                    ignoredBlankRecipeId: ignoredBlankRecipeId,
                    duplicateRecipeIds: recipeResolution.duplicateIds,
                    dryRun: dryRun,
                    archivedConflict: !dryRun && hadBlankRecipeArtifact
                ))
                transaction = .object(object)
            }
            return PiToolResult(callID: call.id, output: transaction)
        } catch {
            return Self.failureResult(callID: call.id, error: error)
        }
    }

    private func canonicalRecipeResolution(args: [String: PiJSONValue], recipeName: String, now: Double) throws -> RecipeResolution {
        let requestedId = PiSaveRecipeFromMealToolRunner.firstNonBlankString(args["recipeId"], args["canonicalRecipeId"], args["replaceExistingRecipeId"])
        let activeIds = try activeRecipeIds(named: recipeName)
        if let requested = requestedId,
           try activeRecipeId(requested) != nil {
            return RecipeResolution(
                id: requested,
                creationOperation: nil,
                duplicateIds: activeIds.filter { $0 != requested }
            )
        }
        if let existing = activeIds.first {
            return RecipeResolution(
                id: existing,
                creationOperation: nil,
                duplicateIds: Array(activeIds.dropFirst())
            )
        }
        if let blank = try sqlRunner.query(
            """
            /* macrodex: Reading blank recipe */
            SELECT name, calories_kcal, COALESCE(protein_g, 0) AS protein_g,
                   COALESCE(carbs_g, 0) AS carbs_g, COALESCE(fat_g, 0) AS fat_g
            FROM food_library_items
            WHERE id = '' AND kind = 'recipe' AND deleted_at_ms IS NULL
            LIMIT 1
            """
        ).first?.objectValue {
            let id = requestedId ?? UUID().uuidString.lowercased()
            return RecipeResolution(
                id: id,
                creationOperation: PiSQLiteTransactionOperation(
                    purpose: "Creating recipe",
                    statement: """
                    /* macrodex: Creating recipe */
                    INSERT INTO food_library_items (
                        id, kind, name, default_serving_qty, default_serving_unit,
                        calories_kcal, protein_g, carbs_g, fat_g, created_at_ms, updated_at_ms
                    ) VALUES (?, 'recipe', ?, 1, 'recipe', ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .string(id),
                        .string(blank["name"]?.stringValue?.nilIfBlank ?? recipeName),
                        .number(blank["calories_kcal"]?.numberValue ?? 0),
                        .number(blank["protein_g"]?.numberValue ?? 0),
                        .number(blank["carbs_g"]?.numberValue ?? 0),
                        .number(blank["fat_g"]?.numberValue ?? 0),
                        .number(now),
                        .number(now)
                    ],
                    mode: .exec
                ),
                duplicateIds: activeIds
            )
        }
        throw PiMacrodexDatabaseToolError.missingCanonicalRecipe
    }

    private func activeRecipeIds(named name: String) throws -> [String] {
        try sqlRunner.query(
            """
            /* macrodex: Finding recipe */
            SELECT id
            FROM food_library_items
            WHERE kind = 'recipe' AND deleted_at_ms IS NULL AND lower(name) = lower(?)
              AND id IS NOT NULL AND trim(id) <> ''
            ORDER BY updated_at_ms DESC
            """,
            bindings: [.string(name)]
        ).compactMap { $0.objectValue?["id"]?.stringValue }
    }

    private func activeRecipeId(_ id: String) throws -> String? {
        try sqlRunner.query(
            """
            /* macrodex: Checking recipe */
            SELECT id
            FROM food_library_items
            WHERE id = ? AND kind = 'recipe' AND deleted_at_ms IS NULL
              AND id IS NOT NULL AND trim(id) <> ''
            LIMIT 1
            """,
            bindings: [.string(id)]
        ).first?.objectValue?["id"]?.stringValue
    }

    private func blankRecipeArtifactExists() throws -> Bool {
        try sqlRunner.query(
            """
            /* macrodex: Checking conflicts */
            SELECT id
            FROM food_library_items
            WHERE id = '' AND kind = 'recipe' AND deleted_at_ms IS NULL
            LIMIT 1
            """
        ).isEmpty == false
    }

    private static func logItemFilter(args: [String: PiJSONValue]) -> (sql: String, bindings: [PiJSONValue])? {
        let ids = (args["logItemIds"]?.arrayValue ?? args["itemIds"]?.arrayValue)?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
            ?? []
        if !ids.isEmpty {
            return ("id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))", ids.map { .string($0) })
        }
        var clauses: [String] = []
        var bindings: [PiJSONValue] = []
        if let logDate = args["logDate"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            clauses.append("log_date = ?")
            bindings.append(.string(logDate))
        }
        if let mealType = args["mealType"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            clauses.append("entry_id IN (SELECT id FROM food_log_entries WHERE meal_type = ? AND deleted_at_ms IS NULL)")
            bindings.append(.string(mealType))
        }
        guard !clauses.isEmpty else {
            return nil
        }
        return (clauses.joined(separator: " AND "), bindings)
    }

    private static func failureResult(callID: String, error: Error) -> PiToolResult {
        PiToolResult(
            callID: callID,
            output: [
                "ok": false,
                "error": .string(error.localizedDescription),
                "recoverable": true,
                "hint": "Pass recipeName plus recipeId/canonicalRecipeId when known, and logDate/mealType or logItemIds to safely relink blank meal rows."
            ],
            isError: true
        )
    }
}

enum PiMacrodexToolDefinitions {
    static let healthKit = PiToolDefinition(
        name: "healthkit",
        description: "Read Apple Health samples, summarize Apple Health trends, sync Macrodex nutrition to Apple Health, and write explicit user-requested Apple Health records. For nutrition sync, run sync-nutrition directly; skipped fields or missing setup are returned as normal tool output.",
        inputSchema: [
            "type": "object",
            "properties": [
                "purpose": ["type": "string", "description": "Short present-tense user-facing purpose for this health action."],
                "command": [
                    "type": "string",
                    "description": "HealthKit subcommand: query, stats, sync-nutrition, types, status, request, write-quantity, write-category, or write-workout."
                ],
                "args": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Optional raw CLI-style arguments after the command, for example [\"--identifier\", \"stepCount\", \"--start\", \"today\"]."
                ]
            ],
            "required": ["command"]
        ]
    )

    static let foodSearch = PiToolDefinition(
        name: "food_search",
        description: "Fuzzy-search Macrodex local food memory, library foods, and recipes. Use this before raw SQL or web search for food macros.",
        inputSchema: [
            "type": "object",
            "properties": [
                "purpose": ["type": "string", "description": "Short present-tense user-facing purpose for this food search."],
                "query": ["type": "string", "description": "Food name, brand, or alias to search for."],
                "limit": ["type": "integer", "description": "Maximum results, default 10, max 25."]
            ],
            "required": ["query"]
        ]
    )

    static let logFood = PiToolDefinition(
        name: "log_food",
        description: "Fast-path log a single food item using Macrodex local food memory. It resolves a matching food, normalizes human serving units, writes the meal entry and food row atomically, and returns the inserted ids plus confirmation data in one tool call. Prefer this over raw SQL for normal calorie logging. If it cannot find reliable local macros or blocks a zero-calorie real food, use web_search once and retry with explicit macros instead of logging bad data. Zero-calorie logs are allowed only for obvious zero-calorie foods or when confirmedZeroCalories is true after verification.",
        inputSchema: [
            "type": "object",
            "properties": [
                "purpose": ["type": "string", "description": "Short present-tense user-facing purpose, such as Logging breakfast."],
                "foodName": ["type": "string", "description": "Food name to log. Aliases: name, query."],
                "name": ["type": "string", "description": "Alias for foodName."],
                "query": ["type": "string", "description": "Alias for foodName."],
                "mealType": ["type": "string", "description": "Meal category: breakfast, lunch, dinner, snack, drink, pre_workout, post_workout, or other. Alias: meal."],
                "meal": ["type": "string", "description": "Alias for mealType."],
                "logDate": ["type": "string", "description": "yyyy-MM-dd date. Defaults to today."],
                "quantity": ["type": "number", "description": "User-facing serving amount, such as 0.8, 1, 2, or 100. Aliases: servingCount, amount."],
                "servingCount": ["type": "number", "description": "Alias for quantity."],
                "amount": ["type": "number", "description": "Alias for quantity."],
                "unit": ["type": "string", "description": "User-facing unit, such as serving, cup, egg, piece, g, or ml. Prefer serving/count units unless the user specifically gives grams or milliliters."],
                "servingUnit": ["type": "string", "description": "Alias for unit."],
                "weightGrams": ["type": "number", "description": "Optional actual gram weight for the serving. Use this separately when quantity is in servings/counts."],
                "calories": ["type": "number", "description": "Optional calories for this logged amount when no local match exists."],
                "caloriesKcal": ["type": "number", "description": "Alias for calories."],
                "protein": ["type": "number", "description": "Optional protein grams for this logged amount."],
                "proteinG": ["type": "number", "description": "Alias for protein."],
                "carbs": ["type": "number", "description": "Optional carb grams for this logged amount."],
                "carbsG": ["type": "number", "description": "Alias for carbs."],
                "fat": ["type": "number", "description": "Optional fat grams for this logged amount."],
                "fatG": ["type": "number", "description": "Alias for fat."],
                "confirmedZeroCalories": ["type": "boolean", "description": "Set true only after verifying this specific food/serving is intentionally zero calories from an exact local item, official nutrition source, or user confirmation. Alias: zeroCaloriesConfirmed."],
                "zeroCaloriesConfirmed": ["type": "boolean", "description": "Alias for confirmedZeroCalories."],
                "libraryItemId": ["type": "string", "description": "Optional exact food_library_items id to log."],
                "canonicalFoodId": ["type": "string", "description": "Optional exact canonical_food_items id to log."],
                "notes": ["type": "string", "description": "Optional user-visible notes for the log item."]
            ],
            "required": ["foodName"]
        ]
    )

    static let databaseSchema = PiToolDefinition(
        name: "db_schema",
        description: "Inspect Macrodex SQLite tables, columns, indexes, and foreign keys. Use this before uncertain food-log, recipe, or preference writes.",
        inputSchema: [
            "type": "object",
            "properties": [
                "purpose": ["type": "string", "description": "Short present-tense user-facing purpose."],
                "tables": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Optional table names. Empty returns common Macrodex food tables."
                ]
            ]
        ]
    )

    static let databaseTransaction = PiToolDefinition(
        name: "db_transaction",
        description: "Run multiple labeled SQL operations atomically on one SQLite connection. Each statement must start with a /* macrodex: Label */ or -- macrodex: Label comment. Returns per-operation confirmations and query rows in one tool call.",
        inputSchema: [
            "type": "object",
            "properties": [
                "purpose": ["type": "string", "description": "Short present-tense user-facing purpose."],
                "dryRun": ["type": "boolean", "description": "When true, execute inside a savepoint and roll back after collecting confirmations."],
                "operations": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "purpose": ["type": "string"],
                            "statement": ["type": "string"],
                            "bindings": ["type": "array", "items": ["description": "JSON SQL binding value."]],
                            "mode": ["type": "string", "enum": ["auto", "query", "exec", "validate"]]
                        ],
                        "required": ["statement"]
                    ]
                ]
            ],
            "required": ["operations"]
        ]
    )

    static let saveRecipeFromMeal = PiToolDefinition(
        name: "save_recipe_from_meal",
        description: "Create or update a saved recipe from existing logged meal items without manually writing recipe SQL. It auto-resolves the recipe by name when no valid recipe id is supplied, ignores blank optional ids with explicit notes, writes food_library_items(kind='recipe') and recipe_components, optionally links source log items, and returns deterministic status fields including recipeId, created_new, updated_existing, archived_conflict, active_item_id, duplicate_recipe_ids, and notes.",
        inputSchema: [
            "type": "object",
            "properties": [
                "purpose": ["type": "string", "description": "Short present-tense user-facing purpose."],
                "recipeName": ["type": "string", "description": "Name of the saved recipe."],
                "logDate": ["type": "string", "description": "yyyy-MM-dd date to read, default today."],
                "mealType": ["type": "string", "description": "Optional meal category such as breakfast, lunch, dinner, snack, drink, pre_workout, post_workout, or other."],
                "entryId": ["type": "string", "description": "Optional food_log_entries id to use instead of date/meal."],
                "logItemIds": ["type": "array", "items": ["type": "string"], "description": "Optional explicit food_log_items ids to use."],
                "recipeId": ["type": "string", "description": "Optional existing recipe id to update."],
                "replaceExistingRecipeId": ["type": "string", "description": "Alias for recipeId."],
                "linkLogItems": ["type": "boolean", "description": "Default true. Link source log items to the saved recipe."],
                "dryRun": ["type": "boolean", "description": "Validate and return confirmations without committing changes."],
                "preview": ["type": "boolean", "description": "Alias for dryRun. When true, returns exactly what would change before writing."]
            ],
            "required": ["recipeName"]
        ]
    )

    static let finalizeRecipeSave = PiToolDefinition(
        name: "finalize_recipe_save",
        description: "Repair and verify a recipe save after a bad or partial run. It auto-resolves a canonical non-blank recipeId from recipeName when no valid id is supplied, moves blank-id recipe_components to it, relinks blank library_item_id food_log_items when log filters are provided, archives the blank recipe row, and returns deterministic status fields including recipeId, created_new, updated_existing, archived_conflict, active_item_id, duplicate_recipe_ids, and notes.",
        inputSchema: [
            "type": "object",
            "properties": [
                "purpose": ["type": "string", "description": "Short present-tense user-facing purpose."],
                "recipeName": ["type": "string", "description": "Name of the saved recipe."],
                "recipeId": ["type": "string", "description": "Optional known valid recipe id."],
                "canonicalRecipeId": ["type": "string", "description": "Optional known valid recipe id."],
                "replaceExistingRecipeId": ["type": "string", "description": "Alias for recipeId."],
                "logDate": ["type": "string", "description": "Optional yyyy-MM-dd date used to limit blank log-item relinking."],
                "mealType": ["type": "string", "description": "Optional meal category used to limit blank log-item relinking."],
                "logItemIds": ["type": "array", "items": ["type": "string"], "description": "Optional exact food_log_items ids to relink if their library_item_id is blank."],
                "dryRun": ["type": "boolean", "description": "Validate and return confirmations without committing changes."],
                "preview": ["type": "boolean", "description": "Alias for dryRun. When true, returns exactly what would change before writing."]
            ],
            "required": ["recipeName"]
        ]
    )
}

final class PiAgentRuntimeBackend: AgentRuntimeBackend, @unchecked Sendable {
    static let shared = PiAgentRuntimeBackend()

    let store: AppStore
    let client: AppClient
    let serverBridge: ServerBridge

    private let core: PiLocalRuntimeCore

    private init() {
        let core = PiLocalRuntimeCore()
        self.core = core
        self.store = PiAppStore(core: core)
        self.client = PiAppClient(core: core)
        self.serverBridge = PiServerBridge(core: core)
    }

    func startAsync() {
        Task.detached(priority: .userInitiated) { [core] in
            do {
                try await core.start()
                LLog.info("lifecycle", "pi runtime initialized")
            } catch {
                LLog.error("lifecycle", "pi runtime failed to initialize", error: error)
            }
        }
    }

    func waitUntilReady() async {
        do {
            try await core.start()
        } catch {
            LLog.error("lifecycle", "pi runtime failed to initialize", error: error)
        }
    }

    func defaultCwd() async -> String {
        core.defaultWorkingDirectoryPath
    }

    func prewarm() {
        startAsync()
        _ = store
        _ = client
        _ = serverBridge
    }

    func rerankFoodSearch(query: String, candidates: [ComposerFoodSearchResult]) async throws -> [ComposerFoodSearchResult] {
        try await core.rerankFoodSearch(query: query, candidates: candidates)
    }

    func dashboardFoodInsights(payloadJSON: String) async throws -> String {
        try await core.dashboardFoodInsights(payloadJSON: payloadJSON)
    }

    func scanNutritionLabel(imageData: Data) async throws -> NutritionLabelScanResult {
        try await core.scanNutritionLabel(imageData: imageData)
    }
}

private enum PiAppRuntimeError: Error, LocalizedError {
    case threadNotFound(ThreadKey)
    case unsupported(String)
    case noProvider
    case subscriptionClosed

    var errorDescription: String? {
        switch self {
        case .threadNotFound(let key):
            return "Pi thread was not found: \(key.serverId)/\(key.threadId)"
        case .unsupported(let feature):
            return "\(feature) is not supported by the Pi runtime adapter yet."
        case .noProvider:
            return "Pi is not signed in to a model provider."
        case .subscriptionClosed:
            return "Pi runtime update subscription closed."
        }
    }
}

private struct FoodSearchRerankPayload: Encodable {
    var query: String
    var webSearchRequired: Bool
    var localBestConfidence: Double?
    var candidates: [FoodSearchRerankCandidate]
}

private struct FoodSearchRerankCandidate: Encodable {
    var id: String
    var title: String
    var detail: String
    var insertText: String
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var servingQuantity: Double?
    var servingUnit: String?
    var servingWeight: Double?
    var source: String?
    var sourceURL: String?
    var notes: String?
    var confidence: Double?
}

private struct FoodSearchRerankResponse: Decodable {
    var ids: [String]
    var suggestions: [FoodSearchAISuggestion]?
}

private struct FoodSearchAISuggestion: Decodable {
    var title: String
    var detail: String
    var insertText: String
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var servingQuantity: Double?
    var servingUnit: String?
    var servingWeight: Double?
    var source: String?
    var sourceURL: String?
    var notes: String?
    var confidence: Double?
}

struct NutritionLabelScanResult: Codable, Equatable {
    var name: String?
    var brand: String?
    var servingQuantity: Double?
    var servingUnit: String?
    var servingWeight: Double?
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?
    var sugars: Double?
    var sodium: Double?
    var potassium: Double?
    var notes: String?
    var sourceTitle: String?
}

private final class PiAppStore: AppStore, @unchecked Sendable {
    private let core: PiLocalRuntimeCore

    init(core: PiLocalRuntimeCore) {
        self.core = core
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("PiAppStore cannot be constructed from an external handle")
    }

    override func snapshot() async throws -> AppSnapshotRecord {
        try await core.snapshot()
    }

    override func threadSnapshot(key: ThreadKey) async throws -> AppThreadSnapshot? {
        try await core.threadSnapshot(key: key)
    }

    override func subscribeUpdates() -> AppStoreSubscription {
        core.subscribeUpdates()
    }

    override func setActiveThread(key: ThreadKey?) {
        core.setActiveThread(key)
    }

    override func startTurn(key: ThreadKey, params: AppStartTurnRequest) async throws {
        try await core.startTurn(key: key, params: params)
    }

    override func externalResumeThread(key: ThreadKey, hostId: String?) async throws {
        _ = try await core.readThread(threadId: key.threadId, includeTurns: true)
    }

    override func renameServer(serverId: String, displayName: String) {
        core.renameServer(serverId: serverId, displayName: displayName)
    }

    override func setThreadCollaborationMode(key: ThreadKey, mode: AppModeKind) async throws {
        try await core.setThreadCollaborationMode(key: key, mode: mode)
    }

    override func deleteQueuedFollowUp(key: ThreadKey, previewId: String) async throws {}
    override func dismissPlanImplementationPrompt(key: ThreadKey) {}
    override func editMessage(key: ThreadKey, selectedTurnIndex: UInt32) async throws -> String { "" }
    override func forkThreadFromMessage(key: ThreadKey, selectedTurnIndex: UInt32, params: AppForkThreadFromMessageRequest) async throws -> ThreadKey {
        throw PiAppRuntimeError.unsupported("Fork from message")
    }
    override func implementPlan(key: ThreadKey) async throws {}
    override func isRecording() -> Bool { false }
    override func respondToApproval(requestId: String, decision: ApprovalDecisionValue) async throws {
        throw PiAppRuntimeError.unsupported("Approvals")
    }
    override func respondToUserInput(requestId: String, answers: [PendingUserInputAnswer]) async throws {
        throw PiAppRuntimeError.unsupported("User input prompts")
    }
    override func setVoiceHandoffThread(key: ThreadKey?) {}
    override func startRecording() {}
    override func startReplay(data: String, targetKey: ThreadKey) async throws {
        throw PiAppRuntimeError.unsupported("Replay")
    }
    override func steerQueuedFollowUp(key: ThreadKey, previewId: String) async throws {}
    override func stopRecording() -> String { "{}" }
}

private final class PiAppClient: AppClient, @unchecked Sendable {
    private let core: PiLocalRuntimeCore

    init(core: PiLocalRuntimeCore) {
        self.core = core
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("PiAppClient cannot be constructed from an external handle")
    }

    override func startThread(serverId: String, params: AppStartThreadRequest) async throws -> ThreadKey {
        try await core.startThread(serverId: serverId, params: params)
    }

    override func resumeThread(serverId: String, params: AppResumeThreadRequest) async throws -> ThreadKey {
        try await core.resumeThread(serverId: serverId, params: params)
    }

    override func readThread(serverId: String, params: AppReadThreadRequest) async throws -> ThreadKey {
        try await core.readThread(threadId: params.threadId, includeTurns: params.includeTurns)
    }

    override func listThreads(serverId: String, params: AppListThreadsRequest) async throws {
        try await core.listThreads(params: params)
    }

    override func archiveThread(serverId: String, params: AppArchiveThreadRequest) async throws {
        try await core.archiveThread(threadId: params.threadId)
    }

    override func renameThread(serverId: String, params: AppRenameThreadRequest) async throws {
        try await core.renameThread(threadId: params.threadId, name: params.name)
    }

    override func refreshModels(serverId: String, params: AppRefreshModelsRequest) async throws {
        try await core.refreshModels(includeHidden: params.includeHidden ?? false)
    }

    override func refreshRateLimits(serverId: String) async throws {
        try await core.refreshRateLimits()
    }

    override func loginAccount(serverId: String, params: AppLoginAccountRequest) async throws {
        try await core.loginAccount(params)
    }

    override func logoutAccount(serverId: String) async throws {
        try await core.logoutAccount()
    }

    override func refreshAccount(serverId: String, params: AppRefreshAccountRequest) async throws {
        try await core.refreshAccount()
    }

    override func authStatus(serverId: String, params: AuthStatusRequest) async throws -> AuthStatus {
        try await core.authStatus(includeToken: params.includeToken ?? false)
    }

    override func resolveRemoteHome(serverId: String) async throws -> String {
        core.defaultWorkingDirectoryPath
    }

    override func listRemoteDirectory(serverId: String, path: String) async throws -> DirectoryListResult {
        try core.listLocalDirectory(path: path)
    }

    override func createRemoteDirectory(serverId: String, path: String) async throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func searchFiles(serverId: String, params: AppSearchFilesRequest) async throws -> [FileSearchResult] {
        []
    }

    override func listCollaborationModes(serverId: String) async throws -> [AppCollaborationModePreset] {
        [
            AppCollaborationModePreset(kind: .default, name: "Default", model: nil, reasoningEffort: nil),
            AppCollaborationModePreset(kind: .plan, name: "Plan", model: nil, reasoningEffort: nil)
        ]
    }

    override func listSkills(serverId: String, params: AppListSkillsRequest) async throws -> [SkillMetadata] {
        []
    }

    override func writeConfigValue(serverId: String, params: AppWriteConfigValueRequest) async throws {}

    override func interruptTurn(serverId: String, params: AppInterruptTurnRequest) async throws {
        core.interruptTurn(threadId: params.threadId)
    }

    override func forkThread(serverId: String, params: AppForkThreadRequest) async throws -> ThreadKey {
        throw PiAppRuntimeError.unsupported("Thread forking")
    }

    override func startReview(serverId: String, params: AppStartReviewRequest) async throws {
        throw PiAppRuntimeError.unsupported("Code review")
    }

    override func resolveImageView(serverId: String, path: String) async throws -> ResolvedImageViewResult {
        throw PiAppRuntimeError.unsupported("Image view resolution")
    }

    override func startRealtimeSession(serverId: String, params: AppStartRealtimeSessionRequest) async throws {
        throw PiAppRuntimeError.unsupported("Realtime sessions")
    }

    override func stopRealtimeSession(serverId: String, params: AppStopRealtimeSessionRequest) async throws {}
    override func appendRealtimeAudio(serverId: String, params: AppAppendRealtimeAudioRequest) async throws {}
    override func appendRealtimeText(serverId: String, params: AppAppendRealtimeTextRequest) async throws {}
    override func resolveRealtimeHandoff(serverId: String, params: AppResolveRealtimeHandoffRequest) async throws {}
    override func finalizeRealtimeHandoff(serverId: String, params: AppFinalizeRealtimeHandoffRequest) async throws {}

    override func execCommand(serverId: String, params: AppExecCommandRequest) async throws -> CommandExecResult {
        throw PiAppRuntimeError.unsupported("Shell commands")
    }

    override func startRemoteSshOauthLogin(serverId: String) async throws -> String {
        throw PiAppRuntimeError.unsupported("SSH OAuth")
    }
}

private final class PiServerBridge: ServerBridge, @unchecked Sendable {
    private let core: PiLocalRuntimeCore

    init(core: PiLocalRuntimeCore) {
        self.core = core
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("PiServerBridge cannot be constructed from an external handle")
    }

    override func connectLocalServer(
        serverId: String,
        displayName: String,
        host: String,
        port: UInt16
    ) async throws -> String {
        try await core.connectLocalServer(
            serverId: serverId,
            displayName: displayName,
            host: host,
            port: port
        )
    }

    override func disconnectServer(serverId: String) {
        core.disconnectServer(serverId: serverId)
    }

    override func connectRemoteServer(serverId: String, displayName: String, host: String, port: UInt16) async throws -> String {
        throw PiAppRuntimeError.unsupported("Remote servers")
    }

    override func connectRemoteUrlServer(serverId: String, displayName: String, websocketUrl: String) async throws -> String {
        throw PiAppRuntimeError.unsupported("Remote URL servers")
    }
}

private final class PiAppStoreSubscription: AppStoreSubscription, @unchecked Sendable {
    private var iterator: AsyncStream<AppStoreUpdateRecord>.AsyncIterator

    init(stream: AsyncStream<AppStoreUpdateRecord>) {
        self.iterator = stream.makeAsyncIterator()
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("PiAppStoreSubscription cannot be constructed from an external handle")
    }

    override func nextUpdate() async throws -> AppStoreUpdateRecord {
        guard let update = await iterator.next() else {
            throw PiAppRuntimeError.subscriptionClosed
        }
        return update
    }
}

private final class PiLocalRuntimeCore: @unchecked Sendable {
    private struct PendingSteer {
        var turnID: String
        var params: AppStartTurnRequest
    }

    private struct PreparedTurn {
        var turnID: String
        var shouldRunImmediately: Bool
    }

    private struct ThreadRecord {
        var key: ThreadKey
        var info: ThreadInfo
        var collaborationMode: AppModeKind
        var model: String
        var reasoningEffort: String?
        var approvalPolicy: AppAskForApproval?
        var sandboxPolicy: AppSandboxPolicy?
        var developerInstructions: String?
        var dynamicTools: [AppDynamicToolSpec]
        var items: [HydratedConversationItem]
        var activeTurnID: String?
        var activeAssistantItemID: String?
        var receivedProviderDelta: Bool
        var pendingSteers: [PendingSteer]
        var stats: AppConversationStats?
        var tokenUsage: AppTokenUsage?
        var archived: Bool
        var lastTurnStartMs: Int64?
        var lastTurnEndMs: Int64?
    }

    private let queue = DispatchQueue(label: "com.macrodex.pi-runtime", qos: .userInitiated)
    private let lock = NSRecursiveLock()
    private let stateFileURL: URL
    private let databaseURL: URL
    let defaultWorkingDirectoryPath: String

    private var runtime: PiJSCRuntime?
    private var toolDefinitions: [PiToolDefinition] = [
        PiBuiltInToolDefinitions.title,
        PiBuiltInToolDefinitions.sql,
        PiBuiltInToolDefinitions.jsc,
        PiBuiltInToolDefinitions.webSearch,
        PiMacrodexToolDefinitions.healthKit,
        PiMacrodexToolDefinitions.foodSearch,
        PiMacrodexToolDefinitions.logFood,
        PiMacrodexToolDefinitions.databaseSchema,
        PiMacrodexToolDefinitions.databaseTransaction,
        PiMacrodexToolDefinitions.saveRecipeFromMeal,
        PiMacrodexToolDefinitions.finalizeRecipeSave
    ]
    private var serverId = "local"
    private var serverDisplayName = "This Device"
    private var serverHost = "127.0.0.1"
    private var serverPort: UInt16 = 0
    private var isConnected = false
    private var account: Account?
    private var authMode: AuthMode?
    private var authToken: String?
    private var agentDirectoryVersion: UInt64 = 1
    private var activeThread: ThreadKey?
    private var threads: [String: ThreadRecord] = [:]
    private var cancelledTurnIDs: Set<String> = []
    private var subscriptions: [UUID: AsyncStream<AppStoreUpdateRecord>.Continuation] = [:]
    private var visibleModels: [ModelInfo] = PiBuiltInModelCatalogs.chatGPTCodex.visibleModels
        .map(PiLocalRuntimeCore.modelInfo)

    init() {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let workingDirectory = documents
            .appendingPathComponent("home", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? documents.appendingPathComponent("Application Support", isDirectory: true)
        let piDirectory = appSupport.appendingPathComponent("PiJSC", isDirectory: true)

        self.defaultWorkingDirectoryPath = workingDirectory.path
        self.databaseURL = workingDirectory.appendingPathComponent("db.sqlite")
        self.stateFileURL = piDirectory.appendingPathComponent("runtime-state.json")

        try? fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: piDirectory, withIntermediateDirectories: true)
    }

    func start() async throws {
        try await perform {
            try self.ensureRuntimeSync()
        }
    }

    func snapshot() async throws -> AppSnapshotRecord {
        try await perform {
            self.snapshotSync()
        }
    }

    func threadSnapshot(key: ThreadKey) async throws -> AppThreadSnapshot? {
        try await perform {
            if self.threads[key.threadId] == nil || self.threads[key.threadId]?.items.isEmpty == true {
                try self.importRuntimeThreadSync(threadId: key.threadId, includeMessages: true)
            }
            guard let record = self.threads[key.threadId], !record.archived else { return nil }
            return self.threadSnapshot(record)
        }
    }

    func subscribeUpdates() -> AppStoreSubscription {
        let id = UUID()
        var continuation: AsyncStream<AppStoreUpdateRecord>.Continuation?
        let stream = AsyncStream<AppStoreUpdateRecord> { streamContinuation in
            continuation = streamContinuation
            streamContinuation.onTermination = { [weak self] _ in
                self?.removeSubscription(id)
            }
        }

        lock.lock()
        if let continuation {
            subscriptions[id] = continuation
        }
        lock.unlock()

        return PiAppStoreSubscription(stream: stream)
    }

    func setActiveThread(_ key: ThreadKey?) {
        lock.lock()
        activeThread = key
        lock.unlock()
        emit(.activeThreadChanged(key: key))
    }

    func startThread(serverId: String, params: AppStartThreadRequest) async throws -> ThreadKey {
        try await perform {
            try self.ensureRuntimeSync()
            return try self.startThreadSync(serverId: serverId, params: params)
        }
    }

    func resumeThread(serverId: String, params: AppResumeThreadRequest) async throws -> ThreadKey {
        try await perform {
            try self.ensureRuntimeSync()
            if self.threads[params.threadId] == nil {
                try self.importRuntimeThreadSync(threadId: params.threadId, includeMessages: true)
            }
            let key = ThreadKey(serverId: serverId, threadId: params.threadId)
            guard var record = self.threads[params.threadId] else {
                throw PiAppRuntimeError.threadNotFound(key)
            }
            if let model = params.model {
                record.model = model
                record.info.model = model
                record.info.modelProvider = Self.providerID(for: model)
            }
            if let cwd = params.cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.info.cwd = cwd
            }
            if let developerInstructions = params.developerInstructions {
                record.developerInstructions = developerInstructions
            }
            record.approvalPolicy = params.approvalPolicy
            record.info.status = record.activeTurnID == nil ? .idle : .active
            self.threads[params.threadId] = record
            self.emitThreadMetadata(record)
            return key
        }
    }

    func readThread(threadId: String, includeTurns: Bool) async throws -> ThreadKey {
        try await perform {
            try self.ensureRuntimeSync()
            try self.importRuntimeThreadSync(threadId: threadId, includeMessages: includeTurns)
            let key = ThreadKey(serverId: self.serverId, threadId: threadId)
            guard let record = self.threads[threadId] else {
                throw PiAppRuntimeError.threadNotFound(key)
            }
            self.emitThreadUpsert(record)
            return key
        }
    }

    func listThreads(params: AppListThreadsRequest) async throws {
        try await perform {
            try self.ensureRuntimeSync()
            try self.importRuntimeThreadsSync()
            self.emit(.fullResync)
        }
    }

    func archiveThread(threadId: String) async throws {
        try await perform {
            guard var record = self.threads[threadId] else { return }
            record.archived = true
            record.info.status = .notLoaded
            self.threads[threadId] = record
            if self.activeThread?.threadId == threadId {
                self.activeThread = nil
                self.emit(.activeThreadChanged(key: nil))
            }
            self.emit(.threadRemoved(key: record.key, agentDirectoryVersion: self.agentDirectoryVersion))
        }
    }

    func renameThread(threadId: String, name: String) async throws {
        try await perform {
            guard var record = self.threads[threadId] else {
                throw PiAppRuntimeError.threadNotFound(ThreadKey(serverId: self.serverId, threadId: threadId))
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.info.title = trimmed.isEmpty ? nil : trimmed
            record.info.updatedAt = Self.nowSeconds()
            self.threads[threadId] = record
            self.emitThreadMetadata(record)
        }
    }

    func refreshModels(includeHidden: Bool) async throws {
        try await perform {
            try self.ensureRuntimeSync()
            self.visibleModels = self.availableModelInfos(includeHidden: includeHidden)
            self.emit(.serverChanged(serverId: self.serverId))
        }
    }

    func refreshRateLimits() async throws {
        emit(.serverChanged(serverId: serverId))
    }

    func rerankFoodSearch(query: String, candidates: [ComposerFoodSearchResult]) async throws -> [ComposerFoodSearchResult] {
        try await perform {
            try self.ensureRuntimeSync()
            return try self.rerankFoodSearchSync(query: query, candidates: candidates)
        }
    }

    func dashboardFoodInsights(payloadJSON: String) async throws -> String {
        try await perform {
            try self.ensureRuntimeSync()
            return try self.dashboardFoodInsightsSync(payloadJSON: payloadJSON)
        }
    }

    func scanNutritionLabel(imageData: Data) async throws -> NutritionLabelScanResult {
        try await perform {
            try self.ensureRuntimeSync()
            return try self.scanNutritionLabelSync(imageData: imageData)
        }
    }

    func loginAccount(_ params: AppLoginAccountRequest) async throws {
        try await perform {
            try self.ensureRuntimeSync()
            switch params {
            case .chatgptAuthTokens(let accessToken, let chatgptAccountId, let chatgptPlanType):
                let provider = PiCodexChatGPTProvider(
                    auth: PiCodexAuth(
                        accessToken: accessToken,
                        accountID: chatgptAccountId
                    )
                )
                self.runtime?.registerProvider(provider, for: PiBuiltInProviderRegistry.openAI.id)
                self.authToken = accessToken
                self.authMode = .chatgptAuthTokens
                self.account = .chatgpt(
                    email: chatgptAccountId,
                    planType: Self.planType(from: chatgptPlanType)
                )
                self.emit(.serverChanged(serverId: self.serverId))
            case .chatgpt:
                throw PiAppRuntimeError.unsupported("Interactive ChatGPT login")
            case .apiKey:
                throw PiAppRuntimeError.unsupported("OpenAI API key provider")
            }
        }
    }

    func logoutAccount() async throws {
        try await perform {
            self.account = nil
            self.authMode = nil
            self.authToken = nil
            self.emit(.serverChanged(serverId: self.serverId))
        }
    }

    func refreshAccount() async throws {
        try await perform {
            try self.ensureRuntimeSync()
            try? self.tryInstallCodexAuthFileProviderSync()
            self.tryInstallGoogleAIProviderSync()
            self.visibleModels = self.availableModelInfos(includeHidden: false)
            self.emit(.serverChanged(serverId: self.serverId))
        }
    }

    func authStatus(includeToken: Bool) async throws -> AuthStatus {
        try await perform {
            AuthStatus(
                authMethod: self.authMode,
                authToken: includeToken ? self.authToken : nil,
                requiresOpenaiAuth: self.account == nil
            )
        }
    }

    func connectLocalServer(
        serverId: String,
        displayName: String,
        host: String,
        port: UInt16
    ) async throws -> String {
        try await perform {
            try self.ensureRuntimeSync()
            self.serverId = serverId
            self.serverDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "This Device"
                : displayName
            self.serverHost = host
            self.serverPort = port
            self.isConnected = true
            self.emit(.serverChanged(serverId: serverId))
            return serverId
        }
    }

    func disconnectServer(serverId: String) {
        queue.async {
            self.lock.lock()
            self.isConnected = false
            self.lock.unlock()
            self.emit(.serverChanged(serverId: serverId))
        }
    }

    func renameServer(serverId: String, displayName: String) {
        queue.async {
            self.lock.lock()
            self.serverDisplayName = displayName
            self.lock.unlock()
            self.emit(.serverChanged(serverId: serverId))
        }
    }

    func setThreadCollaborationMode(key: ThreadKey, mode: AppModeKind) async throws {
        try await perform {
            guard var record = self.threads[key.threadId] else {
                throw PiAppRuntimeError.threadNotFound(key)
            }
            record.collaborationMode = mode
            record.info.updatedAt = Self.nowSeconds()
            self.threads[key.threadId] = record
            self.emitThreadMetadata(record)
        }
    }

    func interruptTurn(threadId: String) {
        lock.lock()
        guard var record = threads[threadId] else {
            lock.unlock()
            return
        }
        if let activeTurnID = record.activeTurnID {
            cancelledTurnIDs.insert(activeTurnID)
        }
        record.activeTurnID = nil
        record.activeAssistantItemID = nil
        record.info.status = .idle
        record.info.updatedAt = Self.nowSeconds()
        threads[threadId] = record
        lock.unlock()

        emitThreadMetadata(record)
    }

    func startTurn(key: ThreadKey, params: AppStartTurnRequest) async throws {
        if try preparePendingSteerIfActive(key: key, params: params) {
            return
        }

        let preparedTurn = try await perform {
            try self.ensureRuntimeSync()
            return try self.prepareTurnSync(key: key, params: params)
        }

        guard preparedTurn.shouldRunImmediately else { return }

        queue.async {
            self.runTurnSync(key: key, params: params, turnID: preparedTurn.turnID)
        }
    }

    private func preparePendingSteerIfActive(key: ThreadKey, params: AppStartTurnRequest) throws -> Bool {
        let turnID = UUID().uuidString.lowercased()
        let nowMs = Self.nowMilliseconds()
        let userText = Self.promptText(from: params.input)
        let imageDataUris = Self.imageDataUris(from: params.input)
        let userItem = HydratedConversationItem(
            id: "\(turnID)-user",
            content: .user(HydratedUserMessageData(text: userText, imageDataUris: imageDataUris)),
            sourceTurnId: turnID,
            sourceTurnIndex: nil,
            timestamp: Double(nowMs) / 1000.0,
            isFromUserTurnBoundary: true
        )

        lock.lock()
        guard var record = threads[key.threadId],
              record.activeTurnID != nil else {
            lock.unlock()
            return false
        }
        guard account != nil else {
            lock.unlock()
            throw PiAppRuntimeError.noProvider
        }

        record.items.append(userItem)
        record.info.preview = record.info.preview ?? Self.preview(userText)
        record.info.status = .active
        record.info.updatedAt = Self.nowSeconds()
        record.pendingSteers.append(PendingSteer(turnID: turnID, params: params))
        record.stats = Self.stats(for: record)
        threads[key.threadId] = record
        lock.unlock()

        emit(.threadItemChanged(key: key, item: userItem, sessionSummary: sessionSummary(record)))
        emitThreadMetadata(record)
        return true
    }

    func listLocalDirectory(path: String) throws -> DirectoryListResult {
        let resolved = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultWorkingDirectoryPath
            : path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return DirectoryListResult(directories: [], path: resolved)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: resolved)
            .filter { name in
                var childIsDirectory: ObjCBool = false
                let child = URL(fileURLWithPath: resolved, isDirectory: true).appendingPathComponent(name).path
                return FileManager.default.fileExists(atPath: child, isDirectory: &childIsDirectory)
                    && childIsDirectory.boolValue
                    && !name.hasPrefix(".")
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return DirectoryListResult(directories: names, path: resolved)
    }

    private func perform<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func ensureRuntimeSync() throws {
        if runtime != nil { return }

        let runtime = try PiJSCRuntime(loadingStateFrom: stateFileURL)
        let registry = PiToolRegistry.defaultLocalTools(
            databaseURL: databaseURL,
            requiredSQLCommentMarker: "macrodex:"
        )
        registry.register(PiBuiltInToolDefinitions.title, runner: PiNoopTitleToolRunner())
        registry.register(
            PiMacrodexToolDefinitions.healthKit,
            runner: PiHealthKitToolRunner(workingDirectoryPath: defaultWorkingDirectoryPath)
        )
        registry.register(
            PiMacrodexToolDefinitions.foodSearch,
            runner: PiFoodSearchToolRunner(databaseURL: databaseURL)
        )
        registry.register(
            PiMacrodexToolDefinitions.logFood,
            runner: PiLogFoodToolRunner(databaseURL: databaseURL)
        )
        registry.register(
            PiMacrodexToolDefinitions.databaseSchema,
            runner: PiDatabaseSchemaToolRunner(databaseURL: databaseURL)
        )
        registry.register(
            PiMacrodexToolDefinitions.databaseTransaction,
            runner: PiDatabaseTransactionToolRunner(databaseURL: databaseURL)
        )
        registry.register(
            PiMacrodexToolDefinitions.saveRecipeFromMeal,
            runner: PiSaveRecipeFromMealToolRunner(databaseURL: databaseURL)
        )
        registry.register(
            PiMacrodexToolDefinitions.finalizeRecipeSave,
            runner: PiFinalizeRecipeSaveToolRunner(databaseURL: databaseURL)
        )
        registry.install(on: runtime)
        self.toolDefinitions = registry.definitions
        self.runtime = runtime

        try? tryInstallCodexAuthFileProviderSync()
        tryInstallGoogleAIProviderSync()
        self.visibleModels = availableModelInfos(includeHidden: false)
    }

    private func tryInstallCodexAuthFileProviderSync() throws {
        let authFileURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/auth.json")
        guard FileManager.default.fileExists(atPath: authFileURL.path) else { return }
        let auth = try PiCodexAuth.loadFromCodexAuthFile(authFileURL)
        let provider = PiCodexChatGPTProvider(auth: auth)
        runtime?.registerProvider(provider, for: PiBuiltInProviderRegistry.openAI.id)
        if account == nil {
            authToken = auth.accessToken
            authMode = .chatgptAuthTokens
            account = .chatgpt(email: auth.accountID, planType: .unknown)
        }
    }

    private func tryInstallGoogleAIProviderSync() {
        guard let envKey = PiBuiltInProviderRegistry.google.authEnvironmentVariable,
              let apiKey = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            return
        }
        runtime?.registerProvider(PiGoogleAIProvider(apiKey: apiKey), for: PiBuiltInProviderRegistry.google.id)
        if account == nil {
            authToken = nil
            authMode = .apiKey
            account = .apiKey
        }
    }

    private func availableModelInfos(includeHidden: Bool) -> [ModelInfo] {
        let openAIModels = runtime?.availableModels(
            providerID: PiBuiltInProviderRegistry.openAI.id,
            includeHidden: includeHidden
        ) ?? PiBuiltInModelCatalogs.chatGPTCodex.visibleModels
        var models = openAIModels
        if isGoogleAIConfigured {
            models += runtime?.availableModels(
                providerID: PiBuiltInProviderRegistry.google.id,
                includeHidden: includeHidden
            ) ?? PiBuiltInModelCatalogs.googleAI.visibleModels
        }
        return models.map(Self.modelInfo)
    }

    private func preferredDefaultModelID() -> String {
        runtime?.preferredModelID(providerID: PiBuiltInProviderRegistry.openAI.id) ?? "gpt-5.4-mini"
    }

    private var isGoogleAIConfigured: Bool {
        guard let envKey = PiBuiltInProviderRegistry.google.authEnvironmentVariable else {
            return false
        }
        return !(ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static func providerID(for model: String) -> String {
        if model.hasPrefix("google/") {
            return PiBuiltInProviderRegistry.google.id
        }
        return PiBuiltInProviderRegistry.openAI.id
    }

    private func providerConfiguration(for model: String) -> PiProviderConfiguration {
        let providerID = Self.providerID(for: model)
        return PiProviderConfiguration(id: providerID, model: model)
    }

    private static func applyFoodSearchRerankResponse(
        _ content: String,
        to candidates: [ComposerFoodSearchResult]
    ) -> [ComposerFoodSearchResult]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString: String
        if trimmed.hasPrefix("{") {
            jsonString = trimmed
        } else if let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"),
                  start < end {
            jsonString = String(trimmed[start...end])
        } else {
            return nil
        }

        guard let data = jsonString.data(using: .utf8),
              let response = try? JSONDecoder().decode(FoodSearchRerankResponse.self, from: data)
        else {
            return nil
        }

        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var seen = Set<String>()
        var ranked: [ComposerFoodSearchResult] = []

        for id in response.ids {
            guard let candidate = candidatesByID[id], seen.insert(id).inserted else { continue }
            ranked.append(candidate)
            if ranked.count >= 8 { return ranked }
        }

        for suggestion in response.suggestions ?? [] {
            let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = "ai-\(title.lowercased())-\(suggestion.insertText.lowercased())"
            guard seen.insert(key).inserted else { continue }
            ranked.append(ComposerFoodSearchResult(
                id: key,
                title: title,
                detail: suggestion.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Suggested match" : suggestion.detail,
                insertText: suggestion.insertText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : suggestion.insertText,
                servingQuantity: suggestion.servingQuantity,
                servingUnit: suggestion.servingUnit,
                servingWeight: suggestion.servingWeight,
                calories: suggestion.calories,
                protein: suggestion.protein,
                carbs: suggestion.carbs,
                fat: suggestion.fat,
                source: suggestion.source ?? "AI food search",
                sourceURL: suggestion.sourceURL,
                notes: suggestion.notes,
                confidence: suggestion.confidence ?? 0.76
            ))
            if ranked.count >= 8 { return ranked }
        }

        for candidate in candidates {
            guard seen.insert(candidate.id).inserted else { continue }
            ranked.append(candidate)
            if ranked.count >= 8 { break }
        }

        return ranked
    }

    private static func foodSearchNeedsWeb(
        query: String,
        candidates: [ComposerFoodSearchResult]
    ) -> Bool {
        let queryTokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard queryTokens.count >= 2 else { return candidates.isEmpty }
        guard let best = candidates.max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) }) else {
            return true
        }

        let bestConfidence = best.confidence ?? 0
        if bestConfidence < 0.85 { return true }

        let titleTokens = best.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let missingTokenCount = queryTokens.filter { queryToken in
            !titleTokens.contains { titleToken in
                titleToken == queryToken
                    || titleToken.hasPrefix(queryToken)
                    || queryToken.hasPrefix(titleToken)
            }
        }.count
        let source = best.source ?? ""
        guard source == "Foundation food" || source == "USDA Foundation" else {
            return missingTokenCount > 0 && queryTokens.count >= 3
        }

        let hasProductSignal = query.contains("'")
            || query.contains("’")
            || query.contains("%")
            || queryTokens.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil }
        return (missingTokenCount > 0 && queryTokens.count >= 3)
            || (queryTokens.count >= 2 && (hasProductSignal || bestConfidence < 0.94))
    }

    private func rerankFoodSearchSync(query: String, candidates: [ComposerFoodSearchResult]) throws -> [ComposerFoodSearchResult] {
        guard let runtime else { return candidates }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidates.count > 1 || trimmedQuery.count >= 2 else { return candidates }

        let availableModels = availableModelInfos(includeHidden: true).map(\.id)
        let preferredModels = [
            "gpt-5.4-mini",
            "gpt-5.4",
            "google/gemini-2.5-flash",
            "google/gemini-2.0-flash"
        ].filter { availableModels.contains($0) }

        let payload = FoodSearchRerankPayload(
            query: query,
            webSearchRequired: Self.foodSearchNeedsWeb(query: trimmedQuery, candidates: candidates),
            localBestConfidence: candidates.map { $0.confidence ?? 0 }.max(),
            candidates: Array(candidates.prefix(12)).map {
                FoodSearchRerankCandidate(
                    id: $0.id,
                    title: $0.title,
                    detail: $0.detail,
                    insertText: $0.insertText,
                    calories: $0.calories,
                    protein: $0.protein,
                    carbs: $0.carbs,
                    fat: $0.fat,
                    servingQuantity: $0.servingQuantity,
                    servingUnit: $0.servingUnit,
                    servingWeight: $0.servingWeight,
                    source: $0.source,
                    sourceURL: $0.sourceURL,
                    notes: $0.notes,
                    confidence: $0.confidence
                )
            }
        )
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
        let instructions = """
        You rank food search suggestions for a calorie tracking app. Prefer exact food, brand, restaurant/menu item, and serving matches. Keep existing candidate IDs only when they genuinely satisfy the user's full query. The payload includes webSearchRequired and localBestConfidence. When webSearchRequired is true, call web_search before answering and include at least one web-backed suggestion if search results contain usable nutrition/menu evidence; do not answer only with generic Foundation/local candidate IDs. For restaurant queries, search the exact restaurant and item plus nutrition/calories/protein. For new suggestions, include convenient serving, typical macros for that serving, notes explaining what source/serving was used, source, sourceURL when available, and confidence from 0.0 to 1.0. Return JSON only with this shape: {"ids":["candidate-id"],"suggestions":[{"title":"Food name","detail":"short serving or macro hint","insertText":"Food name","servingQuantity":1,"servingUnit":"egg","servingWeight":50,"calories":72,"protein":6.3,"carbs":0.4,"fat":4.8,"source":"USDA FoodData Central","sourceURL":"https://...","notes":"Serving based on label or database entry","confidence":0.86}]}.
        """
        let requestMessages = [
            PiMessage(role: .system, content: instructions),
            PiMessage(role: .user, content: payloadJSON)
        ]

        var lastError: Error?
        var metadata: [String: PiJSONValue] = ["reasoning_effort": .string("low")]
        if UserDefaults.standard.bool(forKey: "fastMode") {
            metadata["service_tier"] = .string("fast")
        }
        for model in preferredModels {
            do {
                let response = try runtime.completeProvider(PiProviderRequest(
                    threadID: "food-search-rerank",
                    providerID: Self.providerID(for: model),
                    model: model,
                    messages: requestMessages,
                    tools: [PiBuiltInToolDefinitions.webSearch],
                    metadata: metadata
                ))
                guard let content = response.message?.content,
                      let ranked = Self.applyFoodSearchRerankResponse(content, to: candidates),
                      !ranked.isEmpty
                else {
                    continue
                }
                return ranked
            } catch {
                lastError = error
                continue
            }
        }

        if let lastError {
            LLog.warn("food_search", "AI rerank unavailable", fields: ["error": lastError.localizedDescription])
        }
        return candidates
    }

    private func dashboardFoodInsightsSync(payloadJSON: String) throws -> String {
        guard let runtime else { throw PiAppRuntimeError.noProvider }
        let availableModels = availableModelInfos(includeHidden: true).map(\.id)
        let preferredModels = [
            "gpt-5.4-mini",
            "gpt-5.4",
            "google/gemini-2.5-flash",
            "google/gemini-2.0-flash"
        ].filter { availableModels.contains($0) }
        let instructions = """
        You are a compact nutrition dashboard assistant. Given today's log, goals, current week summary, and candidate food suggestions, return JSON only: {"summary":"one short useful sentence","suggestionIDs":["candidate-id"]}. Pick at most three candidate IDs. If calories are complete or over goal, return an empty suggestionIDs array. Prefer foods that fit the remaining calories/macros, avoid foods already logged today, and do not fill every meal category just because candidates exist. Keep the summary factual and concise.
        """
        let messages = [
            PiMessage(role: .system, content: instructions),
            PiMessage(role: .user, content: payloadJSON)
        ]
        var lastError: Error?
        for model in preferredModels {
            do {
                let response = try runtime.completeProvider(PiProviderRequest(
                    threadID: "dashboard-food-insights",
                    providerID: Self.providerID(for: model),
                    model: model,
                    messages: messages,
                    metadata: ["reasoning_effort": .string("low")]
                ))
                if let content = response.message?.content.trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty {
                    return content
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw PiAppRuntimeError.noProvider
    }

    private func scanNutritionLabelSync(imageData: Data) throws -> NutritionLabelScanResult {
        guard let runtime else { throw PiAppRuntimeError.noProvider }
        let availableModels = availableModelInfos(includeHidden: true).map(\.id)
        let preferredModels = [
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.5",
            "google/gemini-2.5-flash",
            "google/gemini-2.0-flash"
        ].filter { availableModels.contains($0) }
        let imageURI = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        let instructions = """
        Read this nutrition label and return JSON only. Extract the food name/brand if visible, serving size, calories, macros, and useful micronutrients. Use grams for protein/carbs/fat/fiber/sugars, milligrams for sodium/potassium, calories in kcal, and servingWeight in grams. Return: {"name":"Food","brand":"Brand","servingQuantity":1,"servingUnit":"bar","servingWeight":52,"calories":210,"protein":12,"carbs":23,"fat":8,"fiber":4,"sugars":6,"sodium":180,"potassium":120,"notes":"brief uncertainty notes","sourceTitle":"Nutrition label scan"}.
        """
        let messages = [
            PiMessage(role: .system, content: instructions),
            PiMessage(role: .user, content: "Scan this nutrition label.", imageURLs: [imageURI])
        ]
        var lastError: Error?
        for model in preferredModels {
            do {
                let response = try runtime.completeProvider(PiProviderRequest(
                    threadID: "nutrition-label-scan",
                    providerID: Self.providerID(for: model),
                    model: model,
                    messages: messages,
                    metadata: ["reasoning_effort": .string("low")]
                ))
                guard let content = response.message?.content,
                      let result = Self.decodeNutritionLabelScan(content)
                else { continue }
                return result
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw PiAppRuntimeError.noProvider
    }

    private static func decodeNutritionLabelScan(_ content: String) -> NutritionLabelScanResult? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString: String
        if trimmed.hasPrefix("{") {
            jsonString = trimmed
        } else if let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"),
                  start < end {
            jsonString = String(trimmed[start...end])
        } else {
            return nil
        }
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NutritionLabelScanResult.self, from: data)
    }

    private func startThreadSync(serverId: String, params: AppStartThreadRequest) throws -> ThreadKey {
        let model = params.model ?? preferredDefaultModelID()
        let provider = providerConfiguration(for: model)
        let threadId = UUID().uuidString.lowercased()
        let key = ThreadKey(serverId: serverId, threadId: threadId)
        let now = Self.nowSeconds()
        let cwd = params.cwd?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? params.cwd!
            : defaultWorkingDirectoryPath
        let info = ThreadInfo(
            id: threadId,
            title: nil,
            model: model,
            status: .idle,
            preview: nil,
            cwd: cwd,
            path: nil,
            modelProvider: provider.id,
            agentNickname: nil,
            agentRole: nil,
            parentThreadId: nil,
            agentStatus: nil,
            createdAt: now,
            updatedAt: now
        )
        let record = ThreadRecord(
            key: key,
            info: info,
            collaborationMode: .default,
            model: model,
            reasoningEffort: nil,
            approvalPolicy: params.approvalPolicy,
            sandboxPolicy: nil,
            developerInstructions: params.developerInstructions,
            dynamicTools: params.dynamicTools ?? [],
            items: [],
            activeTurnID: nil,
            activeAssistantItemID: nil,
            receivedProviderDelta: false,
            pendingSteers: [],
            stats: Self.emptyStats(),
            tokenUsage: nil,
            archived: false,
            lastTurnStartMs: nil,
            lastTurnEndMs: nil
        )

        lock.lock()
        self.serverId = serverId
        threads[threadId] = record
        lock.unlock()

        emitThreadUpsert(record)
        return key
    }

    private func prepareTurnSync(key: ThreadKey, params: AppStartTurnRequest) throws -> PreparedTurn {
        guard var record = threads[key.threadId] else {
            throw PiAppRuntimeError.threadNotFound(key)
        }
        guard account != nil else {
            throw PiAppRuntimeError.noProvider
        }

        let turnID = UUID().uuidString.lowercased()
        let nowMs = Self.nowMilliseconds()
        let userText = Self.promptText(from: params.input)
        let imageDataUris = Self.imageDataUris(from: params.input)
        let userItem = HydratedConversationItem(
            id: "\(turnID)-user",
            content: .user(HydratedUserMessageData(text: userText, imageDataUris: imageDataUris)),
            sourceTurnId: turnID,
            sourceTurnIndex: nil,
            timestamp: Double(nowMs) / 1000.0,
            isFromUserTurnBoundary: true
        )
        record.items.append(userItem)
        record.info.preview = record.info.preview ?? Self.preview(userText)
        record.info.status = .active
        record.info.updatedAt = Self.nowSeconds()
        let isSteerWhileRunning = record.activeTurnID != nil
        if isSteerWhileRunning {
            record.pendingSteers.append(PendingSteer(turnID: turnID, params: params))
            record.stats = Self.stats(for: record)

            lock.lock()
            threads[key.threadId] = record
            lock.unlock()

            emit(.threadItemChanged(key: key, item: userItem, sessionSummary: sessionSummary(record)))
            emitThreadMetadata(record)
            return PreparedTurn(turnID: turnID, shouldRunImmediately: false)
        }
        record.activeTurnID = turnID
        record.activeAssistantItemID = "\(turnID)-assistant"
        record.receivedProviderDelta = false
        record.lastTurnStartMs = nowMs
        if let model = params.model {
            record.model = model
            record.info.model = model
            record.info.modelProvider = Self.providerID(for: model)
        }
        if let effort = params.effort {
            record.reasoningEffort = Self.reasoningEffortName(effort)
        }
        record.stats = Self.stats(for: record)

        lock.lock()
        threads[key.threadId] = record
        lock.unlock()

        emit(.threadItemChanged(key: key, item: userItem, sessionSummary: sessionSummary(record)))
        emitThreadMetadata(record)
        return PreparedTurn(turnID: turnID, shouldRunImmediately: true)
    }

    private func runTurnSync(key: ThreadKey, params: AppStartTurnRequest, turnID: String) {
        do {
            guard let runtime else { throw PiAppRuntimeError.unsupported("Pi runtime") }
            guard let record = lockedThread(threadId: key.threadId) else {
                throw PiAppRuntimeError.threadNotFound(key)
            }
            let model = params.model ?? record.model
            let provider = providerConfiguration(for: model)
            var metadata: [String: PiJSONValue] = [:]
            if let effort = params.effort.map(Self.reasoningEffortName) ?? record.reasoningEffort {
                metadata["reasoning_effort"] = .string(effort)
            }
            let request = PiTurnRequest(
                threadID: key.threadId,
                input: Self.piMessages(from: params.input),
                provider: provider,
                tools: mergedToolDefinitions(dynamicTools: record.dynamicTools),
                instructions: record.developerInstructions,
                maxToolRounds: 8,
                metadata: metadata
            )
            let result = try runtime.runTurn(request) { [weak self] event in
                self?.handleRuntimeEvent(event, key: key, turnID: turnID)
            } shouldCancel: { [weak self] in
                self?.isTurnCancelled(turnID) ?? false
            } pendingInputProvider: { [weak self] in
                self?.consumePendingSteerMessages(key: key) ?? []
            }
            clearCancelledTurn(turnID)
            finalizeTurn(result: result, key: key, turnID: turnID, inputMessages: request.input)
            try runtime.saveState(to: stateFileURL)
        } catch {
            let wasCancelled = isTurnCancelled(turnID)
            clearCancelledTurn(turnID)
            if wasCancelled {
                cancelTurn(key: key, turnID: turnID)
            } else {
                failTurn(error: error, key: key, turnID: turnID)
            }
            try? runtime?.saveState(to: stateFileURL)
        }
    }

    private func isTurnCancelled(_ turnID: String) -> Bool {
        lock.lock()
        let cancelled = cancelledTurnIDs.contains(turnID)
        lock.unlock()
        return cancelled
    }

    private func clearCancelledTurn(_ turnID: String) {
        lock.lock()
        cancelledTurnIDs.remove(turnID)
        lock.unlock()
    }

    private func consumePendingSteerMessages(key: ThreadKey) -> [PiMessage] {
        lock.lock()
        guard var record = threads[key.threadId],
              record.activeTurnID != nil,
              !record.pendingSteers.isEmpty else {
            lock.unlock()
            return []
        }
        let steers = record.pendingSteers
        record.pendingSteers.removeAll(keepingCapacity: true)
        record.stats = Self.stats(for: record)
        threads[key.threadId] = record
        lock.unlock()

        emitThreadMetadata(record)
        return steers.flatMap { Self.piMessages(from: $0.params.input) }
    }

    private func handleRuntimeEvent(_ event: PiRuntimeEvent, key: ThreadKey, turnID: String) {
        switch event.type {
        case "provider.output_text.delta":
            guard let delta = event.payload["delta"]?.stringValue, !delta.isEmpty else { return }
            appendAssistantDelta(delta, key: key, turnID: turnID, markProviderDelta: true)
        case "message.delta":
            guard let delta = event.payload["delta"]?.stringValue, !delta.isEmpty else { return }
            guard lockedThread(threadId: key.threadId)?.receivedProviderDelta != true else { return }
            appendAssistantDelta(delta, key: key, turnID: turnID, markProviderDelta: false)
        case "provider.tool_call.completed":
            let callID = event.payload["call_id"]?.stringValue ?? UUID().uuidString.lowercased()
            let name = event.payload["name"]?.stringValue ?? "tool"
            let arguments = event.payload["arguments"].map(Self.jsonString) ?? nil
            upsertToolCall(
                key: key,
                turnID: turnID,
                callID: callID,
                name: name,
                status: .inProgress,
                argumentsJson: arguments,
                success: nil,
                summary: nil
            )
        case "provider.web_search.completed":
            let callID = event.payload["call_id"]?.stringValue ?? UUID().uuidString.lowercased()
            let query = event.payload["query"]?.stringValue ?? ""
            let actionJSON = event.payload["action_json"]?.stringValue
            upsertHostedWebSearch(
                key: key,
                turnID: turnID,
                callID: callID,
                query: query,
                actionJSON: actionJSON,
                isInProgress: false
            )
        case "tool.started":
            let callID = event.payload["call_id"]?.stringValue ?? UUID().uuidString.lowercased()
            let name = event.payload["name"]?.stringValue ?? "tool"
            let arguments = event.payload["arguments"].map(Self.jsonString) ?? nil
            upsertToolCall(
                key: key,
                turnID: turnID,
                callID: callID,
                name: name,
                status: .inProgress,
                argumentsJson: arguments,
                success: nil,
                summary: nil
            )
        case "tool.completed":
            let callID = event.payload["call_id"]?.stringValue ?? UUID().uuidString.lowercased()
            let name = event.payload["name"]?.stringValue ?? "tool"
            let isError = event.payload["is_error"]?.boolValue ?? false
            upsertToolCall(
                key: key,
                turnID: turnID,
                callID: callID,
                name: name,
                status: .completed,
                argumentsJson: nil,
                success: !isError,
                summary: nil
            )
        default:
            break
        }
    }

    private func appendAssistantDelta(
        _ delta: String,
        key: ThreadKey,
        turnID: String,
        markProviderDelta: Bool
    ) {
        lock.lock()
        guard var record = threads[key.threadId],
              let itemID = record.activeAssistantItemID else {
            lock.unlock()
            return
        }
        if markProviderDelta {
            record.receivedProviderDelta = true
        }
        var item: HydratedConversationItem
        if let index = record.items.firstIndex(where: { $0.id == itemID }) {
            item = record.items[index]
            if case .assistant(var data) = item.content {
                data.text += delta
                item.content = .assistant(data)
            } else {
                item.content = .assistant(HydratedAssistantMessageData(text: delta, agentNickname: nil, agentRole: nil, phase: .finalAnswer))
            }
            record.items[index] = item
        } else {
            item = HydratedConversationItem(
                id: itemID,
                content: .assistant(HydratedAssistantMessageData(text: delta, agentNickname: nil, agentRole: nil, phase: .finalAnswer)),
                sourceTurnId: turnID,
                sourceTurnIndex: nil,
                timestamp: Double(Self.nowMilliseconds()) / 1000.0,
                isFromUserTurnBoundary: false
            )
            record.items.append(item)
        }
        threads[key.threadId] = record
        lock.unlock()

        emit(.threadItemChanged(key: key, item: item, sessionSummary: sessionSummary(record)))
        emit(.threadStreamingDelta(key: key, itemId: itemID, kind: .assistantText, text: delta))
    }

    private func upsertToolCall(
        key: ThreadKey,
        turnID: String,
        callID: String,
        name: String,
        status: AppOperationStatus,
        argumentsJson: String?,
        success: Bool?,
        summary: String?
    ) {
        let itemID = "\(turnID)-tool-\(callID)"
        lock.lock()
        guard var record = threads[key.threadId] else {
            lock.unlock()
            return
        }
        var item: HydratedConversationItem
        let isWebSearch = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == PiBuiltInToolDefinitions.webSearch.name
        if let index = record.items.firstIndex(where: { $0.id == itemID }) {
            item = record.items[index]
            if isWebSearch {
                let previous: HydratedWebSearchData? = {
                    if case .webSearch(let data) = item.content { return data }
                    return nil
                }()
                item.content = .webSearch(
                    HydratedWebSearchData(
                        query: Self.webSearchQuery(fromArgumentsJSON: argumentsJson) ?? previous?.query ?? "",
                        actionJson: argumentsJson ?? previous?.actionJson,
                        isInProgress: status == .pending || status == .inProgress
                    )
                )
            } else if case .dynamicToolCall(var data) = item.content {
                data.status = status
                data.success = success ?? data.success
                data.argumentsJson = argumentsJson ?? data.argumentsJson
                data.contentSummary = summary ?? data.contentSummary
                item.content = .dynamicToolCall(data)
            }
            record.items[index] = item
        } else {
            item = HydratedConversationItem(
                id: itemID,
                content: isWebSearch
                    ? .webSearch(
                        HydratedWebSearchData(
                            query: Self.webSearchQuery(fromArgumentsJSON: argumentsJson) ?? "",
                            actionJson: argumentsJson,
                            isInProgress: status == .pending || status == .inProgress
                        )
                    )
                    : .dynamicToolCall(
                        HydratedDynamicToolCallData(
                            tool: name,
                            status: status,
                            durationMs: nil,
                            success: success,
                            argumentsJson: argumentsJson,
                            contentSummary: summary
                        )
                    ),
                sourceTurnId: turnID,
                sourceTurnIndex: nil,
                timestamp: Double(Self.nowMilliseconds()) / 1000.0,
                isFromUserTurnBoundary: false
            )
            record.items.append(item)
        }
        record.stats = Self.stats(for: record)
        threads[key.threadId] = record
        lock.unlock()

        emit(.threadItemChanged(key: key, item: item, sessionSummary: sessionSummary(record)))
    }

    private func upsertHostedWebSearch(
        key: ThreadKey,
        turnID: String,
        callID: String,
        query: String,
        actionJSON: String?,
        isInProgress: Bool
    ) {
        let itemID = "\(turnID)-web-search-\(callID)"
        lock.lock()
        guard var record = threads[key.threadId] else {
            lock.unlock()
            return
        }
        let item = HydratedConversationItem(
            id: itemID,
            content: .webSearch(
                HydratedWebSearchData(
                    query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                    actionJson: actionJSON,
                    isInProgress: isInProgress
                )
            ),
            sourceTurnId: turnID,
            sourceTurnIndex: nil,
            timestamp: Double(Self.nowMilliseconds()) / 1000.0,
            isFromUserTurnBoundary: false
        )
        if let index = record.items.firstIndex(where: { $0.id == itemID }) {
            record.items[index] = item
        } else {
            record.items.append(item)
        }
        record.stats = Self.stats(for: record)
        threads[key.threadId] = record
        lock.unlock()

        emit(.threadItemChanged(key: key, item: item, sessionSummary: sessionSummary(record)))
    }

    private static func webSearchQuery(fromArgumentsJSON argumentsJSON: String?) -> String? {
        guard let argumentsJSON,
              let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawQuery = (object["query"] as? String) ?? (object["q"] as? String)
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        return query?.isEmpty == false ? query : nil
    }

    private func finalizeTurn(
        result: PiTurnResult,
        key: ThreadKey,
        turnID: String,
        inputMessages: [PiMessage]
    ) {
        var titleCandidate: String?
        let currentTurnMessages = Self.messagesAfterCurrentInput(in: result.messages, inputMessages: inputMessages)
        let toolOutputs = Self.toolOutputsByCallID(currentTurnMessages)

        lock.lock()
        guard var record = threads[key.threadId] else {
            lock.unlock()
            return
        }

        for message in currentTurnMessages {
            guard let calls = message.toolCalls else { continue }
            for call in calls {
                if call.name == PiBuiltInToolDefinitions.title.name,
                   let title = call.arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !title.isEmpty,
                   !ManualThreadTitleStore.isManuallyRenamed(key) {
                    titleCandidate = title
                }
                let summary = toolOutputs[call.id].map(Self.preview)
                let itemID = "\(turnID)-tool-\(call.id)"
                let item = HydratedConversationItem(
                    id: itemID,
                    content: .dynamicToolCall(
                        HydratedDynamicToolCallData(
                            tool: call.name,
                            status: .completed,
                            durationMs: nil,
                            success: !(toolOutputs[call.id]?.localizedCaseInsensitiveContains("\"error\"") ?? false),
                            argumentsJson: Self.jsonString(call.arguments),
                            contentSummary: summary
                        )
                    ),
                    sourceTurnId: turnID,
                    sourceTurnIndex: nil,
                    timestamp: Double(Self.nowMilliseconds()) / 1000.0,
                    isFromUserTurnBoundary: false
                )
                if let index = record.items.firstIndex(where: { $0.id == itemID }) {
                    record.items[index] = item
                } else {
                    record.items.append(item)
                }
            }
        }

        if let final = result.finalMessage, !final.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let itemID = record.activeAssistantItemID ?? "\(turnID)-assistant"
            let item = HydratedConversationItem(
                id: itemID,
                content: .assistant(HydratedAssistantMessageData(text: final.content, agentNickname: nil, agentRole: nil, phase: .finalAnswer)),
                sourceTurnId: turnID,
                sourceTurnIndex: nil,
                timestamp: Double(Self.nowMilliseconds()) / 1000.0,
                isFromUserTurnBoundary: false
            )
            if let index = record.items.firstIndex(where: { $0.id == itemID }) {
                record.items[index] = item
            } else {
                record.items.append(item)
            }
        }

        if let titleCandidate {
            record.info.title = titleCandidate
        }
        record.info.status = .idle
        record.info.updatedAt = Self.nowSeconds()
        record.activeTurnID = nil
        record.activeAssistantItemID = nil
        record.receivedProviderDelta = false
        record.lastTurnEndMs = Self.nowMilliseconds()
        record.tokenUsage = result.usage.map(Self.tokenUsage)
        record.stats = Self.stats(for: record)
        threads[key.threadId] = record
        let items = record.items
        lock.unlock()

        for item in items where item.sourceTurnId == turnID {
            emit(.threadItemChanged(key: key, item: item, sessionSummary: sessionSummary(record)))
        }
        emitThreadMetadata(record)
        scheduleNextPendingSteerIfNeeded(key: key)
    }

    private func failTurn(error: Error, key: ThreadKey, turnID: String) {
        let item = HydratedConversationItem(
            id: "\(turnID)-error",
            content: .error(
                HydratedErrorData(
                    title: "Pi runtime error",
                    message: error.localizedDescription,
                    details: nil
                )
            ),
            sourceTurnId: turnID,
            sourceTurnIndex: nil,
            timestamp: Double(Self.nowMilliseconds()) / 1000.0,
            isFromUserTurnBoundary: false
        )

        lock.lock()
        guard var record = threads[key.threadId] else {
            lock.unlock()
            return
        }
        record.items.append(item)
        record.info.status = .systemError
        record.info.updatedAt = Self.nowSeconds()
        record.activeTurnID = nil
        record.activeAssistantItemID = nil
        record.lastTurnEndMs = Self.nowMilliseconds()
        record.stats = Self.stats(for: record)
        threads[key.threadId] = record
        lock.unlock()

        emit(.threadItemChanged(key: key, item: item, sessionSummary: sessionSummary(record)))
        emitThreadMetadata(record)
        scheduleNextPendingSteerIfNeeded(key: key)
    }

    private func cancelTurn(key: ThreadKey, turnID: String) {
        lock.lock()
        guard var record = threads[key.threadId] else {
            lock.unlock()
            return
        }
        record.info.status = .idle
        record.info.updatedAt = Self.nowSeconds()
        record.activeTurnID = nil
        record.activeAssistantItemID = nil
        record.receivedProviderDelta = false
        record.lastTurnEndMs = Self.nowMilliseconds()
        record.stats = Self.stats(for: record)
        threads[key.threadId] = record
        lock.unlock()

        emitThreadMetadata(record)
        scheduleNextPendingSteerIfNeeded(key: key)
    }

    private func scheduleNextPendingSteerIfNeeded(key: ThreadKey) {
        guard let next = prepareNextPendingSteerSync(key: key) else { return }
        queue.async {
            self.runTurnSync(key: key, params: next.params, turnID: next.turnID)
        }
    }

    private func prepareNextPendingSteerSync(key: ThreadKey) -> PendingSteer? {
        lock.lock()
        guard var record = threads[key.threadId],
              record.activeTurnID == nil,
              !record.pendingSteers.isEmpty else {
            lock.unlock()
            return nil
        }
        let next = record.pendingSteers.removeFirst()
        let nowMs = Self.nowMilliseconds()
        record.info.status = .active
        record.info.updatedAt = Self.nowSeconds()
        record.activeTurnID = next.turnID
        record.activeAssistantItemID = "\(next.turnID)-assistant"
        record.receivedProviderDelta = false
        record.lastTurnStartMs = nowMs
        if let model = next.params.model {
            record.model = model
            record.info.model = model
            record.info.modelProvider = Self.providerID(for: model)
        }
        if let effort = next.params.effort {
            record.reasoningEffort = Self.reasoningEffortName(effort)
        }
        record.stats = Self.stats(for: record)
        threads[key.threadId] = record
        lock.unlock()

        emitThreadMetadata(record)
        return next
    }

    private func importRuntimeThreadsSync() throws {
        guard let runtime else { return }
        for thread in try runtime.listThreads() {
            try importRuntimeThreadSync(threadId: thread.id, includeMessages: true)
        }
    }

    private func importRuntimeThreadSync(threadId: String, includeMessages: Bool) throws {
        guard let runtime,
              let thread = try runtime.threadSnapshot(threadID: threadId, includeMessages: includeMessages) else {
            return
        }
        try importRuntimeThreadSnapshotSync(thread, includeMessages: includeMessages)
    }

    private func importRuntimeThreadSnapshotSync(_ thread: PiThreadSnapshot, includeMessages: Bool) throws {
        let key = ThreadKey(serverId: serverId, threadId: thread.id)
        let messages = includeMessages ? (thread.messages ?? []) : []
        let model = threads[thread.id]?.model ?? preferredDefaultModelID()
        let items = includeMessages ? Self.hydratedItems(from: messages, threadID: thread.id) : (threads[thread.id]?.items ?? [])
        let title = Self.title(from: messages) ?? threads[thread.id]?.info.title
        let preview = Self.preview(from: messages) ?? threads[thread.id]?.info.preview
        let info = ThreadInfo(
            id: thread.id,
            title: title,
            model: model,
            status: .idle,
            preview: preview,
            cwd: threads[thread.id]?.info.cwd ?? defaultWorkingDirectoryPath,
            path: nil,
            modelProvider: Self.providerID(for: model),
            agentNickname: nil,
            agentRole: nil,
            parentThreadId: nil,
            agentStatus: nil,
            createdAt: thread.createdAtMilliseconds.map { $0 / 1000 },
            updatedAt: thread.updatedAtMilliseconds.map { $0 / 1000 }
        )
        var record = threads[thread.id] ?? ThreadRecord(
            key: key,
            info: info,
            collaborationMode: .default,
            model: model,
            reasoningEffort: nil,
            approvalPolicy: nil,
            sandboxPolicy: nil,
            developerInstructions: nil,
            dynamicTools: AgentDynamicToolSpecs.defaultThreadTools(includeGenerativeUI: false) ?? [],
            items: items,
            activeTurnID: nil,
            activeAssistantItemID: nil,
            receivedProviderDelta: false,
            pendingSteers: [],
            stats: nil,
            tokenUsage: nil,
            archived: false,
            lastTurnStartMs: nil,
            lastTurnEndMs: nil
        )
        record.info = info
        if includeMessages {
            record.items = items
        }
        record.stats = Self.stats(for: record)
        threads[thread.id] = record
    }

    private func snapshotSync() -> AppSnapshotRecord {
        lock.lock()
        let records = threads.values
            .filter { !$0.archived }
            .sorted { ($0.info.updatedAt ?? 0) > ($1.info.updatedAt ?? 0) }
        let server = serverSnapshotSync()
        let activeThread = activeThread
        let version = agentDirectoryVersion
        lock.unlock()

        return AppSnapshotRecord(
            servers: [server],
            threads: records.map(threadSnapshot),
            sessionSummaries: records.map(sessionSummary).sorted(by: { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }),
            agentDirectoryVersion: version,
            activeThread: activeThread,
            pendingApprovals: [],
            pendingUserInputs: [],
            voiceSession: AppVoiceSessionSnapshot(
                activeThread: nil,
                sessionId: nil,
                phase: nil,
                lastError: nil,
                transcriptEntries: [],
                handoffThreadKey: nil
            )
        )
    }

    private func serverSnapshotSync() -> AppServerSnapshot {
        AppServerSnapshot(
            serverId: serverId,
            displayName: serverDisplayName,
            host: serverHost,
            port: serverPort,
            wakeMac: nil,
            isLocal: true,
            supportsIpc: false,
            hasIpc: false,
            health: isConnected ? .connected : .disconnected,
            transportState: isConnected ? .connected : .disconnected,
            ipcState: .unsupported,
            capabilities: AppServerCapabilities(
                canUseTransportActions: false,
                canBrowseDirectories: true,
                canStartThreads: true,
                canResumeThreads: true,
                canUseIpc: false,
                canResumeViaIpc: false
            ),
            account: account,
            requiresOpenaiAuth: account == nil,
            rateLimits: nil,
            availableModels: visibleModels,
            connectionProgress: nil,
            usageStats: nil
        )
    }

    private func threadSnapshot(_ record: ThreadRecord) -> AppThreadSnapshot {
        AppThreadSnapshot(
            key: record.key,
            info: record.info,
            collaborationMode: record.collaborationMode,
            model: record.model,
            reasoningEffort: record.reasoningEffort,
            effectiveApprovalPolicy: record.approvalPolicy,
            effectiveSandboxPolicy: record.sandboxPolicy,
            hydratedConversationItems: record.items,
            queuedFollowUps: [],
            activeTurnId: record.activeTurnID,
            activePlanProgress: nil,
            pendingPlanImplementationPrompt: nil,
            contextTokensUsed: record.tokenUsage.map { UInt64(max(0, $0.totalTokens)) },
            modelContextWindow: nil,
            rateLimits: nil,
            realtimeSessionId: nil,
            stats: record.stats,
            tokenUsage: record.tokenUsage
        )
    }

    private func threadState(_ record: ThreadRecord) -> AppThreadStateRecord {
        AppThreadStateRecord(
            key: record.key,
            info: record.info,
            collaborationMode: record.collaborationMode,
            model: record.model,
            reasoningEffort: record.reasoningEffort,
            effectiveApprovalPolicy: record.approvalPolicy,
            effectiveSandboxPolicy: record.sandboxPolicy,
            queuedFollowUps: [],
            activeTurnId: record.activeTurnID,
            activePlanProgress: nil,
            pendingPlanImplementationPrompt: nil,
            contextTokensUsed: record.tokenUsage.map { UInt64(max(0, $0.totalTokens)) },
            modelContextWindow: nil,
            rateLimits: nil,
            realtimeSessionId: nil
        )
    }

    private func sessionSummary(_ record: ThreadRecord) -> AppSessionSummary {
        let lastAssistant = record.items.reversed().compactMap { item -> String? in
            if case .assistant(let data) = item.content { return data.text }
            return nil
        }.first
        let lastUser = record.items.reversed().compactMap { item -> String? in
            if case .user(let data) = item.content { return data.text }
            return nil
        }.first
        let lastTool = record.items.reversed().compactMap { item -> String? in
            if case .dynamicToolCall(let data) = item.content { return data.tool }
            return nil
        }.first
        let title = record.info.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = Self.preview(lastUser ?? record.info.preview ?? "New chat")

        return AppSessionSummary(
            key: record.key,
            serverDisplayName: serverDisplayName,
            serverHost: serverHost,
            title: title?.isEmpty == false ? title! : fallbackTitle,
            preview: record.info.preview ?? Self.preview(lastUser ?? lastAssistant ?? ""),
            cwd: record.info.cwd ?? defaultWorkingDirectoryPath,
            model: record.model,
            modelProvider: Self.providerID(for: record.model),
            parentThreadId: nil,
            agentNickname: nil,
            agentRole: nil,
            agentDisplayLabel: nil,
            agentStatus: .unknown,
            updatedAt: record.info.updatedAt,
            hasActiveTurn: record.activeTurnID != nil,
            isSubagent: false,
            isFork: false,
            lastResponsePreview: lastAssistant.map(Self.preview),
            lastResponseTurnId: nil,
            lastUserMessage: lastUser.map(Self.preview),
            lastToolLabel: lastTool,
            recentToolLog: [],
            lastTurnStartMs: record.lastTurnStartMs,
            lastTurnEndMs: record.lastTurnEndMs,
            stats: record.stats,
            tokenUsage: record.tokenUsage
        )
    }

    private func emitThreadUpsert(_ record: ThreadRecord) {
        emit(.threadUpserted(
            thread: threadSnapshot(record),
            sessionSummary: sessionSummary(record),
            agentDirectoryVersion: agentDirectoryVersion
        ))
    }

    private func emitThreadMetadata(_ record: ThreadRecord) {
        emit(.threadMetadataChanged(
            state: threadState(record),
            sessionSummary: sessionSummary(record),
            agentDirectoryVersion: agentDirectoryVersion
        ))
    }

    private func emit(_ update: AppStoreUpdateRecord) {
        lock.lock()
        let continuations = Array(subscriptions.values)
        lock.unlock()
        for continuation in continuations {
            continuation.yield(update)
        }
    }

    private func removeSubscription(_ id: UUID) {
        lock.lock()
        subscriptions.removeValue(forKey: id)
        lock.unlock()
    }

    private func lockedThread(threadId: String) -> ThreadRecord? {
        lock.lock()
        let record = threads[threadId]
        lock.unlock()
        return record
    }

    private func mergedToolDefinitions(dynamicTools: [AppDynamicToolSpec]) -> [PiToolDefinition] {
        var definitionsByName = Dictionary(uniqueKeysWithValues: toolDefinitions.map { ($0.name, $0) })
        for spec in dynamicTools where definitionsByName[spec.name] == nil {
            definitionsByName[spec.name] = PiToolDefinition(
                name: spec.name,
                description: spec.description,
                inputSchema: Self.piJSONValue(fromJSONString: spec.inputSchemaJson) ?? .object([:])
            )
        }
        return definitionsByName.values.sorted { $0.name < $1.name }
    }

    private static func piMessages(from inputs: [AppUserInput]) -> [PiMessage] {
        let text = promptText(from: inputs)
        let imageURLs = imageDataUris(from: inputs)
        guard !text.isEmpty || !imageURLs.isEmpty else { return [] }
        return [PiMessage(role: .user, content: text, imageURLs: imageURLs)]
    }

    private static func promptText(from inputs: [AppUserInput]) -> String {
        let textParts: [String] = inputs.compactMap { input in
            switch input {
            case .text(let text, _):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            case .image:
                return nil
            case .localImage(let path):
                return "[Local image: \(path.value)]"
            case .skill(let name, let path):
                return "[Skill: \(name) at \(path.value)]"
            case .mention(let name, let path):
                return "[Mention: \(name) at \(path)]"
            }
        }
        let imageCount = imageDataUris(from: inputs).count
        var parts = textParts
        if parts.isEmpty, imageCount > 0 {
            parts.append(imageCount == 1 ? "Image" : "\(imageCount) images")
        }
        return parts.joined(separator: "\n\n")
    }

    private static func imageDataUris(from inputs: [AppUserInput]) -> [String] {
        inputs.compactMap { input in
            guard case .image(let url) = input else { return nil }
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func messagesAfterCurrentInput(in messages: [PiMessage], inputMessages: [PiMessage]) -> [PiMessage] {
        guard !inputMessages.isEmpty, messages.count >= inputMessages.count else {
            return messages
        }

        let lastPossibleStart = messages.count - inputMessages.count
        for start in stride(from: lastPossibleStart, through: 0, by: -1) {
            var matches = true
            for offset in inputMessages.indices {
                if !messages[start + offset].matchesTurnInput(inputMessages[offset]) {
                    matches = false
                    break
                }
            }
            if matches {
                let firstCurrentOutput = start + inputMessages.count
                guard firstCurrentOutput < messages.count else { return [] }
                return Array(messages[firstCurrentOutput...])
            }
        }

        return messages
    }

    private static func hydratedItems(from messages: [PiMessage], threadID: String) -> [HydratedConversationItem] {
        var items: [HydratedConversationItem] = []
        var toolCallsByID: [String: PiToolCall] = [:]
        for (index, message) in messages.enumerated() {
            let id = "\(threadID)-\(index)"
            switch message.role {
            case .system:
                continue
            case .user:
                items.append(HydratedConversationItem(
                    id: id,
                    content: .user(HydratedUserMessageData(text: message.content, imageDataUris: message.imageURLs)),
                    sourceTurnId: nil,
                    sourceTurnIndex: UInt32(index),
                    timestamp: nil,
                    isFromUserTurnBoundary: true
                ))
            case .assistant:
                if let calls = message.toolCalls, !calls.isEmpty {
                    for call in calls {
                        toolCallsByID[call.id] = call
                    }
                }
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(HydratedConversationItem(
                        id: id,
                        content: .assistant(HydratedAssistantMessageData(text: message.content, agentNickname: nil, agentRole: nil, phase: .finalAnswer)),
                        sourceTurnId: nil,
                        sourceTurnIndex: UInt32(index),
                        timestamp: nil,
                        isFromUserTurnBoundary: false
                    ))
                }
            case .tool:
                let call = message.toolCallID.flatMap { toolCallsByID[$0] }
                items.append(HydratedConversationItem(
                    id: "\(threadID)-tool-\(message.toolCallID ?? String(index))",
                    content: .dynamicToolCall(
                        HydratedDynamicToolCallData(
                            tool: message.name ?? call?.name ?? "tool",
                            status: .completed,
                            durationMs: nil,
                            success: true,
                            argumentsJson: call.map { jsonString($0.arguments) },
                            contentSummary: preview(message.content)
                        )
                    ),
                    sourceTurnId: nil,
                    sourceTurnIndex: UInt32(index),
                    timestamp: nil,
                    isFromUserTurnBoundary: false
                ))
            }
        }
        return items
    }

    private static func title(from messages: [PiMessage]) -> String? {
        for message in messages.reversed() {
            guard let calls = message.toolCalls else { continue }
            for call in calls.reversed() where call.name == PiBuiltInToolDefinitions.title.name {
                if let title = call.arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !title.isEmpty {
                    return title
                }
            }
        }
        return nil
    }

    private static func preview(from messages: [PiMessage]) -> String? {
        guard let user = messages.first(where: { $0.role == .user }) else { return nil }
        if let text = user.content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return preview(text)
        }
        guard !user.imageURLs.isEmpty else { return nil }
        return user.imageURLs.count == 1 ? "Image" : "\(user.imageURLs.count) images"
    }

    private static func toolOutputsByCallID(_ messages: [PiMessage]) -> [String: String] {
        var outputs: [String: String] = [:]
        for message in messages where message.role == .tool {
            if let id = message.toolCallID {
                outputs[id] = message.content
            }
        }
        return outputs
    }

    private static func stats(for record: ThreadRecord) -> AppConversationStats {
        var userCount: UInt32 = 0
        var assistantCount: UInt32 = 0
        var dynamicToolCount: UInt32 = 0
        var webSearchCount: UInt32 = 0
        var imageCount: UInt32 = 0
        for item in record.items {
            switch item.content {
            case .user(let data):
                userCount += 1
                imageCount += UInt32(data.imageDataUris.count)
            case .assistant:
                assistantCount += 1
            case .dynamicToolCall(let data):
                dynamicToolCount += 1
                if data.tool == PiBuiltInToolDefinitions.webSearch.name {
                    webSearchCount += 1
                }
            case .webSearch:
                webSearchCount += 1
            default:
                break
            }
        }
        return AppConversationStats(
            totalMessages: userCount + assistantCount,
            userMessageCount: userCount,
            assistantMessageCount: assistantCount,
            turnCount: userCount,
            commandsExecuted: 0,
            commandsSucceeded: 0,
            commandsFailed: 0,
            totalCommandDurationMs: 0,
            filesChanged: 0,
            filesAdded: 0,
            filesModified: 0,
            filesDeleted: 0,
            diffAdditions: 0,
            diffDeletions: 0,
            toolCallCount: dynamicToolCount,
            mcpToolCallCount: 0,
            dynamicToolCallCount: dynamicToolCount,
            webSearchCount: webSearchCount,
            imageCount: imageCount,
            codeReviewCount: 0,
            widgetCount: 0,
            sessionDurationMs: nil
        )
    }

    private static func emptyStats() -> AppConversationStats {
        AppConversationStats(
            totalMessages: 0,
            userMessageCount: 0,
            assistantMessageCount: 0,
            turnCount: 0,
            commandsExecuted: 0,
            commandsSucceeded: 0,
            commandsFailed: 0,
            totalCommandDurationMs: 0,
            filesChanged: 0,
            filesAdded: 0,
            filesModified: 0,
            filesDeleted: 0,
            diffAdditions: 0,
            diffDeletions: 0,
            toolCallCount: 0,
            mcpToolCallCount: 0,
            dynamicToolCallCount: 0,
            webSearchCount: 0,
            imageCount: 0,
            codeReviewCount: 0,
            widgetCount: 0,
            sessionDurationMs: nil
        )
    }

    private static func tokenUsage(_ usage: PiUsage) -> AppTokenUsage {
        AppTokenUsage(
            totalTokens: Int64(usage.totalTokens),
            inputTokens: Int64(usage.inputTokens),
            cachedInputTokens: Int64(usage.cachedInputTokens),
            outputTokens: Int64(usage.outputTokens),
            reasoningOutputTokens: 0,
            contextWindow: nil
        )
    }

    private static func modelInfo(_ model: PiModelInfo) -> ModelInfo {
        let efforts = model.supportedReasoningEfforts
            .compactMap(reasoningEffort)
            .map { ReasoningEffortOption(reasoningEffort: $0, description: reasoningDescription($0)) }
        let defaultEffort = model.defaultReasoningEffort.flatMap(reasoningEffort) ?? .medium
        let modalities = model.inputModalities.contains("image") ? [InputModality.text, .image] : [.text]
        return ModelInfo(
            id: model.id,
            model: model.id,
            displayName: model.displayName,
            description: model.description,
            hidden: model.hidden,
            supportedReasoningEfforts: efforts,
            defaultReasoningEffort: defaultEffort,
            inputModalities: modalities,
            isDefault: model.isDefault
        )
    }

    private static func reasoningEffort(_ value: String) -> ReasoningEffort? {
        switch value.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
        case "none": return ReasoningEffort.none
        case "minimal": return .minimal
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "xhigh": return .xHigh
        default: return nil
        }
    }

    private static func reasoningEffortName(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .none: return "none"
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xHigh: return "xhigh"
        }
    }

    private static func reasoningDescription(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .none: return "No reasoning"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xHigh: return "Extra high"
        }
    }

    private static func planType(from rawValue: String?) -> PlanType {
        switch rawValue?.lowercased() {
        case "free": return .free
        case "go": return .go
        case "plus": return .plus
        case "pro": return .pro
        case "team": return .team
        case "business": return .business
        case "enterprise": return .enterprise
        case "edu": return .edu
        default: return .unknown
        }
    }

    private static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 140 else { return trimmed.isEmpty ? "New chat" : trimmed }
        return String(trimmed.prefix(137)) + "..."
    }

    private static func piJSONValue(fromJSONString json: String) -> PiJSONValue? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return try? PiJSONValue(jsonObject: object)
    }

    private static func jsonString(_ value: PiJSONValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value.jsonObject(), options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func nowSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

private struct PiNoopTitleToolRunner: PiToolRunner {
    func runTool(_ call: PiToolCall) throws -> PiToolResult {
        PiToolResult(
            callID: call.id,
            output: [
                "ok": true,
                "title": call.arguments["title"] ?? .null
            ]
        )
    }
}

private extension PiMessage {
    func matchesTurnInput(_ input: PiMessage) -> Bool {
        role == input.role
            && content == input.content
            && name == input.name
            && toolCallID == input.toolCallID
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
