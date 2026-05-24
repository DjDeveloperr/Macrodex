import Foundation

public struct MacrodexAgentCodexAuth: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var accountID: String
    public var idToken: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        accountID: String,
        idToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.idToken = idToken
    }

    public static func loadFromCodexAuthFile(
        _ url: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/auth.json")
    ) throws -> Self {
        let data = try Data(contentsOf: url)
        let authFile = try JSONDecoder().decode(CodexAuthFile.self, from: data)

        guard authFile.resolvedMode == "chatgpt" || authFile.resolvedMode == "chatgptAuthTokens" else {
            throw MacrodexAgentCodexProviderError.unsupportedAuthMode(authFile.resolvedMode)
        }
        guard let tokens = authFile.tokens else {
            throw MacrodexAgentCodexProviderError.missingAuthField("tokens")
        }
        guard !tokens.accessToken.isEmpty else {
            throw MacrodexAgentCodexProviderError.missingAuthField("tokens.access_token")
        }
        guard !tokens.accountID.isEmpty else {
            throw MacrodexAgentCodexProviderError.missingAuthField("tokens.account_id")
        }

        return Self(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken?.isEmpty == false ? tokens.refreshToken : nil,
            accountID: tokens.accountID,
            idToken: tokens.idToken
        )
    }

    public var accessTokenExpiration: Date? {
        Self.jwtExpiration(accessToken)
    }

    public var shouldRefreshAccessToken: Bool {
        guard let expiration = accessTokenExpiration else {
            return false
        }
        return expiration <= Date().addingTimeInterval(60)
    }

    private static func jwtExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload.append(String(repeating: "=", count: 4 - padding))
        }

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? TimeInterval
        else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}

public enum MacrodexAgentCodexProviderError: Error, Equatable, LocalizedError {
    case missingAuthField(String)
    case unsupportedAuthMode(String)
    case invalidURL(String)
    case invalidRequestBody(String)
    case invalidResponse(String)
    case httpStatus(Int, String)
    case refreshUnavailable
    case refreshFailed(Int, String)
    case noAssistantOutput

    public var errorDescription: String? {
        switch self {
        case .missingAuthField(let field):
            return "Codex auth is missing \(field)."
        case .unsupportedAuthMode(let mode):
            return "Unsupported Codex auth mode: \(mode)."
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .invalidRequestBody(let message):
            return "Invalid request body: \(message)"
        case .invalidResponse(let message):
            return "Invalid provider response: \(message)"
        case .httpStatus(let status, let body):
            return "Codex provider returned HTTP \(status): \(body)"
        case .refreshUnavailable:
            return "Codex auth has no refresh token."
        case .refreshFailed(let status, let body):
            return "Codex token refresh failed with HTTP \(status): \(body)"
        case .noAssistantOutput:
            return "Codex provider returned no assistant output."
        }
    }
}

public protocol MacrodexAgentCodexHTTPTransport {
    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse)
}

public protocol MacrodexAgentCodexStreamingHTTPTransport: MacrodexAgentCodexHTTPTransport {
    func performStreaming(
        _ request: URLRequest,
        onData: @escaping (Data) -> Void
    ) throws -> (Data, HTTPURLResponse)
}

public final class MacrodexAgentCodexChatGPTProvider: MacrodexAgentStreamingProviderClient {
    public static let defaultBaseURL = URL(string: "https://chatgpt.com/backend-api/codex")!
    public static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private var auth: MacrodexAgentCodexAuth
    private let baseURL: URL
    private let refreshURL: URL
    private let transport: any MacrodexAgentCodexHTTPTransport
    private let timeout: TimeInterval

    public convenience init(
        authFileURL: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/auth.json"),
        baseURL: URL = MacrodexAgentCodexChatGPTProvider.defaultBaseURL,
        refreshURL: URL = MacrodexAgentCodexChatGPTProvider.refreshURL,
        timeout: TimeInterval = 60
    ) throws {
        try self.init(
            auth: MacrodexAgentCodexAuth.loadFromCodexAuthFile(authFileURL),
            baseURL: baseURL,
            refreshURL: refreshURL,
            timeout: timeout
        )
    }

    public init(
        auth: MacrodexAgentCodexAuth,
        baseURL: URL = MacrodexAgentCodexChatGPTProvider.defaultBaseURL,
        refreshURL: URL = MacrodexAgentCodexChatGPTProvider.refreshURL,
        transport: any MacrodexAgentCodexHTTPTransport = URLSessionMacrodexAgentCodexHTTPTransport(),
        timeout: TimeInterval = 60
    ) {
        self.auth = auth
        self.baseURL = baseURL
        self.refreshURL = refreshURL
        self.transport = transport
        self.timeout = timeout
    }

    public func complete(_ request: MacrodexAgentProviderRequest) throws -> MacrodexAgentProviderResponse {
        try complete(request, eventHandler: nil)
    }

    public func complete(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: MacrodexAgentProviderStreamEventHandler?
    ) throws -> MacrodexAgentProviderResponse {
        if auth.shouldRefreshAccessToken {
            try refreshAuth()
        }

        let response = try performResponsesRequest(request, eventHandler: eventHandler)
        if response.statusCode == 401 {
            try refreshAuth()
            let retry = try performResponsesRequest(request, eventHandler: eventHandler)
            guard (200...299).contains(retry.statusCode) else {
                throw MacrodexAgentCodexProviderError.httpStatus(
                    retry.statusCode,
                    Self.safeResponseSnippet(retry.data)
                )
            }
            return try handleResponsesData(retry.data)
        }

        guard (200...299).contains(response.statusCode) else {
            throw MacrodexAgentCodexProviderError.httpStatus(
                response.statusCode,
                Self.safeResponseSnippet(response.data)
            )
        }

        return try handleResponsesData(response.data)
    }

    private func performResponsesRequest(
        _ providerRequest: MacrodexAgentProviderRequest,
        eventHandler: MacrodexAgentProviderStreamEventHandler?
    ) throws -> CodexHTTPResult {
        let url = baseURL.appendingPathComponent("responses")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try makeResponsesBody(providerRequest)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("MacrodexAgent/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, HTTPURLResponse)
        if let eventHandler,
           let streamingTransport = transport as? any MacrodexAgentCodexStreamingHTTPTransport {
            var parser = MacrodexAgentCodexEventStreamParser()
            (data, response) = try streamingTransport.performStreaming(request) { chunk in
                for payload in parser.append(chunk) {
                    if let event = Self.providerStreamEvent(
                        fromEventStreamPayload: payload,
                        providerRequest: providerRequest
                    ) {
                        eventHandler(event)
                    }
                }
            }
            for payload in parser.finish() {
                if let event = Self.providerStreamEvent(
                    fromEventStreamPayload: payload,
                    providerRequest: providerRequest
                ) {
                    eventHandler(event)
                }
            }
        } else {
            (data, response) = try transport.perform(request)
        }
        return CodexHTTPResult(statusCode: response.statusCode, data: data)
    }

    private func makeResponsesBody(_ request: MacrodexAgentProviderRequest) throws -> Data {
        let instructions = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let input = try request.messages.flatMap(makeResponseInputItems)
        let tools = try request.tools.map(makeResponseTool)

        var body: [String: Any] = [
            "model": request.model,
            "input": input,
            "tools": tools,
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "include": []
        ]
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }
        if let reasoningEffort = request.metadata["reasoning_effort"]?.stringValue,
           !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["reasoning"] = ["effort": reasoningEffort, "summary": "auto"]
        }
        if !request.metadata.isEmpty {
            body["client_metadata"] = try request.metadata.mapValues { try jsonObject($0) }
        }

        guard JSONSerialization.isValidJSONObject(body) else {
            throw MacrodexAgentCodexProviderError.invalidRequestBody("Responses payload is not JSON-serializable")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func makeResponseInputItems(_ message: MacrodexAgentMessage) throws -> [[String: Any]] {
        switch message.role {
        case .system:
            return []
        case .user:
            var content: [[String: Any]] = []
            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content.append([
                    "type": "input_text",
                    "text": message.content
                ])
            }
            content.append(contentsOf: message.imageURLs.map { url in
                [
                    "type": "input_image",
                    "image_url": url
                ]
            })
            if content.isEmpty {
                content.append([
                    "type": "input_text",
                    "text": ""
                ])
            }
            return [
                [
                    "type": "message",
                    "role": "user",
                    "content": content
                ]
            ]
        case .assistant:
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                return try toolCalls.map { call in
                    [
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": try jsonString(call.arguments)
                    ]
                }
            }
            return [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": message.content
                        ]
                    ]
                ]
            ]
        case .tool:
            guard let callID = message.toolCallID, !callID.isEmpty else {
                throw MacrodexAgentCodexProviderError.invalidRequestBody("Tool messages require toolCallID")
            }
            return [
                [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": message.content
                ]
            ]
        }
    }

    private func makeResponseTool(_ tool: MacrodexAgentToolDefinition) throws -> [String: Any] {
        if tool.name == MacrodexAgentBuiltInToolDefinitions.webSearch.name {
            return [
                "type": "web_search",
                "external_web_access": true
            ]
        }
        return [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "parameters": try jsonObject(tool.inputSchema)
        ]
    }

    private func handleResponsesData(_ data: Data) throws -> MacrodexAgentProviderResponse {
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("\ndata:") || text.hasPrefix("data:") {
            return try parseEventStream(text)
        }
        return try parseResponseJSON(data)
    }

    private func parseEventStream(_ text: String) throws -> MacrodexAgentProviderResponse {
        var assistantText = ""
        var outputDeltas: [String] = []
        var messageFromItem: MacrodexAgentMessage?
        var toolCalls: [MacrodexAgentToolCall] = []
        var usage: MacrodexAgentUsage?

        for event in Self.eventStreamDataPayloads(text) {
            guard event != "[DONE]" else {
                continue
            }
            guard let data = event.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else {
                continue
            }

            switch type {
            case "response.output_text.delta":
                let delta = object["delta"] as? String ?? ""
                assistantText += delta
                if !delta.isEmpty {
                    outputDeltas.append(delta)
                }
            case "response.output_item.done":
                guard let item = object["item"] as? [String: Any] else {
                    continue
                }
                if let message = Self.message(from: item) {
                    messageFromItem = message
                } else if let call = try Self.toolCall(from: item) {
                    toolCalls.append(call)
                }
            case "response.completed":
                if let response = object["response"] as? [String: Any] {
                    usage = Self.usage(from: response["usage"] as? [String: Any])
                }
            case "response.failed":
                throw MacrodexAgentCodexProviderError.invalidResponse(Self.responseFailureMessage(object))
            default:
                continue
            }
        }

        let message = messageFromItem ?? (!assistantText.isEmpty ? MacrodexAgentMessage(role: .assistant, content: assistantText) : nil)
        if message == nil && toolCalls.isEmpty {
            throw MacrodexAgentCodexProviderError.noAssistantOutput
        }
        return MacrodexAgentProviderResponse(
            message: message,
            outputDeltas: outputDeltas,
            toolCalls: toolCalls,
            usage: usage
        )
    }

    private func parseResponseJSON(_ data: Data) throws -> MacrodexAgentProviderResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MacrodexAgentCodexProviderError.invalidResponse("Expected a JSON object")
        }
        if let error = object["error"] as? [String: Any] {
            throw MacrodexAgentCodexProviderError.invalidResponse(Self.errorMessage(error))
        }

        let outputItems = object["output"] as? [[String: Any]] ?? []
        let message = outputItems.compactMap(Self.message(from:)).last
        let toolCalls = try outputItems.compactMap(Self.toolCall(from:))
        let usage = Self.usage(from: object["usage"] as? [String: Any])

        if message == nil && toolCalls.isEmpty {
            throw MacrodexAgentCodexProviderError.noAssistantOutput
        }
        return MacrodexAgentProviderResponse(message: message, toolCalls: toolCalls, usage: usage)
    }

    private func refreshAuth() throws {
        guard let refreshToken = auth.refreshToken, !refreshToken.isEmpty else {
            throw MacrodexAgentCodexProviderError.refreshUnavailable
        }

        var request = URLRequest(url: refreshURL, timeoutInterval: min(timeout, 30))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MacrodexAgent/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])

        let (data, response) = try transport.perform(request)
        guard (200...299).contains(response.statusCode) else {
            throw MacrodexAgentCodexProviderError.refreshFailed(
                response.statusCode,
                Self.safeResponseSnippet(data)
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MacrodexAgentCodexProviderError.invalidResponse("Refresh response was not a JSON object")
        }

        if let accessToken = object["access_token"] as? String, !accessToken.isEmpty {
            auth.accessToken = accessToken
        }
        if let idToken = object["id_token"] as? String, !idToken.isEmpty {
            auth.idToken = idToken
        }
        if let refreshToken = object["refresh_token"] as? String, !refreshToken.isEmpty {
            auth.refreshToken = refreshToken
        }
    }

    private static func eventStreamDataPayloads(_ text: String) -> [String] {
        var parser = MacrodexAgentCodexEventStreamParser()
        return parser.append(Data(text.utf8)) + parser.finish()
    }

    private static func providerStreamEvent(
        fromEventStreamPayload event: String,
        providerRequest: MacrodexAgentProviderRequest
    ) -> MacrodexAgentProviderStreamEvent? {
        guard event != "[DONE]",
              let data = event.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return nil
        }

        switch type {
        case "response.output_text.delta":
            let delta = object["delta"] as? String ?? ""
            guard !delta.isEmpty else {
                return nil
            }
            return MacrodexAgentProviderStreamEvent(
                type: "output_text.delta",
                providerID: providerRequest.providerID,
                threadID: providerRequest.threadID,
                payload: [
                    "delta": .string(delta)
                ]
            )
        case "response.reasoning_summary_text.delta":
            let delta = object["delta"] as? String ?? ""
            guard !delta.isEmpty else {
                return nil
            }
            return MacrodexAgentProviderStreamEvent(
                type: "reasoning_summary_text.delta",
                providerID: providerRequest.providerID,
                threadID: providerRequest.threadID,
                payload: [
                    "item_id": .string(object["item_id"] as? String ?? "reasoning"),
                    "delta": .string(delta)
                ]
            )
        case "response.reasoning_summary_text.done":
            let text = object["text"] as? String ?? object["delta"] as? String ?? ""
            return MacrodexAgentProviderStreamEvent(
                type: "reasoning_summary_text.done",
                providerID: providerRequest.providerID,
                threadID: providerRequest.threadID,
                payload: [
                    "item_id": .string(object["item_id"] as? String ?? "reasoning"),
                    "text": .string(text)
                ]
            )
        case "response.output_item.done":
            guard let item = object["item"] as? [String: Any] else {
                return nil
            }
            if let webSearchEvent = providerWebSearchEvent(from: item, providerRequest: providerRequest) {
                return webSearchEvent
            }
            guard let call = try? toolCall(from: item) else { return nil }
            return MacrodexAgentProviderStreamEvent(
                type: "tool_call.completed",
                providerID: providerRequest.providerID,
                threadID: providerRequest.threadID,
                payload: [
                    "call_id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": call.arguments
                ]
            )
        case "response.completed":
            return MacrodexAgentProviderStreamEvent(
                type: "completed",
                providerID: providerRequest.providerID,
                threadID: providerRequest.threadID
            )
        default:
            return nil
        }
    }

    private static func providerWebSearchEvent(
        from item: [String: Any],
        providerRequest: MacrodexAgentProviderRequest
    ) -> MacrodexAgentProviderStreamEvent? {
        guard item["type"] as? String == "web_search_call" else {
            return nil
        }
        let action = item["action"] as? [String: Any] ?? [:]
        let queries = action["queries"] as? [String]
        let query = queries?.first ?? action["query"] as? String ?? ""
        let actionJSON = (try? JSONSerialization.data(withJSONObject: action))
            .flatMap { String(data: $0, encoding: .utf8) }
        return MacrodexAgentProviderStreamEvent(
            type: "web_search.completed",
            providerID: providerRequest.providerID,
            threadID: providerRequest.threadID,
            payload: [
                "call_id": .string(item["id"] as? String ?? UUID().uuidString),
                "query": .string(query),
                "action_json": actionJSON.map(MacrodexAgentJSONValue.string) ?? .null
            ]
        )
    }

    private static func message(from item: [String: Any]) -> MacrodexAgentMessage? {
        guard item["type"] as? String == "message",
              item["role"] as? String == "assistant",
              let content = item["content"] as? [[String: Any]]
        else {
            return nil
        }
        let text = content.compactMap { contentItem -> String? in
            let type = contentItem["type"] as? String
            guard type == "output_text" || type == "input_text" else {
                return nil
            }
            return contentItem["text"] as? String
        }.joined()
        guard !text.isEmpty else {
            return nil
        }
        return MacrodexAgentMessage(role: .assistant, content: text)
    }

    private static func toolCall(from item: [String: Any]) throws -> MacrodexAgentToolCall? {
        let type = item["type"] as? String
        guard type == "function_call" || type == "custom_tool_call" else {
            return nil
        }
        let name = item["name"] as? String ?? ""
        let callID = item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString
        let rawArguments = item["arguments"] as? String ?? item["input"] as? String ?? "{}"
        let arguments = try jsonValue(fromJSONString: rawArguments)
        return MacrodexAgentToolCall(id: callID, name: name, arguments: arguments)
    }

    private static func usage(from object: [String: Any]?) -> MacrodexAgentUsage? {
        guard let object else {
            return nil
        }
        let inputDetails = object["input_tokens_details"] as? [String: Any]
        return MacrodexAgentUsage(
            inputTokens: object["input_tokens"] as? Int ?? 0,
            cachedInputTokens: inputDetails?["cached_tokens"] as? Int ?? 0,
            outputTokens: object["output_tokens"] as? Int ?? 0,
            totalTokens: object["total_tokens"] as? Int ?? 0
        )
    }

    private static func responseFailureMessage(_ object: [String: Any]) -> String {
        guard let response = object["response"] as? [String: Any],
              let error = response["error"] as? [String: Any]
        else {
            return "response.failed"
        }
        return errorMessage(error)
    }

    private static func errorMessage(_ error: [String: Any]) -> String {
        let code = error["code"] as? String
        let message = error["message"] as? String
        return [code, message].compactMap { $0 }.joined(separator: ": ")
    }

    private static func jsonValue(fromJSONString string: String) throws -> MacrodexAgentJSONValue {
        guard let data = string.data(using: .utf8) else {
            return .string(string)
        }
        if let value = try? JSONDecoder().decode(MacrodexAgentJSONValue.self, from: data) {
            return value
        }
        return .string(string)
    }

    private func jsonObject(_ value: MacrodexAgentJSONValue) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func jsonString(_ value: MacrodexAgentJSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MacrodexAgentCodexProviderError.invalidRequestBody("Failed to encode JSON arguments.")
        }
        return string
    }

    private static func safeResponseSnippet(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return String(text.prefix(600))
    }
}

public struct URLSessionMacrodexAgentCodexHTTPTransport: MacrodexAgentCodexStreamingHTTPTransport {
    public init() {}

    public func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        try performStreaming(request, onData: { _ in })
    }

    public func performStreaming(
        _ request: URLRequest,
        onData: @escaping (Data) -> Void
    ) throws -> (Data, HTTPURLResponse) {
        let delegate = StreamingDataDelegate(onData: onData)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)
        task.resume()
        let result = try delegate.waitForResult()
        session.finishTasksAndInvalidate()
        return result
    }
}

private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate {
    private let onData: (Data) -> Void
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var response: HTTPURLResponse?
    private var error: Error?

    init(onData: @escaping (Data) -> Void) {
        self.onData = onData
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return chunks.reduce(into: Data()) { result, chunk in
            result.append(chunk)
        }
    }

    func waitForResult() throws -> (Data, HTTPURLResponse) {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        if let error {
            throw error
        }
        guard let response else {
            throw MacrodexAgentCodexProviderError.invalidResponse("Missing HTTP response")
        }
        let body = chunks.reduce(into: Data()) { result, chunk in
            result.append(chunk)
        }
        return (body, response)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        chunks.append(data)
        lock.unlock()
        onData(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        self.error = error
        lock.unlock()
        semaphore.signal()
    }
}

private struct MacrodexAgentCodexEventStreamParser {
    private var buffer = ""

    mutating func append(_ data: Data) -> [String] {
        buffer += String(decoding: data, as: UTF8.self)
        return drain(onlyCompleteBlocks: true)
    }

    mutating func finish() -> [String] {
        drain(onlyCompleteBlocks: false)
    }

    private mutating func drain(onlyCompleteBlocks: Bool) -> [String] {
        var payloads: [String] = []

        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            if let payload = Self.payload(from: block) {
                payloads.append(payload)
            }
        }

        if !onlyCompleteBlocks {
            let trailing = buffer
            buffer = ""
            if let payload = Self.payload(from: trailing) {
                payloads.append(payload)
            }
        }

        return payloads
    }

    private static func payload(from block: String) -> String? {
        let lines = block
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let dataLines = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else {
                return nil
            }
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard !dataLines.isEmpty else {
            return nil
        }
        return dataLines.joined(separator: "\n")
    }
}

private struct CodexAuthFile: Decodable {
    var authMode: String?
    var openAIAPIKey: String?
    var tokens: CodexAuthTokens?

    var resolvedMode: String {
        if let authMode, !authMode.isEmpty {
            return authMode
        }
        if openAIAPIKey?.isEmpty == false {
            return "apiKey"
        }
        return "chatgpt"
    }

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
    }
}

private struct CodexAuthTokens: Decodable {
    var idToken: String?
    var accessToken: String
    var refreshToken: String?
    var accountID: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }
}

private struct CodexHTTPResult {
    var statusCode: Int
    var data: Data
}
