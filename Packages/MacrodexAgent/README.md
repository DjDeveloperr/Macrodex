# Macrodex Agent

Macrodex Agent is the native Swift agent runtime for Macrodex. It owns the turn
loop, persistent thread message state, provider streaming, tool execution, and
thread snapshot/export/import behavior used by the app.

The package keeps the thread/message JSON shape stable so older local
conversation state can be imported without rewriting transcripts.

## Built-In Coverage

- `MacrodexAgentRuntime` runs turns, coordinates tool loops, streams provider
  events, and manages file-backed state.
- `MacrodexAgentCodexChatGPTProvider` supports Responses SSE parsing,
  ChatGPT-token refresh, reasoning summary stream events, and function-call
  continuation items.
- `MacrodexAgentBuiltInModelCatalogs` exposes model metadata for Macrodex model
  pickers.
- `MacrodexAgentBuiltInToolDefinitions` exposes standard tool schemas for
  `title`, `sql`, `jsc`, and `web_search`.
- `MacrodexAgentSQLiteToolRunner` runs SQL against an app-owned SQLite file with
  optional leading-comment enforcement.
- `MacrodexAgentScriptToolRunner` runs the explicit `jsc` scripting tool with
  console output and optional SQL helpers.
- `MacrodexAgentWebSearchToolRunner` provides injectable web search transport
  plus a default DuckDuckGo HTML implementation.
- `MacrodexAgentToolRegistry` installs the local tool set into a runtime.
