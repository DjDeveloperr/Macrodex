import Foundation
import JavaScriptCore

public protocol PiProviderClient {
    func complete(_ request: PiProviderRequest) throws -> PiProviderResponse
}

public protocol PiStreamingProviderClient: PiProviderClient {
    func complete(
        _ request: PiProviderRequest,
        eventHandler: PiProviderStreamEventHandler?
    ) throws -> PiProviderResponse
}

public protocol PiToolRunner {
    func runTool(_ call: PiToolCall) throws -> PiToolResult
}

public typealias PiRuntimeEventHandler = (PiRuntimeEvent) -> Void
public typealias PiRuntimeCancellationChecker = () -> Bool
public typealias PiRuntimePendingInputProvider = () -> [PiMessage]

public enum PiRuntimeError: Error, Equatable, LocalizedError {
    case resourceMissing(String)
    case missingRuntimeObject
    case missingRuntimeFunction(String)
    case javaScriptException(String)
    case invalidJSONString(String)
    case invalidStateFile(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Runtime resource is missing: \(name)"
        case .missingRuntimeObject:
            return "The JavaScript runtime did not install PiRuntime."
        case .missingRuntimeFunction(let name):
            return "The JavaScript runtime is missing function: \(name)"
        case .javaScriptException(let message):
            return message
        case .invalidJSONString(let message):
            return "Invalid runtime JSON: \(message)"
        case .invalidStateFile(let message):
            return "Invalid runtime state file: \(message)"
        case .cancelled:
            return "Turn cancelled."
        }
    }
}

public final class PiJSCRuntime {
    private let context: JSContext
    private var providers: [String: any PiProviderClient] = [:]
    private var tools: [String: any PiToolRunner] = [:]
    private var modelCatalogs: [String: PiModelCatalog] = [
        PiBuiltInModelCatalogs.chatGPTCodex.providerID: PiBuiltInModelCatalogs.chatGPTCodex,
        PiBuiltInModelCatalogs.googleAI.providerID: PiBuiltInModelCatalogs.googleAI
    ]
    private var currentEventHandler: PiRuntimeEventHandler?
    private var currentCancellationChecker: PiRuntimeCancellationChecker?
    private var currentPendingInputProvider: PiRuntimePendingInputProvider?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(runtimeSource: String? = nil) throws {
        guard let context = JSContext() else {
            throw PiRuntimeError.missingRuntimeObject
        }

        self.context = context
        installExceptionHandler()
        installHostBindings()

        let source = try runtimeSource ?? Self.loadBundledRuntimeSource()
        context.evaluateScript(source)

        if let exception = context.exception, !exception.isUndefined, !exception.isNull {
            throw PiRuntimeError.javaScriptException(exception.toString() ?? "JavaScriptCore exception")
        }

        guard let runtime = context.objectForKeyedSubscript("PiRuntime"),
              !runtime.isUndefined,
              !runtime.isNull
        else {
            throw PiRuntimeError.missingRuntimeObject
        }
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

    public func registerProvider(_ provider: any PiProviderClient, for id: String) {
        providers[id] = provider
    }

    public func registerProvider(
        id: String,
        complete: @escaping (PiProviderRequest) throws -> PiProviderResponse
    ) {
        providers[id] = ClosureProviderClient(complete: complete)
    }

    public func registerTool(_ runner: any PiToolRunner, named name: String) {
        tools[name] = runner
    }

    public func registerTool(
        name: String,
        run: @escaping (PiToolCall) throws -> PiToolResult
    ) {
        tools[name] = ClosureToolRunner(run: run)
    }

    public func registerModelCatalog(_ catalog: PiModelCatalog) {
        modelCatalogs[catalog.providerID] = catalog
    }

    public func availableModels(providerID: String, includeHidden: Bool = false) -> [PiModelInfo] {
        let models = modelCatalogs[providerID]?.models ?? []
        return includeHidden ? models : models.filter { !$0.hidden }
    }

    public func preferredModelID(providerID: String) -> String? {
        modelCatalogs[providerID]?.defaultModel?.id
    }

    public func completeProvider(_ request: PiProviderRequest) throws -> PiProviderResponse {
        guard let provider = providers[request.providerID] else {
            throw PiRuntimeError.javaScriptException("Provider not registered: \(request.providerID)")
        }
        return try provider.complete(request)
    }

    public func capabilities() throws -> PiRuntimeCapabilities {
        let json = try callRuntimeFunction("capabilities", arguments: [])
        return try decode(PiRuntimeCapabilities.self, fromJSONString: json)
    }

    public func reset() throws {
        _ = try callRuntimeFunction("reset", arguments: [])
    }

    public func runTurn(_ request: PiTurnRequest) throws -> PiTurnResult {
        try runTurn(request, eventHandler: nil)
    }

    public func runTurn(
        _ request: PiTurnRequest,
        eventHandler: PiRuntimeEventHandler?,
        shouldCancel: PiRuntimeCancellationChecker? = nil,
        pendingInputProvider: PiRuntimePendingInputProvider? = nil
    ) throws -> PiTurnResult {
        let requestJSON = try encodeToJSONString(request)
        currentEventHandler = eventHandler
        currentCancellationChecker = shouldCancel
        currentPendingInputProvider = pendingInputProvider
        defer {
            currentEventHandler = nil
            currentCancellationChecker = nil
            currentPendingInputProvider = nil
        }
        let resultJSON = try callRuntimeFunction("runTurn", arguments: [requestJSON])
        return try decode(PiTurnResult.self, fromJSONString: resultJSON)
    }

    public func listThreads() throws -> [PiThreadSnapshot] {
        let json = try callRuntimeFunction("listThreads", arguments: [])
        return try decode([PiThreadSnapshot].self, fromJSONString: json)
    }

    public func threadSnapshot(threadID: String, includeMessages: Bool = true) throws -> PiThreadSnapshot? {
        let json = try callRuntimeFunction("threadSnapshot", arguments: [threadID, includeMessages])
        return try decode(OptionalThreadSnapshot.self, fromJSONString: json).thread
    }

    @discardableResult
    public func deleteThread(threadID: String) throws -> Bool {
        let json = try callRuntimeFunction("deleteThread", arguments: [threadID])
        return try decode(DeleteThreadResult.self, fromJSONString: json).deleted
    }

    public func exportState() throws -> String {
        try callRuntimeFunction("exportState", arguments: [])
    }

    public func importState(_ stateJSON: String) throws {
        _ = try callRuntimeFunction("importState", arguments: [stateJSON])
    }

    public func saveState(to url: URL) throws {
        let state = try exportState()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try state.write(to: url, atomically: true, encoding: .utf8)
    }

    public func loadState(from url: URL) throws {
        let state = try String(contentsOf: url, encoding: .utf8)
        guard state.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            throw PiRuntimeError.invalidStateFile("State file is not a JSON object.")
        }
        try importState(state)
    }

    private static func loadBundledRuntimeSource() throws -> String {
        guard let url = Bundle.module.url(
            forResource: "pi-jsc-runtime",
            withExtension: "js"
        ) else {
            throw PiRuntimeError.resourceMissing("pi-jsc-runtime.js")
        }

        return try String(contentsOf: url, encoding: .utf8)
    }

    private func installExceptionHandler() {
        context.exceptionHandler = { context, exception in
            context?.exception = exception
        }
    }

    private func installHostBindings() {
        let providerComplete: @convention(block) (String, String) -> String = { [weak self] providerID, requestJSON in
            guard let self else {
                return Self.failureEnvelope(
                    code: "runtime_deallocated",
                    message: "Native runtime was deallocated"
                )
            }

            return self.completeProvider(providerID: providerID, requestJSON: requestJSON)
        }

        let toolRun: @convention(block) (String, String) -> String = { [weak self] toolName, callJSON in
            guard let self else {
                return Self.failureEnvelope(
                    code: "runtime_deallocated",
                    message: "Native runtime was deallocated"
                )
            }

            return self.runTool(name: toolName, callJSON: callJSON)
        }

        let emitEvent: @convention(block) (String) -> Void = { [weak self] eventJSON in
            self?.emitEvent(eventJSON: eventJSON)
        }

        let shouldCancel: @convention(block) () -> Bool = { [weak self] in
            self?.currentCancellationChecker?() ?? false
        }

        let consumePendingInput: @convention(block) () -> String = { [weak self] in
            guard let self else { return "[]" }
            let messages = self.currentPendingInputProvider?() ?? []
            return (try? self.encodeToJSONString(messages)) ?? "[]"
        }

        context.setObject(providerComplete, forKeyedSubscript: "__piProviderComplete" as NSString)
        context.setObject(toolRun, forKeyedSubscript: "__piToolRun" as NSString)
        context.setObject(emitEvent, forKeyedSubscript: "__piEmitEvent" as NSString)
        context.setObject(shouldCancel, forKeyedSubscript: "__piShouldCancel" as NSString)
        context.setObject(consumePendingInput, forKeyedSubscript: "__piConsumePendingInput" as NSString)
    }

    private func completeProvider(providerID: String, requestJSON: String) -> String {
        do {
            if currentCancellationChecker?() == true {
                throw PiRuntimeError.cancelled
            }
            guard let provider = providers[providerID] else {
                return Self.failureEnvelope(
                    code: "provider_not_registered",
                    message: "Provider not registered: \(providerID)"
                )
            }

            let request = try decode(PiProviderRequest.self, fromJSONString: requestJSON)
            let response: PiProviderResponse
            if let streamingProvider = provider as? any PiStreamingProviderClient {
                response = try streamingProvider.complete(
                    request,
                    eventHandler: { [weak self] event in
                        self?.emitProviderStreamEvent(event)
                    }
                )
            } else {
                response = try provider.complete(request)
            }
            if currentCancellationChecker?() == true {
                throw PiRuntimeError.cancelled
            }
            return try successEnvelope(response)
        } catch {
            return Self.failureEnvelope(
                code: "provider_failed",
                message: error.localizedDescription
            )
        }
    }

    private func runTool(name: String, callJSON: String) -> String {
        do {
            if currentCancellationChecker?() == true {
                throw PiRuntimeError.cancelled
            }
            guard let runner = tools[name] else {
                return Self.failureEnvelope(
                    code: "tool_not_registered",
                    message: "Tool not registered: \(name)"
                )
            }

            let call = try decode(PiToolCall.self, fromJSONString: callJSON)
            let result = try runner.runTool(call)
            if currentCancellationChecker?() == true {
                throw PiRuntimeError.cancelled
            }
            return try successEnvelope(result)
        } catch {
            return Self.failureEnvelope(
                code: "tool_failed",
                message: error.localizedDescription
            )
        }
    }

    private func emitEvent(eventJSON: String) {
        guard let currentEventHandler else {
            return
        }

        do {
            let event = try decode(PiRuntimeEvent.self, fromJSONString: eventJSON)
            currentEventHandler(event)
        } catch {
            currentEventHandler(
                PiRuntimeEvent(
                    type: "runtime.event_decode_failed",
                    threadID: "",
                    payload: [
                        "error": .string(error.localizedDescription)
                    ]
                )
            )
        }
    }

    private func emitProviderStreamEvent(_ event: PiProviderStreamEvent) {
        currentEventHandler?(
            PiRuntimeEvent(
                type: "provider.\(event.type)",
                threadID: event.threadID,
                payload: event.payload.merging([
                    "provider_id": .string(event.providerID)
                ]) { current, _ in current }
            )
        )
    }

    private func callRuntimeFunction(_ name: String, arguments: [Any]) throws -> String {
        context.exception = nil

        guard let runtime = context.objectForKeyedSubscript("PiRuntime"),
              !runtime.isUndefined,
              !runtime.isNull
        else {
            throw PiRuntimeError.missingRuntimeObject
        }

        guard let function = runtime.objectForKeyedSubscript(name),
              !function.isUndefined,
              !function.isNull
        else {
            throw PiRuntimeError.missingRuntimeFunction(name)
        }

        let value = function.call(withArguments: arguments)

        if let exception = context.exception, !exception.isUndefined, !exception.isNull {
            throw PiRuntimeError.javaScriptException(exception.toString() ?? "JavaScriptCore exception")
        }

        guard let value,
              !value.isUndefined,
              !value.isNull,
              let string = value.toString()
        else {
            throw PiRuntimeError.invalidJSONString("Runtime function \(name) did not return a JSON string")
        }

        return string
    }

    private func encodeToJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PiRuntimeError.invalidJSONString("Failed to encode UTF-8 JSON")
        }
        return string
    }

    private func decode<T: Decodable>(_ type: T.Type, fromJSONString json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw PiRuntimeError.invalidJSONString("Runtime returned non-UTF-8 JSON")
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PiRuntimeError.invalidJSONString(error.localizedDescription)
        }
    }

    private func successEnvelope<T: Encodable>(_ value: T) throws -> String {
        try encodeToJSONString(HostEnvelope(ok: true, value: value, error: nil))
    }

    private static func failureEnvelope(code: String, message: String) -> String {
        let envelope = HostEnvelope<EmptyHostValue>(
            ok: false,
            value: nil,
            error: HostErrorPayload(code: code, message: message)
        )

        guard let data = try? JSONEncoder().encode(envelope),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"ok\":false,\"error\":{\"code\":\"encoding_failed\",\"message\":\"Failed to encode host failure\"}}"
        }

        return json
    }
}

private struct ClosureProviderClient: PiProviderClient {
    var complete: (PiProviderRequest) throws -> PiProviderResponse

    func complete(_ request: PiProviderRequest) throws -> PiProviderResponse {
        try complete(request)
    }
}

private struct ClosureToolRunner: PiToolRunner {
    var run: (PiToolCall) throws -> PiToolResult

    func runTool(_ call: PiToolCall) throws -> PiToolResult {
        try run(call)
    }
}

private struct HostEnvelope<Value: Encodable>: Encodable {
    var ok: Bool
    var value: Value?
    var error: HostErrorPayload?
}

private struct HostErrorPayload: Encodable {
    var code: String
    var message: String
}

private struct EmptyHostValue: Encodable {}

private struct OptionalThreadSnapshot: Decodable {
    var thread: PiThreadSnapshot?
}

private struct DeleteThreadResult: Decodable {
    var deleted: Bool
}
