(function (global) {
  "use strict";

  var version = "0.1.0";
  var nextThreadNumber = 1;
  var threads = Object.create(null);

  function parseJSON(json, label) {
    try {
      return JSON.parse(json);
    } catch (error) {
      throw new Error("Invalid " + label + " JSON: " + error.message);
    }
  }

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function makeThreadID() {
    var id = "thread-" + nextThreadNumber;
    nextThreadNumber += 1;
    return id;
  }

  function nowMilliseconds() {
    return Date.now ? Date.now() : new Date().getTime();
  }

  function event(type, threadID, payload) {
    return {
      type: type,
      threadID: threadID,
      payload: payload || {}
    };
  }

  function emit(events, type, threadID, payload) {
    var emitted = event(type, threadID, payload);
    events.push(emitted);
    if (typeof global.__piEmitEvent === "function") {
      global.__piEmitEvent(JSON.stringify(emitted));
    }
    return emitted;
  }

  function shouldCancel() {
    return typeof global.__piShouldCancel === "function" && Boolean(global.__piShouldCancel());
  }

  function throwIfCancelled() {
    if (shouldCancel()) {
      throw new Error("Turn cancelled.");
    }
  }

  function consumePendingInput() {
    if (typeof global.__piConsumePendingInput !== "function") {
      return [];
    }
    var raw = global.__piConsumePendingInput();
    if (typeof raw !== "string" || raw.length === 0) {
      return [];
    }
    var pending = parseJSON(raw, "pending input");
    if (!Array.isArray(pending)) {
      throw new Error("Pending input must be an array of messages");
    }
    return pending.map(normalizeMessage);
  }

  function persistThread(threadID, messages, createdAt) {
    threads[threadID] = {
      id: threadID,
      messages: clone(messages),
      createdAtMilliseconds: createdAt,
      updatedAtMilliseconds: nowMilliseconds()
    };
  }

  function requireString(value, label) {
    if (typeof value !== "string" || value.length === 0) {
      throw new Error(label + " must be a non-empty string");
    }
    return value;
  }

  function normalizeMessage(message) {
    if (!message || typeof message !== "object") {
      throw new Error("Message must be an object");
    }

    return {
      role: requireString(message.role, "Message role"),
      content: typeof message.content === "string" ? message.content : "",
      imageURLs: Array.isArray(message.imageURLs) ? message.imageURLs.filter(function (url) { return typeof url === "string" && url.length > 0; }) : [],
      name: typeof message.name === "string" ? message.name : null,
      toolCallID: typeof message.toolCallID === "string" ? message.toolCallID : null,
      toolCalls: Array.isArray(message.toolCalls) ? message.toolCalls.map(normalizeToolCall) : null
    };
  }

  function normalizeInput(input) {
    if (!Array.isArray(input)) {
      throw new Error("Turn input must be an array of messages");
    }

    return input.map(normalizeMessage);
  }

  function normalizeToolCall(call, index) {
    if (!call || typeof call !== "object") {
      throw new Error("Tool call must be an object");
    }

    return {
      id: typeof call.id === "string" && call.id.length > 0 ? call.id : "call-" + index,
      name: requireString(call.name, "Tool call name"),
      arguments: call.arguments === undefined ? {} : call.arguments
    };
  }

  function stringifyToolOutput(output) {
    if (output === null || output === undefined) {
      return "null";
    }

    if (typeof output === "string") {
      return output;
    }

    return JSON.stringify(output);
  }

  function hostProviderComplete(providerID, request) {
    if (typeof global.__piProviderComplete !== "function") {
      throw new Error("Native provider bridge is not installed");
    }

    var raw = global.__piProviderComplete(providerID, JSON.stringify(request));
    var envelope = parseJSON(raw, "provider envelope");
    if (!envelope.ok) {
      var providerMessage = envelope.error && envelope.error.message ? envelope.error.message : "Provider failed";
      throw new Error(providerMessage);
    }

    return envelope.value || {};
  }

  function hostToolRun(toolName, call) {
    if (typeof global.__piToolRun !== "function") {
      throw new Error("Native tool bridge is not installed");
    }

    var raw = global.__piToolRun(toolName, JSON.stringify(call));
    var envelope = parseJSON(raw, "tool envelope");
    if (!envelope.ok) {
      var toolMessage = envelope.error && envelope.error.message ? envelope.error.message : "Tool failed";
      throw new Error(toolMessage);
    }

    return envelope.value || {};
  }

  function mergeUsage(current, next) {
    if (!next || typeof next !== "object") {
      return current;
    }

    current.inputTokens += Number(next.inputTokens || 0);
    current.cachedInputTokens += Number(next.cachedInputTokens || 0);
    current.outputTokens += Number(next.outputTokens || 0);
    current.totalTokens += Number(next.totalTokens || 0);
    return current;
  }

  function capabilities() {
    return JSON.stringify({
      runtime: "PiJSC",
      engine: "JavaScriptCore",
      version: version,
      supportsPersistentThreads: true,
      supportsNativeProviderHooks: true,
      supportsNativeToolHooks: true,
      supportsEventStreaming: true,
      supportsThreadSnapshots: true,
      supportsModelCatalogs: true,
      supportedTransports: ["native-provider-hook", "native-tool-hook"]
    });
  }

  function reset() {
    threads = Object.create(null);
    nextThreadNumber = 1;
    return JSON.stringify({ ok: true });
  }

  function normalizeThreadRecord(threadID) {
    var record = threads[threadID];
    if (!record) {
      return null;
    }

    if (Array.isArray(record)) {
      record = {
        id: threadID,
        messages: record,
        createdAtMilliseconds: nowMilliseconds(),
        updatedAtMilliseconds: nowMilliseconds()
      };
      threads[threadID] = record;
    }

    return record;
  }

  function snapshotForRecord(record, includeMessages) {
    var messages = Array.isArray(record.messages) ? record.messages : [];
    return {
      id: record.id,
      messageCount: messages.length,
      createdAtMilliseconds: typeof record.createdAtMilliseconds === "number" ? record.createdAtMilliseconds : null,
      updatedAtMilliseconds: typeof record.updatedAtMilliseconds === "number" ? record.updatedAtMilliseconds : null,
      lastMessage: messages.length > 0 ? clone(messages[messages.length - 1]) : null,
      messages: includeMessages ? clone(messages) : null
    };
  }

  function listThreads() {
    var snapshots = [];
    for (var threadID in threads) {
      if (!Object.prototype.hasOwnProperty.call(threads, threadID)) {
        continue;
      }
      var record = normalizeThreadRecord(threadID);
      if (record) {
        snapshots.push(snapshotForRecord(record, false));
      }
    }
    snapshots.sort(function (lhs, rhs) {
      return Number(rhs.updatedAtMilliseconds || 0) - Number(lhs.updatedAtMilliseconds || 0);
    });
    return JSON.stringify(snapshots);
  }

  function threadSnapshot(threadID, includeMessages) {
    var record = normalizeThreadRecord(threadID);
    return JSON.stringify({
      thread: record ? snapshotForRecord(record, Boolean(includeMessages)) : null
    });
  }

  function deleteThread(threadID) {
    var existed = Boolean(threads[threadID]);
    if (existed) {
      delete threads[threadID];
    }
    return JSON.stringify({ deleted: existed });
  }

  function exportState() {
    return JSON.stringify({
      version: version,
      nextThreadNumber: nextThreadNumber,
      threads: threads
    });
  }

  function importState(stateJSON) {
    var state = parseJSON(stateJSON, "state");
    if (!state || typeof state !== "object" || !state.threads || typeof state.threads !== "object") {
      throw new Error("State must include a threads object");
    }
    threads = clone(state.threads);
    nextThreadNumber = typeof state.nextThreadNumber === "number" ? state.nextThreadNumber : 1;
    return JSON.stringify({ ok: true });
  }

  function runTurn(requestJSON) {
    var request = parseJSON(requestJSON, "turn request");
    var provider = request.provider || {};
    var providerID = requireString(provider.id, "Provider id");
    var model = requireString(provider.model, "Provider model");
    var threadID = typeof request.threadID === "string" && request.threadID.length > 0 ? request.threadID : makeThreadID();
    var existingThread = normalizeThreadRecord(threadID);
    var createdAt = existingThread ? existingThread.createdAtMilliseconds : nowMilliseconds();
    var messages = existingThread ? clone(existingThread.messages) : [];
    var input = normalizeInput(request.input || []);
    var events = [];
    var tools = Array.isArray(request.tools) ? request.tools : [];
    var metadata = request.metadata && typeof request.metadata === "object" ? request.metadata : {};
    var finalMessage = null;
    var usage = {
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      totalTokens: 0
    };
    var hasUsage = false;

    emit(events, "turn.started", threadID, { input_count: input.length });

    if (messages.length === 0 && typeof request.instructions === "string" && request.instructions.length > 0) {
      messages.push({
        role: "system",
        content: request.instructions,
        name: null,
        toolCallID: null
      });
    }

    for (var inputIndex = 0; inputIndex < input.length; inputIndex += 1) {
      messages.push(input[inputIndex]);
      emit(events, "message.added", threadID, {
        role: input[inputIndex].role,
        content_length: input[inputIndex].content.length
      });
    }
    persistThread(threadID, messages, createdAt);

    var toolRounds = 0;
    var webSearchOutputsByQuery = {};

    while (true) {
      throwIfCancelled();
      var providerRequest = {
        threadID: threadID,
        providerID: providerID,
        model: model,
        messages: clone(messages),
        tools: clone(tools),
        metadata: clone(metadata)
      };

      emit(events, "provider.requested", threadID, {
        provider_id: providerID,
        model: model,
        message_count: messages.length
      });

      var response = hostProviderComplete(providerID, providerRequest);
      throwIfCancelled();

      if (response.usage) {
        usage = mergeUsage(usage, response.usage);
        hasUsage = true;
      }

      if (response.message) {
        var assistantMessage = normalizeMessage(response.message);
        assistantMessage.role = "assistant";
        var deltas = Array.isArray(response.outputDeltas) ? response.outputDeltas : [];
        var assistantItemID = "assistant-" + (messages.length + 1);
        if (deltas.length > 0) {
          emit(events, "message.started", threadID, {
            item_id: assistantItemID,
            role: "assistant"
          });
          var aggregate = "";
          for (var deltaIndex = 0; deltaIndex < deltas.length; deltaIndex += 1) {
            var delta = typeof deltas[deltaIndex] === "string" ? deltas[deltaIndex] : String(deltas[deltaIndex]);
            aggregate += delta;
            emit(events, "message.delta", threadID, {
              item_id: assistantItemID,
              role: "assistant",
              delta: delta,
              aggregate: aggregate
            });
          }
        }
        messages.push(assistantMessage);
        persistThread(threadID, messages, createdAt);
        finalMessage = assistantMessage;
        emit(events, "message.completed", threadID, {
          item_id: assistantItemID,
          role: "assistant",
          content_length: assistantMessage.content.length
        });
      }

      var toolCalls = Array.isArray(response.toolCalls) ? response.toolCalls : [];
      if (toolCalls.length === 0) {
        break;
      }

      var normalizedToolCalls = toolCalls.map(normalizeToolCall);
      messages.push({
        role: "assistant",
        content: "",
        name: null,
        toolCallID: null,
        toolCalls: normalizedToolCalls
      });
      emit(events, "tool.calls_added", threadID, {
        count: normalizedToolCalls.length
      });

      for (var callIndex = 0; callIndex < normalizedToolCalls.length; callIndex += 1) {
        throwIfCancelled();
        var toolCall = normalizedToolCalls[callIndex];
        emit(events, "tool.started", threadID, {
          call_id: toolCall.id,
          name: toolCall.name,
          arguments: clone(toolCall.arguments)
        });

        var normalizedSearchQuery = null;
        if (toolCall.name === "web_search" && toolCall.arguments && typeof toolCall.arguments === "object") {
          var rawSearchQuery = typeof toolCall.arguments.query === "string" ? toolCall.arguments.query : toolCall.arguments.q;
          if (typeof rawSearchQuery === "string") {
            normalizedSearchQuery = rawSearchQuery.toLowerCase().replace(/\s+/g, " ").trim();
          }
        }

        var toolResult;
        if (normalizedSearchQuery && webSearchOutputsByQuery[normalizedSearchQuery]) {
          toolResult = {
            callID: toolCall.id,
            output: {
              query: toolCall.arguments.query || toolCall.arguments.q,
              duplicate: true,
              message: "This query was already searched during this turn. Reuse the previous web_search results instead of searching again.",
              previous: webSearchOutputsByQuery[normalizedSearchQuery]
            },
            isError: false
          };
        } else {
          toolResult = hostToolRun(toolCall.name, toolCall);
          throwIfCancelled();
          if (normalizedSearchQuery) {
            webSearchOutputsByQuery[normalizedSearchQuery] = clone(toolResult.output);
          }
        }
        var toolMessage = {
          role: "tool",
          content: stringifyToolOutput(toolResult.output),
          name: toolCall.name,
          toolCallID: typeof toolResult.callID === "string" ? toolResult.callID : toolCall.id
        };
        messages.push(toolMessage);
        persistThread(threadID, messages, createdAt);

        emit(events, "tool.completed", threadID, {
          call_id: toolMessage.toolCallID,
          name: toolCall.name,
          is_error: Boolean(toolResult.isError)
        });
      }

      var pendingInput = consumePendingInput();
      if (pendingInput.length > 0) {
        for (var pendingIndex = 0; pendingIndex < pendingInput.length; pendingIndex += 1) {
          messages.push(pendingInput[pendingIndex]);
        }
        persistThread(threadID, messages, createdAt);
        emit(events, "turn.input_appended", threadID, {
          count: pendingInput.length,
          message_count: messages.length
        });
      }

      toolRounds += 1;
    }

    persistThread(threadID, messages, createdAt);
    emit(events, "turn.completed", threadID, {
      message_count: messages.length,
      tool_rounds: toolRounds
    });

    return JSON.stringify({
      threadID: threadID,
      messages: messages,
      finalMessage: finalMessage,
      events: events,
      usage: hasUsage ? usage : null
    });
  }

  global.PiRuntime = {
    capabilities: capabilities,
    reset: reset,
    runTurn: runTurn,
    listThreads: listThreads,
    threadSnapshot: threadSnapshot,
    deleteThread: deleteThread,
    exportState: exportState,
    importState: importState
  };
})(this);
