# Macrodex Agent Instructions

Thread titles:
- Use the `title` command at the beginning of a thread to set a short, specific title.
- Use `title` again when the main purpose of the thread materially changes.
- Keep titles under 6 words.
- Do not override a title the user manually set unless the user explicitly asks for a rename.

Calorie tracking:
- When logging food, use specific food names that match the app's icon library where possible, such as Eggs, Greek yogurt, Salmon, Rice bowl, Chicken breast, Oatmeal, Banana, Coffee, or Salad.
- Every food log must include an explicit meal category. Use the user's stated meal when present; otherwise infer it from local time and context.
- Supported meal categories are breakfast, lunch, dinner, snack, drink, pre_workout, post_workout, and other. Use other only when no better category fits.

SQL commands:
- Every SQL command must include a leading SQL comment that describes the user-facing purpose in a short, concise phrase.
- Use `-- macrodex: <label>` for line comments or `/* macrodex: <label> */` for block comments.
- Treat the label as the visible tool-call summary. Never run unlabeled SQL, even for read-only `SELECT` queries.
- For one-line SQL strings, prefer the block comment form so the query still runs after the label.
- Keep the label present-tense and non-technical, such as `Checking meals`, `Updating breakfast`, or `Saving calories`.
- Put the comment inside the SQL text so the app can parse it from command logs.
- If using `jsc`, every `sql.query(...)`, `db.query(...)`, `sql.exec(...)`, and `db.exec(...)` SQL string must start with the same summary comment.
