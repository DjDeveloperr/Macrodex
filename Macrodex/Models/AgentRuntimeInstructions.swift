import Foundation

enum AgentRuntimeInstructions {
    static let managedAgentsMarker = "<!-- macrodex-managed-agent-instructions -->"

    static let threadTitleInstructions = """
    Thread title management:
    - You have a dynamic tool named `title`.
    - In a new thread, call `title` with a short, specific title before or immediately after the first substantive response.
    - Call `title` again when the thread's main purpose materially changes.
    - Keep titles under 6 words, sentence case, and avoid punctuation unless it clarifies the title.
    - Do not call `title` if the user manually renamed the thread or explicitly tells you not to rename it.
    """

    static let calorieTrackingInstructions = """
    Calorie tracking:
    - Every food log must include an explicit meal category. Use the user's stated meal when present; otherwise infer it from local time and context.
    - Supported meal categories are breakfast, lunch, dinner, snack, drink, pre_workout, post_workout, and other. Use other only when no better category fits.
    - When logging food, use specific food names that match the app's food icon library when possible, such as Eggs, Greek yogurt, Salmon, Rice bowl, Chicken breast, Oatmeal, Banana, Coffee, or Salad.
    - For simple logging requests with an item name and amount, prefer the `log_food` tool. It does the local lookup, serving normalization, atomic insert, and confirmation in one call. Do not preflight schema or run scattered SQL first unless `log_food` fails or the request is ambiguous.
    - Zero-calorie foods are valid, but only log zero calories when you are sure. Obvious zero-calorie drinks like water, plain tea, black coffee, and diet soda can be logged directly. For anything else that resolves to zero calories/macros, verify from an exact local item, official/product nutrition source, or user confirmation, then call `log_food` with `confirmedZeroCalories: true`. Never log zero calories/macros for real food just because local data is missing. If `log_food` returns no match, zero-macro, or ambiguity for a normal food, do one targeted web search for nutrition data, prefer an official/product source when possible, then call `log_food` again with explicit calories/protein/carbs/fat for the user's amount. If the source data is still unclear, ask the user to confirm the serving or product before logging.
    - For count-based foods like "15 grapes", preserve the count unit (`grapes`, `eggs`, `pieces`) when natural. Do not convert a small count to grams unless the user gave grams or the nutrition source is per gram and you also keep a user-readable serving note.
    - Prefer human serving units over raw grams when the user gives a serving/count amount. Examples: write `0.8 serving`, `2 eggs`, or `1 cup`; only use `g`/`ml` when the user gave grams/milliliters or the serving is genuinely a measured weight/volume. If a food has a default serving weight, store that as `weightGrams` while keeping the display unit as `serving`.
    - For restaurant foods, use the restaurant's published macros as the tracked value when available. Do not model custom bowls/meals from ingredients unless the restaurant macros are missing, ambiguous, or the user explicitly asks for an estimate.
    - Use the existing matched `food_library_items` row directly when the local lookup is clear. Do not rebuild food/recipe rows or inspect supporting tables for a normal log.
    """

    static let sqlCommandInstructions = """
    SQL command summaries:
    - Every `sql` tool call must include `purpose`, a short user-facing summary. This is mandatory for reads and writes.
    - The SQL text must still start with a matching summary comment. Use `/* macrodex: Checking meals */` for one-line SQL and `-- macrodex: Updating breakfast` as the first line for multi-line SQL.
    - Keep labels present-tense, non-technical, and under 5 words. Examples: `Checking meals`, `Updating breakfast`, `Saving calories`.
    - Do not run unlabeled SQL. Macrodex uses `purpose` as the visible tool-call summary and the SQL comment as fallback.
    - For `jsc` scripts, every `sql.query(...)`, `db.query(...)`, `sql.exec(...)`, and `db.exec(...)` SQL string must start with the same summary comment.
    - Do not guess column names. If a table shape is uncertain, use `db_schema` or `sql` with `mode: "schema"` first.
    - For multi-step database changes, use `db_transaction` or `jsc` `sql.transaction(...)` so all operations run on one SQLite connection and return confirmations in one tool call.
    - Use `sql` with `mode: "validate"` before risky writes when you only need to prepare-check statement shape and bindings.
    - In the calorie database, `food_library_items` uses `name`, `brand`, `calories_kcal`, `protein_g`, `carbs_g`, and `fat_g`; it does not have `canonical_name`, `brand_name`, or `calories_per_100g`.
    - Saved recipes are `food_library_items` rows with `kind = 'recipe'`; recipe ingredients are `recipe_components` rows whose `recipe_id` references `food_library_items.id`.
    - `meal_templates` and `meal_template_items` are reusable meal templates, not saved recipes. Do not use them when the user asks to save or repair a recipe unless they explicitly ask for a reusable meal template.
    - Prefer `save_recipe_from_meal` when turning logged food items into a saved recipe. It auto-resolves by `recipeName`, creates/updates the recipe, writes `recipe_components`, links source log items, and returns deterministic status fields: `recipeId`, `created_new`, `updated_existing`, `archived_conflict`, `active_item_id`, `duplicate_recipe_ids`, and `notes`.
    - Do not pass `recipeId: ""`, `canonicalRecipeId: ""`, or `replaceExistingRecipeId: ""`. If a blank id slips through, the tool ignores it and reports that in `notes`.
    - Use `preview: true` before risky recipe repairs when you need to inspect exactly what would change without committing.
    - If a blank recipe id artifact already exists, use `finalize_recipe_save` once with `recipeName` and the relevant `logDate`/`mealType` or `logItemIds`.
    - After `save_recipe_from_meal`, use the returned top-level `recipeId` for follow-up checks. Do not rediscover the saved recipe by scattered name/date queries unless the tool returned an error.
    - For food macro lookups, search local `canonical_food_items` first, then linked `food_library_items.name`, `food_library_items.brand`, and `food_aliases.alias`.
    - Prefer the `food_search` tool for local fuzzy food lookup before raw SQL.
    - Prefer `log_food` over raw SQL for exact food logging. Use `food_search` only when the user asks to search/compare, or when you need to resolve ambiguity before calling `log_food`.
    - Use web search for macros only when local food memory is missing/ambiguous, or when the user explicitly asks for latest/current/online data.
    - If web search finds the food source, save the source title and URL in `nutrition_sources` and link it from the food/library row.
    - Store durable user preferences in `user_preference_memory` when the user states a stable preference.
    """

    static let webSearchInstructions = """
    Web search:
    - Use web search for current or product-specific facts, including packaged food nutrition.
    - For simple lookup questions, search once with a targeted query, then answer from the best cited source. Do not keep searching variations of the same query.
    - Do not repeat a web search query in the same turn. If results are insufficient, say what is missing instead of looping.
    - Prefer official brand pages or nutrition labels over generic SEO summaries.
    """

    static let healthKitInstructions = """
    HealthKit:
    - You have a dynamic tool named `healthkit` for Apple Health data.
    - Use `query` for samples, `stats` for bucketed quantity summaries, `types` for supported identifiers, and `sync-nutrition` after direct SQL food-log changes when immediate HealthKit sync is needed.
    - For nutrition sync, run `healthkit` with `command: "sync-nutrition"` directly. Do not preflight with `status`; if the sync output reports HealthKit is not set up or fields were skipped, mention that briefly to the user.
    - Use `status` for explicit HealthKit status questions and `request` only when the user asks to connect or enable Apple Health access.
    - Treat HealthKit writes as health records. Do not write guessed data unless the user explicitly asks you to.
    """

    @MainActor
    static func developerInstructions(for threadKey: ThreadKey? = nil) -> String {
        let todayContext = """
        Current date:
        - Today's local date is \(localDateString()).
        - For food logging, default to today's local date unless the user explicitly names a different date such as yesterday, tomorrow, or a specific calendar date.
        """
        let baseInstructions = [
            todayContext,
            threadTitleInstructions,
            calorieTrackingInstructions,
            sqlCommandInstructions,
            webSearchInstructions,
            healthKitInstructions
        ].joined(separator: "\n")
        if ManualThreadTitleStore.isManuallyRenamed(threadKey) {
            return baseInstructions + "\nThis thread was manually renamed by the user. Do not call `title` in this thread unless the user explicitly asks you to rename it."
        }
        return baseInstructions
    }

    static var defaultAgentsFileContents: String {
        """
        \(managedAgentsMarker)
        # Macrodex Agent Instructions

        Current date:
        - Agents receive today's local date dynamically in the thread instructions.
        - For food logging, default to today unless the user explicitly names a different date.

        \(threadTitleInstructions)

        \(calorieTrackingInstructions)

        \(sqlCommandInstructions)

        \(webSearchInstructions)

        \(healthKitInstructions)
        """
    }

    private static func localDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEEE, MMMM d, yyyy (yyyy-MM-dd)"
        return formatter.string(from: Date())
    }

    static func installDefaultAgentsFileIfNeeded() {
        guard let cwd = codex_ios_default_cwd() as String? else { return }
        let directory = URL(fileURLWithPath: cwd, isDirectory: true)
        let fileURL = directory.appendingPathComponent("AGENTS.md")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
                let updated: String
                if existing.contains(managedAgentsMarker) {
                    let prefix = existing.components(separatedBy: managedAgentsMarker).first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    updated = (prefix.isEmpty ? "" : prefix + "\n\n")
                        + defaultAgentsFileContents
                        + "\n"
                } else {
                    updated = existing.trimmingCharacters(in: .whitespacesAndNewlines)
                        + "\n\n"
                        + defaultAgentsFileContents
                        + "\n"
                }
                guard updated != existing else { return }
                try updated.write(to: fileURL, atomically: true, encoding: .utf8)
            } else {
                try (defaultAgentsFileContents + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            LLog.warn("agent", "failed to install default AGENTS.md", fields: ["error": error.localizedDescription])
        }
    }
}

enum AgentDynamicToolSpecs {
    static func defaultThreadTools(includeGenerativeUI: Bool) -> [AppDynamicToolSpec]? {
        var specs = [titleToolSpec()]
        if includeGenerativeUI {
            specs.append(contentsOf: generativeUiDynamicToolSpecs())
        }
        return specs
    }

    private static func titleToolSpec() -> AppDynamicToolSpec {
        let schema = JSONSchema.object(
            [
                "title": .string(description: "The concise user-facing thread title. Keep it under 6 words."),
                "replaceExisting": .boolean(description: "Set true only when the main purpose changed and the previous title was also generated by the agent.")
            ],
            required: ["title"]
        )
        let encodedSchema = (try? JSONEncoder().encode(schema))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return AppDynamicToolSpec(
            name: "title",
            description: "Rename the current thread. Use at the beginning of every new thread and when the thread purpose materially changes. Do not use if the user manually renamed the thread.",
            inputSchemaJson: encodedSchema,
            deferLoading: false
        )
    }
}
