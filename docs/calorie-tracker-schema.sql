-- Macrodex calorie tracker database schema.
-- Runtime database path on device:
--   app-dir/Documents/home/codex/db.sqlite
--
-- Local photo files are stored beside the database:
--   app-dir/Documents/home/codex/attachments/<uuid>.jpg
--
-- Time values are Unix epoch milliseconds unless noted.
-- Date values are local calendar dates in YYYY-MM-DD format.
-- IDs are TEXT so the app can use UUID/ULID values without SQLite extensions.
-- Mutable user data uses deleted_at_ms for soft delete.

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS schema_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS nutrient_definitions (
    key TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    unit TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('energy', 'macro', 'carb_detail', 'fat_detail', 'mineral', 'vitamin', 'other')),
    is_core INTEGER NOT NULL DEFAULT 0 CHECK (is_core IN (0, 1)),
    display_order INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
);

INSERT OR IGNORE INTO nutrient_definitions
    (key, label, unit, category, is_core, display_order, created_at_ms, updated_at_ms)
VALUES
    ('calories_kcal', 'Calories', 'kcal', 'energy', 1, 10, 0, 0),
    ('protein_g', 'Protein', 'g', 'macro', 1, 20, 0, 0),
    ('carbs_g', 'Carbohydrates', 'g', 'macro', 1, 30, 0, 0),
    ('fat_g', 'Fat', 'g', 'macro', 1, 40, 0, 0),
    ('fiber_g', 'Fiber', 'g', 'carb_detail', 0, 110, 0, 0),
    ('sugars_g', 'Sugars', 'g', 'carb_detail', 0, 120, 0, 0),
    ('added_sugars_g', 'Added sugars', 'g', 'carb_detail', 0, 130, 0, 0),
    ('saturated_fat_g', 'Saturated fat', 'g', 'fat_detail', 0, 210, 0, 0),
    ('trans_fat_g', 'Trans fat', 'g', 'fat_detail', 0, 220, 0, 0),
    ('cholesterol_mg', 'Cholesterol', 'mg', 'fat_detail', 0, 230, 0, 0),
    ('sodium_mg', 'Sodium', 'mg', 'mineral', 0, 310, 0, 0),
    ('potassium_mg', 'Potassium', 'mg', 'mineral', 0, 320, 0, 0),
    ('calcium_mg', 'Calcium', 'mg', 'mineral', 0, 330, 0, 0),
    ('iron_mg', 'Iron', 'mg', 'mineral', 0, 340, 0, 0),
    ('vitamin_d_mcg', 'Vitamin D', 'mcg', 'vitamin', 0, 410, 0, 0),
    ('caffeine_mg', 'Caffeine', 'mg', 'other', 0, 510, 0, 0);

CREATE TABLE IF NOT EXISTS nutrition_sources (
    id TEXT PRIMARY KEY,
    source_type TEXT NOT NULL CHECK (source_type IN ('label', 'database', 'restaurant', 'website', 'user_estimate', 'ai_estimate', 'other')),
    title TEXT,
    url TEXT,
    citation TEXT,
    notes TEXT,
    captured_at_ms INTEGER,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE TABLE IF NOT EXISTS food_library_items (
    id TEXT PRIMARY KEY CHECK (length(trim(id)) > 0),
    kind TEXT NOT NULL CHECK (kind IN ('food', 'recipe')),
    name TEXT NOT NULL,
    brand TEXT,
    barcode TEXT,
    default_serving_qty REAL,
    default_serving_unit TEXT,
    default_serving_weight_g REAL CHECK (default_serving_weight_g IS NULL OR default_serving_weight_g >= 0),
    calories_kcal REAL NOT NULL CHECK (calories_kcal >= 0),
    protein_g REAL CHECK (protein_g IS NULL OR protein_g >= 0),
    carbs_g REAL CHECK (carbs_g IS NULL OR carbs_g >= 0),
    fat_g REAL CHECK (fat_g IS NULL OR fat_g >= 0),
    notes TEXT,
    source_id TEXT REFERENCES nutrition_sources(id) ON DELETE SET NULL,
    is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_food_library_items_kind_name
    ON food_library_items(kind, name COLLATE NOCASE)
    WHERE deleted_at_ms IS NULL;

CREATE INDEX IF NOT EXISTS idx_food_library_items_barcode
    ON food_library_items(barcode)
    WHERE barcode IS NOT NULL AND deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS food_aliases (
    id TEXT PRIMARY KEY,
    library_item_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
    alias TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_food_aliases_alias
    ON food_aliases(alias COLLATE NOCASE)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS serving_units (
    id TEXT PRIMARY KEY,
    library_item_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    quantity REAL NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit TEXT NOT NULL,
    gram_weight REAL CHECK (gram_weight IS NULL OR gram_weight >= 0),
    is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_serving_units_library_item
    ON serving_units(library_item_id, is_default DESC)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS food_library_item_nutrients (
    library_item_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
    nutrient_key TEXT NOT NULL REFERENCES nutrient_definitions(key) ON DELETE RESTRICT,
    amount REAL NOT NULL CHECK (amount >= 0),
    source_id TEXT REFERENCES nutrition_sources(id) ON DELETE SET NULL,
    notes TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER,
    PRIMARY KEY (library_item_id, nutrient_key)
);

CREATE TABLE IF NOT EXISTS recipe_components (
    id TEXT PRIMARY KEY CHECK (length(trim(id)) > 0),
    recipe_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE CHECK (length(trim(recipe_id)) > 0),
    component_item_id TEXT REFERENCES food_library_items(id) ON DELETE SET NULL CHECK (component_item_id IS NULL OR length(trim(component_item_id)) > 0),
    component_name TEXT NOT NULL,
    quantity REAL NOT NULL CHECK (quantity > 0),
    unit TEXT NOT NULL,
    weight_g REAL CHECK (weight_g IS NULL OR weight_g >= 0),
    calories_kcal REAL CHECK (calories_kcal IS NULL OR calories_kcal >= 0),
    protein_g REAL CHECK (protein_g IS NULL OR protein_g >= 0),
    carbs_g REAL CHECK (carbs_g IS NULL OR carbs_g >= 0),
    fat_g REAL CHECK (fat_g IS NULL OR fat_g >= 0),
    sort_order INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_recipe_components_recipe
    ON recipe_components(recipe_id, sort_order)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS meal_templates (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    notes TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_meal_templates_name
    ON meal_templates(name COLLATE NOCASE)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS meal_template_items (
    id TEXT PRIMARY KEY,
    template_id TEXT NOT NULL REFERENCES meal_templates(id) ON DELETE CASCADE,
    library_item_id TEXT REFERENCES food_library_items(id) ON DELETE SET NULL,
    quantity REAL NOT NULL DEFAULT 1 CHECK (quantity > 0),
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_meal_template_items_template
    ON meal_template_items(template_id, sort_order)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS food_log_entries (
    id TEXT PRIMARY KEY,
    log_date TEXT NOT NULL,
    meal_type TEXT CHECK (meal_type IN ('breakfast', 'lunch', 'dinner', 'snack', 'drink', 'other')),
    title TEXT,
    notes TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_food_log_entries_date
    ON food_log_entries(log_date)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS food_log_items (
    id TEXT PRIMARY KEY,
    entry_id TEXT REFERENCES food_log_entries(id) ON DELETE CASCADE,
    parent_log_item_id TEXT REFERENCES food_log_items(id) ON DELETE CASCADE,
    library_item_id TEXT REFERENCES food_library_items(id) ON DELETE SET NULL CHECK (library_item_id IS NULL OR length(trim(library_item_id)) > 0),
    recipe_component_id TEXT REFERENCES recipe_components(id) ON DELETE SET NULL,
    log_date TEXT NOT NULL,
    logged_at_ms INTEGER NOT NULL,
    name TEXT NOT NULL,
    quantity REAL CHECK (quantity IS NULL OR quantity > 0),
    unit TEXT,
    weight_g REAL CHECK (weight_g IS NULL OR weight_g >= 0),
    serving_count REAL CHECK (serving_count IS NULL OR serving_count >= 0),
    calories_kcal REAL NOT NULL CHECK (calories_kcal >= 0),
    protein_g REAL CHECK (protein_g IS NULL OR protein_g >= 0),
    carbs_g REAL CHECK (carbs_g IS NULL OR carbs_g >= 0),
    fat_g REAL CHECK (fat_g IS NULL OR fat_g >= 0),
    notes TEXT,
    source_id TEXT REFERENCES nutrition_sources(id) ON DELETE SET NULL,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_food_log_items_date_time
    ON food_log_items(log_date, logged_at_ms)
    WHERE deleted_at_ms IS NULL;

CREATE INDEX IF NOT EXISTS idx_food_log_items_entry
    ON food_log_items(entry_id)
    WHERE entry_id IS NOT NULL AND deleted_at_ms IS NULL;

CREATE INDEX IF NOT EXISTS idx_food_log_items_library_item
    ON food_log_items(library_item_id)
    WHERE library_item_id IS NOT NULL AND deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS food_log_item_nutrients (
    log_item_id TEXT NOT NULL REFERENCES food_log_items(id) ON DELETE CASCADE,
    nutrient_key TEXT NOT NULL REFERENCES nutrient_definitions(key) ON DELETE RESTRICT,
    amount REAL NOT NULL CHECK (amount >= 0),
    source_id TEXT REFERENCES nutrition_sources(id) ON DELETE SET NULL,
    notes TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER,
    PRIMARY KEY (log_item_id, nutrient_key)
);

CREATE INDEX IF NOT EXISTS idx_food_log_item_nutrients_key
    ON food_log_item_nutrients(nutrient_key)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS favorite_foods (
    id TEXT PRIMARY KEY,
    library_item_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_favorite_foods_active
    ON favorite_foods(library_item_id)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS daily_notes (
    id TEXT PRIMARY KEY,
    note_date TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    mood TEXT,
    hunger TEXT,
    training TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_notes_active_date
    ON daily_notes(note_date)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS photo_attachments (
    id TEXT PRIMARY KEY,
    entity_type TEXT NOT NULL CHECK (entity_type IN ('log_item', 'library_item', 'recipe_component', 'daily_note')),
    entity_id TEXT NOT NULL,
    file_relative_path TEXT NOT NULL,
    mime_type TEXT,
    byte_size INTEGER CHECK (byte_size IS NULL OR byte_size >= 0),
    caption TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_photo_attachments_entity
    ON photo_attachments(entity_type, entity_id)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS goal_profiles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    starts_on TEXT,
    ends_on TEXT,
    is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    notes TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_goal_profiles_active
    ON goal_profiles(is_active, starts_on, ends_on)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS goal_profile_targets (
    profile_id TEXT NOT NULL REFERENCES goal_profiles(id) ON DELETE CASCADE,
    nutrient_key TEXT NOT NULL REFERENCES nutrient_definitions(key) ON DELETE RESTRICT,
    target_amount REAL CHECK (target_amount IS NULL OR target_amount >= 0),
    min_amount REAL CHECK (min_amount IS NULL OR min_amount >= 0),
    max_amount REAL CHECK (max_amount IS NULL OR max_amount >= 0),
    notes TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER,
    PRIMARY KEY (profile_id, nutrient_key),
    CHECK (
        target_amount IS NOT NULL OR
        min_amount IS NOT NULL OR
        max_amount IS NOT NULL
    )
);

CREATE TABLE IF NOT EXISTS daily_goal_overrides (
    id TEXT PRIMARY KEY,
    goal_date TEXT NOT NULL,
    notes TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_goal_overrides_active_date
    ON daily_goal_overrides(goal_date)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS daily_goal_override_targets (
    override_id TEXT NOT NULL REFERENCES daily_goal_overrides(id) ON DELETE CASCADE,
    nutrient_key TEXT NOT NULL REFERENCES nutrient_definitions(key) ON DELETE RESTRICT,
    target_amount REAL CHECK (target_amount IS NULL OR target_amount >= 0),
    min_amount REAL CHECK (min_amount IS NULL OR min_amount >= 0),
    max_amount REAL CHECK (max_amount IS NULL OR max_amount >= 0),
    notes TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER,
    PRIMARY KEY (override_id, nutrient_key),
    CHECK (
        target_amount IS NOT NULL OR
        min_amount IS NOT NULL OR
        max_amount IS NOT NULL
    )
);

CREATE VIEW IF NOT EXISTS daily_core_nutrition_totals AS
SELECT
    log_date,
    SUM(calories_kcal) AS calories_kcal,
    SUM(COALESCE(protein_g, 0)) AS protein_g,
    SUM(COALESCE(carbs_g, 0)) AS carbs_g,
    SUM(COALESCE(fat_g, 0)) AS fat_g
FROM food_log_items
WHERE deleted_at_ms IS NULL AND parent_log_item_id IS NULL
GROUP BY log_date;

CREATE VIEW IF NOT EXISTS daily_optional_nutrient_totals AS
SELECT
    fli.log_date,
    flin.nutrient_key,
    SUM(flin.amount) AS amount
FROM food_log_item_nutrients flin
JOIN food_log_items fli ON fli.id = flin.log_item_id
WHERE fli.deleted_at_ms IS NULL
    AND flin.deleted_at_ms IS NULL
    AND fli.parent_log_item_id IS NULL
GROUP BY fli.log_date, flin.nutrient_key;
