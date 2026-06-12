import Foundation

public protocol MacrodexAgentProviderClient {
    func complete(_ request: MacrodexAgentProviderRequest) throws -> MacrodexAgentProviderResponse
}

public protocol MacrodexAgentStreamingProviderClient: MacrodexAgentProviderClient {
    func complete(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: MacrodexAgentProviderStreamEventHandler?
    ) throws -> MacrodexAgentProviderResponse
}

public protocol MacrodexAgentToolRunner {
    func runTool(_ call: MacrodexAgentToolCall) throws -> MacrodexAgentToolResult
}

public typealias MacrodexAgentRuntimeEventHandler = (MacrodexAgentRuntimeEvent) -> Void
public typealias MacrodexAgentRuntimeCancellationChecker = () -> Bool
public typealias MacrodexAgentRuntimePendingInputProvider = () -> [MacrodexAgentMessage]

public enum MacrodexAgentRuntimeError: Error, Equatable, LocalizedError {
    case providerNotRegistered(String)
    case toolNotRegistered(String)
    case invalidStateFile(String)
    case invalidJSONString(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .providerNotRegistered(let id):
            return "Provider not registered: \(id)"
        case .toolNotRegistered(let name):
            return "Tool not registered: \(name)"
        case .invalidStateFile(let message):
            return "Invalid runtime state file: \(message)"
        case .invalidJSONString(let message):
            return "Invalid runtime JSON: \(message)"
        case .cancelled:
            return "Turn cancelled."
        }
    }
}

public final class MacrodexAgentRuntime {
    private struct RuntimeState: Codable {
        var version: String?
        var nextThreadNumber: Int
        var threads: [String: ThreadRecord]

        init(
            version: String? = MacrodexAgentRuntime.version,
            nextThreadNumber: Int = 1,
            threads: [String: ThreadRecord] = [:]
        ) {
            self.version = version
            self.nextThreadNumber = nextThreadNumber
            self.threads = threads
        }
    }

    private struct ThreadRecord: Codable, Equatable {
        var id: String
        var messages: [MacrodexAgentMessage]
        var createdAtMilliseconds: Int64?
        var updatedAtMilliseconds: Int64?
    }

    private struct OptionalThreadSnapshot: Codable {
        var thread: MacrodexAgentThreadSnapshot?
    }

    private struct DeleteThreadResult: Codable {
        var deleted: Bool
    }

    private static let version = "1.0.0"

    private var providers: [String: any MacrodexAgentProviderClient] = [:]
    private var tools: [String: any MacrodexAgentToolRunner] = [:]
    private var modelCatalogs: [String: MacrodexAgentModelCatalog] = [
        MacrodexAgentBuiltInModelCatalogs.chatGPTCodex.providerID: MacrodexAgentBuiltInModelCatalogs.chatGPTCodex,
        MacrodexAgentBuiltInModelCatalogs.googleAI.providerID: MacrodexAgentBuiltInModelCatalogs.googleAI,
        MacrodexAgentBuiltInModelCatalogs.foundationModels.providerID: MacrodexAgentBuiltInModelCatalogs.foundationModels
    ]
    private var state = RuntimeState()
    private var currentEventHandler: MacrodexAgentRuntimeEventHandler?
    private var currentCancellationChecker: MacrodexAgentRuntimeCancellationChecker?
    private var currentPendingInputProvider: MacrodexAgentRuntimePendingInputProvider?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(runtimeSource: String? = nil) throws {
        _ = runtimeSource
    }

    public convenience init(
        runtimeSource: String? = nil,
        loadingStateFrom stateFileURL: URL
    ) throws {
        try self.init(runtimeSource: runtimeSource)
        if FileManager.default.fileExists(atPath: stateFileURL.path) {
            try loadState(from: stateFileURL)
        }
    }

    public func registerProvider(_ provider: any MacrodexAgentProviderClient, for id: String) {
        providers[id] = provider
    }

    public func registerProvider(
        id: String,
        complete: @escaping (MacrodexAgentProviderRequest) throws -> MacrodexAgentProviderResponse
    ) {
        providers[id] = ClosureProviderClient(complete: complete)
    }

    public func registerTool(_ runner: any MacrodexAgentToolRunner, named name: String) {
        tools[name] = runner
    }

    public func registerTool(
        name: String,
        run: @escaping (MacrodexAgentToolCall) throws -> MacrodexAgentToolResult
    ) {
        tools[name] = ClosureToolRunner(run: run)
    }

    public func registerModelCatalog(_ catalog: MacrodexAgentModelCatalog) {
        modelCatalogs[catalog.providerID] = catalog
    }

    public func availableModels(providerID: String, includeHidden: Bool = false) -> [MacrodexAgentModelInfo] {
        let models = modelCatalogs[providerID]?.models ?? []
        return includeHidden ? models : models.filter { !$0.hidden }
    }

    public func preferredModelID(providerID: String) -> String? {
        modelCatalogs[providerID]?.defaultModel?.id
    }

    public func completeProvider(_ request: MacrodexAgentProviderRequest) throws -> MacrodexAgentProviderResponse {
        guard let provider = providers[request.providerID] else {
            throw MacrodexAgentRuntimeError.providerNotRegistered(request.providerID)
        }
        return try provider.complete(request)
    }

    public func capabilities() throws -> MacrodexAgentRuntimeCapabilities {
        MacrodexAgentRuntimeCapabilities(
            runtime: "MacrodexAgent",
            engine: "Swift",
            version: Self.version,
            supportsPersistentThreads: true,
            supportsNativeProviderHooks: true,
            supportsNativeToolHooks: true,
            supportsEventStreaming: true,
            supportsThreadSnapshots: true,
            supportsModelCatalogs: true,
            supportedTransports: ["native-provider", "native-tool"]
        )
    }

    public func reset() throws {
        state = RuntimeState()
    }

    public func runTurn(_ request: MacrodexAgentTurnRequest) throws -> MacrodexAgentTurnResult {
        try runTurn(request, eventHandler: nil)
    }

    public func runTurn(
        _ request: MacrodexAgentTurnRequest,
        eventHandler: MacrodexAgentRuntimeEventHandler?,
        shouldCancel: MacrodexAgentRuntimeCancellationChecker? = nil,
        pendingInputProvider: MacrodexAgentRuntimePendingInputProvider? = nil
    ) throws -> MacrodexAgentTurnResult {
        currentEventHandler = eventHandler
        currentCancellationChecker = shouldCancel
        currentPendingInputProvider = pendingInputProvider
        defer {
            currentEventHandler = nil
            currentCancellationChecker = nil
            currentPendingInputProvider = nil
        }
        return try runTurnSync(request)
    }

    public func listThreads() throws -> [MacrodexAgentThreadSnapshot] {
        state.threads.values
            .map { snapshot(for: $0, includeMessages: false) }
            .sorted {
                ($0.updatedAtMilliseconds ?? 0) > ($1.updatedAtMilliseconds ?? 0)
            }
    }

    public func threadSnapshot(threadID: String, includeMessages: Bool = true) throws -> MacrodexAgentThreadSnapshot? {
        guard let record = state.threads[threadID] else { return nil }
        return snapshot(for: record, includeMessages: includeMessages)
    }

    @discardableResult
    public func deleteThread(threadID: String) throws -> Bool {
        state.threads.removeValue(forKey: threadID) != nil
    }

    public func exportState() throws -> String {
        try encodeToJSONString(state)
    }

    public func importState(_ stateJSON: String) throws {
        guard let data = stateJSON.data(using: .utf8) else {
            throw MacrodexAgentRuntimeError.invalidStateFile("State file is not UTF-8.")
        }
        do {
            var decoded = try decoder.decode(RuntimeState.self, from: data)
            decoded.version = decoded.version ?? Self.version
            for (threadID, record) in decoded.threads where record.id.isEmpty || record.id != threadID {
                var normalized = record
                normalized.id = threadID
                decoded.threads[threadID] = normalized
            }
            state = decoded
        } catch {
            throw MacrodexAgentRuntimeError.invalidStateFile(error.localizedDescription)
        }
    }

    public func saveState(to url: URL) throws {
        let exported = try exportState()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try exported.write(to: url, atomically: true, encoding: .utf8)
    }

    public func loadState(from url: URL) throws {
        let state = try String(contentsOf: url, encoding: .utf8)
        guard state.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            throw MacrodexAgentRuntimeError.invalidStateFile("State file is not a JSON object.")
        }
        try importState(state)
    }

    private func runTurnSync(_ request: MacrodexAgentTurnRequest) throws -> MacrodexAgentTurnResult {
        try throwIfCancelled()
        let providerID = request.provider.id
        let model = request.provider.model
        let threadID = request.threadID?.nilIfBlank ?? makeThreadID()
        let createdAt = state.threads[threadID]?.createdAtMilliseconds ?? Self.nowMilliseconds()
        var messages = state.threads[threadID]?.messages ?? []
        let input = request.input.map(Self.normalizedMessage)
        var events: [MacrodexAgentRuntimeEvent] = []
        var finalMessage: MacrodexAgentMessage?
        var usage = MacrodexAgentUsage()
        var hasUsage = false
        var toolRounds = 0
        var searchedOutputsByQuery: [String: MacrodexAgentJSONValue] = [:]

        emit(&events, type: "turn.started", threadID: threadID, payload: [
            "input_count": .number(Double(input.count))
        ])

        if messages.isEmpty,
           let instructions = request.instructions?.nilIfBlank {
            messages.append(MacrodexAgentMessage(role: .system, content: instructions))
        }

        for item in input {
            messages.append(item)
            emit(&events, type: "message.added", threadID: threadID, payload: [
                "role": .string(item.role.rawValue),
                "content_length": .number(Double(item.content.count))
            ])
        }
        persistThread(threadID: threadID, messages: messages, createdAt: createdAt)

        while true {
            try throwIfCancelled()
            let providerRequest = MacrodexAgentProviderRequest(
                threadID: threadID,
                providerID: providerID,
                model: model,
                messages: messages,
                tools: request.tools,
                metadata: request.metadata
            )
            emit(&events, type: "provider.requested", threadID: threadID, payload: [
                "provider_id": .string(providerID),
                "model": .string(model),
                "message_count": .number(Double(messages.count))
            ])

            let response = try completeProviderStreaming(providerRequest)
            try throwIfCancelled()
            if let responseUsage = response.usage {
                usage = Self.mergeUsage(usage, responseUsage)
                hasUsage = true
            }

            if let message = response.message {
                let assistant = MacrodexAgentMessage(
                    role: .assistant,
                    content: message.content,
                    imageURLs: message.imageURLs,
                    name: message.name,
                    toolCallID: message.toolCallID,
                    toolCalls: nil
                )
                let deltas = response.outputDeltas
                let itemID = "assistant-\(messages.count + 1)"
                if !deltas.isEmpty {
                    emit(&events, type: "message.started", threadID: threadID, payload: [
                        "item_id": .string(itemID),
                        "role": .string("assistant")
                    ])
                    var aggregate = ""
                    for delta in deltas {
                        aggregate += delta
                        emit(&events, type: "message.delta", threadID: threadID, payload: [
                            "item_id": .string(itemID),
                            "role": .string("assistant"),
                            "delta": .string(delta),
                            "aggregate": .string(aggregate)
                        ])
                    }
                }
                messages.append(assistant)
                persistThread(threadID: threadID, messages: messages, createdAt: createdAt)
                finalMessage = assistant
                emit(&events, type: "message.completed", threadID: threadID, payload: [
                    "item_id": .string(itemID),
                    "role": .string("assistant"),
                    "content_length": .number(Double(assistant.content.count))
                ])
            }

            let toolCalls = response.toolCalls.map(Self.normalizedToolCall)
            guard !toolCalls.isEmpty else {
                break
            }

            messages.append(MacrodexAgentMessage(role: .assistant, content: "", toolCalls: toolCalls))
            emit(&events, type: "tool.calls_added", threadID: threadID, payload: [
                "count": .number(Double(toolCalls.count))
            ])
            persistThread(threadID: threadID, messages: messages, createdAt: createdAt)

            for call in toolCalls {
                try throwIfCancelled()
                emit(&events, type: "tool.started", threadID: threadID, payload: [
                    "call_id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": call.arguments
                ])

                let result = try runToolDeduplicatingWebSearch(
                    call,
                    searchedOutputsByQuery: &searchedOutputsByQuery
                )
                try throwIfCancelled()
                let toolMessage = MacrodexAgentMessage(
                    role: .tool,
                    content: Self.stringifyToolOutput(result.output),
                    name: call.name,
                    toolCallID: result.callID.isEmpty ? call.id : result.callID
                )
                messages.append(toolMessage)
                persistThread(threadID: threadID, messages: messages, createdAt: createdAt)
                emit(&events, type: "tool.completed", threadID: threadID, payload: [
                    "call_id": .string(toolMessage.toolCallID ?? call.id),
                    "name": .string(call.name),
                    "is_error": .bool(result.isError)
                ])
            }

            let pendingInput = currentPendingInputProvider?().map(Self.normalizedMessage) ?? []
            if !pendingInput.isEmpty {
                messages.append(contentsOf: pendingInput)
                persistThread(threadID: threadID, messages: messages, createdAt: createdAt)
                emit(&events, type: "turn.input_appended", threadID: threadID, payload: [
                    "count": .number(Double(pendingInput.count)),
                    "message_count": .number(Double(messages.count))
                ])
            }

            toolRounds += 1
            if toolRounds >= request.maxToolRounds {
                break
            }
        }

        persistThread(threadID: threadID, messages: messages, createdAt: createdAt)
        emit(&events, type: "turn.completed", threadID: threadID, payload: [
            "message_count": .number(Double(messages.count)),
            "tool_rounds": .number(Double(toolRounds))
        ])

        return MacrodexAgentTurnResult(
            threadID: threadID,
            messages: messages,
            finalMessage: finalMessage,
            events: events,
            usage: hasUsage ? usage : nil
        )
    }

    private func completeProviderStreaming(
        _ request: MacrodexAgentProviderRequest
    ) throws -> MacrodexAgentProviderResponse {
        guard let provider = providers[request.providerID] else {
            throw MacrodexAgentRuntimeError.providerNotRegistered(request.providerID)
        }
        if let streamingProvider = provider as? any MacrodexAgentStreamingProviderClient {
            return try streamingProvider.complete(request) { [weak self] event in
                self?.emitProviderStreamEvent(event)
            }
        }
        return try provider.complete(request)
    }

    private func runToolDeduplicatingWebSearch(
        _ call: MacrodexAgentToolCall,
        searchedOutputsByQuery: inout [String: MacrodexAgentJSONValue]
    ) throws -> MacrodexAgentToolResult {
        if let query = Self.normalizedWebSearchQuery(from: call),
           let previous = searchedOutputsByQuery[query] {
            return MacrodexAgentToolResult(
                callID: call.id,
                output: [
                    "query": call.arguments["query"] ?? call.arguments["q"] ?? .string(query),
                    "duplicate": true,
                    "message": "This query was already searched during this turn. Reuse the previous web_search results instead of searching again.",
                    "previous": previous
                ]
            )
        }
        guard let runner = tools[call.name] else {
            throw MacrodexAgentRuntimeError.toolNotRegistered(call.name)
        }
        let result = try runner.runTool(call)
        if let query = Self.normalizedWebSearchQuery(from: call) {
            searchedOutputsByQuery[query] = result.output
        }
        return result
    }

    private func emitProviderStreamEvent(_ event: MacrodexAgentProviderStreamEvent) {
        currentEventHandler?(
            MacrodexAgentRuntimeEvent(
                type: "provider.\(event.type)",
                threadID: event.threadID,
                payload: event.payload.merging([
                    "provider_id": .string(event.providerID)
                ]) { current, _ in current }
            )
        )
    }

    private func emit(
        _ events: inout [MacrodexAgentRuntimeEvent],
        type: String,
        threadID: String,
        payload: [String: MacrodexAgentJSONValue] = [:]
    ) {
        let event = MacrodexAgentRuntimeEvent(type: type, threadID: threadID, payload: payload)
        events.append(event)
        currentEventHandler?(event)
    }

    private func persistThread(threadID: String, messages: [MacrodexAgentMessage], createdAt: Int64?) {
        state.threads[threadID] = ThreadRecord(
            id: threadID,
            messages: messages,
            createdAtMilliseconds: createdAt ?? Self.nowMilliseconds(),
            updatedAtMilliseconds: Self.nowMilliseconds()
        )
    }

    private func snapshot(for record: ThreadRecord, includeMessages: Bool) -> MacrodexAgentThreadSnapshot {
        MacrodexAgentThreadSnapshot(
            id: record.id,
            messageCount: record.messages.count,
            createdAtMilliseconds: record.createdAtMilliseconds,
            updatedAtMilliseconds: record.updatedAtMilliseconds,
            lastMessage: record.messages.last,
            messages: includeMessages ? record.messages : nil
        )
    }

    private func makeThreadID() -> String {
        let id = "thread-\(state.nextThreadNumber)"
        state.nextThreadNumber += 1
        return id
    }

    private func throwIfCancelled() throws {
        if currentCancellationChecker?() == true {
            throw MacrodexAgentRuntimeError.cancelled
        }
    }

    private func encodeToJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MacrodexAgentRuntimeError.invalidJSONString("Failed to encode UTF-8 JSON.")
        }
        return json
    }

    private static func normalizedMessage(_ message: MacrodexAgentMessage) -> MacrodexAgentMessage {
        MacrodexAgentMessage(
            role: message.role,
            content: message.content,
            imageURLs: message.imageURLs.filter { !$0.isEmpty },
            name: message.name?.nilIfBlank,
            toolCallID: message.toolCallID?.nilIfBlank,
            toolCalls: message.toolCalls?.map(normalizedToolCall)
        )
    }

    private static func normalizedToolCall(_ call: MacrodexAgentToolCall) -> MacrodexAgentToolCall {
        MacrodexAgentToolCall(
            id: call.id.nilIfBlank ?? UUID().uuidString.lowercased(),
            name: call.name,
            arguments: call.arguments
        )
    }

    private static func normalizedWebSearchQuery(from call: MacrodexAgentToolCall) -> String? {
        guard call.name == MacrodexAgentBuiltInToolDefinitions.webSearch.name else {
            return nil
        }
        let raw = call.arguments["query"]?.stringValue ?? call.arguments["q"]?.stringValue
        return raw?
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .nilIfBlank
    }

    private static func stringifyToolOutput(_ value: MacrodexAgentJSONValue) -> String {
        if let string = value.stringValue {
            return string
        }
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return json
    }

    private static func mergeUsage(
        _ current: MacrodexAgentUsage,
        _ next: MacrodexAgentUsage
    ) -> MacrodexAgentUsage {
        MacrodexAgentUsage(
            inputTokens: current.inputTokens + next.inputTokens,
            cachedInputTokens: current.cachedInputTokens + next.cachedInputTokens,
            outputTokens: current.outputTokens + next.outputTokens,
            totalTokens: current.totalTokens + next.totalTokens
        )
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

private struct ClosureProviderClient: MacrodexAgentProviderClient {
    var complete: (MacrodexAgentProviderRequest) throws -> MacrodexAgentProviderResponse

    func complete(_ request: MacrodexAgentProviderRequest) throws -> MacrodexAgentProviderResponse {
        try complete(request)
    }
}

private struct ClosureToolRunner: MacrodexAgentToolRunner {
    var run: (MacrodexAgentToolCall) throws -> MacrodexAgentToolResult

    func runTool(_ call: MacrodexAgentToolCall) throws -> MacrodexAgentToolResult {
        try run(call)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
