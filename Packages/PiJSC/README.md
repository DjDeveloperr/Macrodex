# PiJSC

PiJSC is a small SwiftPM experiment for running a provider-neutral agent loop inside JavaScriptCore on iOS and macOS.

The package intentionally avoids Node, subprocesses, `fetch`, and the Codex CLI. Swift owns native host functionality:

- provider completion hooks for OpenAI, ChatGPT-token-backed Codex API calls, Anthropic, Google, or OpenAI-compatible providers
- tool execution hooks
- typed turn, message, tool, and usage payloads
- model catalog metadata for picker UIs
- SQLite, JavaScriptCore scripting, and web search tool runners

The embedded JavaScript owns only the lightweight runtime behavior that needs to be portable:

- persistent thread message state
- provider request shaping
- tool-call loop coordination
- runtime event emission
- thread snapshot, list, delete, export, and import helpers

This is not a full Codex replacement yet. It is the validation layer for proving that a Pi-style harness can execute in JavaScriptCore and expose the app-facing primitives needed by a thin local runtime.

## Built-In Coverage

- `PiBuiltInModelCatalogs.chatGPTCodex` includes the ChatGPT Codex model slugs verified by the live provider smoke test.
- `PiBuiltInToolDefinitions` exposes standard tool schemas for `title`, `sql`, `jsc`, and `web_search`.
- `PiSQLiteToolRunner` runs row-returning and mutating SQL against an app-owned SQLite file, with optional leading-comment enforcement.
- `PiJSCScriptToolRunner` runs JavaScriptCore scripts with `console`, `crypto.randomUUID()`, `nowMs()`, `todayKey()`, and optional `sql` / `db` helpers.
- `PiWebSearchToolRunner` provides an injectable web-search transport and a default DuckDuckGo HTML implementation.
- `PiToolRegistry` installs a coherent local tool set into a runtime.
- `PiCodexChatGPTProvider` supports Responses SSE parsing, provider stream events, ChatGPT token refresh, and function-call continuation items.
- `PiJSCRuntime` supports event callbacks for runtime events and provider output deltas, plus thread list/read/delete/export/import and file-backed state load/save helpers.
