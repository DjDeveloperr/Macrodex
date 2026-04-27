import Foundation

public final class PiGoogleAIProvider: PiProviderClient {
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com")!

    private let apiKey: String
    private let baseURL: URL
    private let transport: any PiCodexHTTPTransport
    private let timeout: TimeInterval

    public init(
        apiKey: String,
        baseURL: URL = PiGoogleAIProvider.defaultBaseURL,
        transport: any PiCodexHTTPTransport = URLSessionPiCodexHTTPTransport(),
        timeout: TimeInterval = 90
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport
        self.timeout = timeout
    }

    public func complete(_ request: PiProviderRequest) throws -> PiProviderResponse {
        let model = Self.googleModelName(from: request.model)
        let url = baseURL
            .appendingPathComponent("v1beta")
            .appendingPathComponent("models")
            .appendingPathComponent("\(model):generateContent")

        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try makeGenerateContentBody(request)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("PiJSC/0.1 JavaScriptCore", forHTTPHeaderField: "User-Agent")

        let (data, response) = try transport.perform(urlRequest)
        guard (200...299).contains(response.statusCode) else {
            throw PiGoogleAIProviderError.httpStatus(response.statusCode, Self.safeResponseSnippet(data))
        }
        return try parseGenerateContentResponse(data)
    }

    private func makeGenerateContentBody(_ request: PiProviderRequest) throws -> Data {
        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        var toolNamesByCallID: [String: String] = [:]
        for message in request.messages {
            for call in message.toolCalls ?? [] {
                toolNamesByCallID[call.id] = call.name
            }
        }

        var body: [String: Any] = [
            "contents": try request.messages.compactMap { try makeContent($0, toolNamesByCallID: toolNamesByCallID) }
        ]

        if !systemText.isEmpty {
            body["systemInstruction"] = [
                "parts": [
                    ["text": systemText]
                ]
            ]
        }

        let declarations = try request.tools.map(makeFunctionDeclaration)
        if !declarations.isEmpty {
            body["tools"] = [
                ["functionDeclarations": declarations]
            ]
        }

        if let reasoningEffort = request.metadata["reasoning_effort"]?.stringValue,
           !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["generationConfig"] = [
                "thinkingConfig": [
                    "thinkingBudget": Self.thinkingBudget(for: reasoningEffort)
                ]
            ]
        }

        guard JSONSerialization.isValidJSONObject(body) else {
            throw PiGoogleAIProviderError.invalidRequestBody("Gemini payload is not JSON-serializable.")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func makeContent(_ message: PiMessage, toolNamesByCallID: [String: String]) throws -> [String: Any]? {
        switch message.role {
        case .system:
            return nil
        case .user:
            var parts: [[String: Any]] = []
            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(["text": message.content])
            }
            for imageURL in message.imageURLs {
                parts.append(Self.imagePart(from: imageURL) ?? ["text": "Image URL: \(imageURL)"])
            }
            if parts.isEmpty {
                parts.append(["text": ""])
            }
            return ["role": "user", "parts": parts]
        case .assistant:
            var parts: [[String: Any]] = []
            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(["text": message.content])
            }
            if let toolCalls = message.toolCalls {
                for call in toolCalls {
                    parts.append([
                        "functionCall": [
                            "name": call.name,
                            "args": try jsonObject(call.arguments)
                        ]
                    ])
                }
            }
            if parts.isEmpty {
                parts.append(["text": ""])
            }
            return ["role": "model", "parts": parts]
        case .tool:
            let name = message.name?.isEmpty == false
                ? message.name!
                : message.toolCallID.flatMap { toolNamesByCallID[$0] } ?? "tool_result"
            let responseObject = Self.toolResponseObject(from: message.content)
            return [
                "role": "user",
                "parts": [
                    [
                        "functionResponse": [
                            "name": name,
                            "response": responseObject
                        ]
                    ]
                ]
            ]
        }
    }

    private func makeFunctionDeclaration(_ tool: PiToolDefinition) throws -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "parameters": try sanitizedSchemaObject(tool.inputSchema)
        ]
    }

    private func parseGenerateContentResponse(_ data: Data) throws -> PiProviderResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PiGoogleAIProviderError.invalidResponse("Expected a JSON object.")
        }
        if let error = object["error"] as? [String: Any] {
            throw PiGoogleAIProviderError.invalidResponse(Self.errorMessage(error))
        }

        let candidates = object["candidates"] as? [[String: Any]] ?? []
        let parts = candidates
            .compactMap { $0["content"] as? [String: Any] }
            .flatMap { $0["parts"] as? [[String: Any]] ?? [] }

        let text = parts.compactMap { $0["text"] as? String }.joined()
        let toolCalls = try parts.compactMap(Self.toolCall)
        let usage = Self.usage(from: object["usageMetadata"] as? [String: Any])

        let message = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : PiMessage(role: .assistant, content: text)
        if message == nil && toolCalls.isEmpty {
            throw PiGoogleAIProviderError.noAssistantOutput
        }
        return PiProviderResponse(message: message, toolCalls: toolCalls, usage: usage)
    }

    private func sanitizedSchemaObject(_ value: PiJSONValue) throws -> Any {
        let object = try jsonObject(value)
        return Self.sanitizeSchema(object)
    }

    private func jsonObject(_ value: PiJSONValue) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func googleModelName(from model: String) -> String {
        if model.hasPrefix("google/") {
            return String(model.dropFirst("google/".count))
        }
        return model
    }

    private static func imagePart(from value: String) -> [String: Any]? {
        guard value.hasPrefix("data:"),
              let comma = value.firstIndex(of: ",")
        else {
            return nil
        }
        let header = String(value[value.index(value.startIndex, offsetBy: 5)..<comma])
        let data = String(value[value.index(after: comma)...])
        let mediaType = header.split(separator: ";").first.map(String.init) ?? "image/jpeg"
        guard header.localizedCaseInsensitiveContains("base64"), !data.isEmpty else {
            return nil
        }
        return [
            "inlineData": [
                "mimeType": mediaType,
                "data": data
            ]
        ]
    }

    private static func toolCall(from part: [String: Any]) throws -> PiToolCall? {
        guard let functionCall = part["functionCall"] as? [String: Any] else {
            return nil
        }
        let name = functionCall["name"] as? String ?? ""
        let args = functionCall["args"] ?? [:]
        return PiToolCall(
            id: UUID().uuidString.lowercased(),
            name: name,
            arguments: try PiJSONValue(jsonObject: args)
        )
    }

    private static func toolResponseObject(from text: String) -> [String: Any] {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return ["result": text]
    }

    private static func sanitizeSchema(_ value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(sanitizeSchema)
        }
        guard var object = value as? [String: Any] else {
            return value
        }
        object.removeValue(forKey: "$schema")
        object.removeValue(forKey: "additionalProperties")
        object.removeValue(forKey: "unevaluatedProperties")
        for (key, child) in object {
            object[key] = sanitizeSchema(child)
        }
        return object
    }

    private static func usage(from object: [String: Any]?) -> PiUsage? {
        guard let object else { return nil }
        let input = object["promptTokenCount"] as? Int ?? 0
        let output = object["candidatesTokenCount"] as? Int ?? 0
        return PiUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: object["totalTokenCount"] as? Int ?? input + output
        )
    }

    private static func thinkingBudget(for effort: String) -> Int {
        switch effort {
        case "low": return 512
        case "high": return 4096
        case "xhigh": return 8192
        default: return 2048
        }
    }

    private static func errorMessage(_ error: [String: Any]) -> String {
        let status = error["status"] as? String
        let message = error["message"] as? String
        return [status, message].compactMap { $0 }.joined(separator: ": ")
    }

    private static func safeResponseSnippet(_ data: Data) -> String {
        String(String(decoding: data, as: UTF8.self).prefix(800))
    }
}

public enum PiGoogleAIProviderError: Error, Equatable, LocalizedError {
    case invalidRequestBody(String)
    case invalidResponse(String)
    case httpStatus(Int, String)
    case noAssistantOutput

    public var errorDescription: String? {
        switch self {
        case .invalidRequestBody(let message):
            return "Invalid Google AI request: \(message)"
        case .invalidResponse(let message):
            return "Invalid Google AI response: \(message)"
        case .httpStatus(let status, let body):
            return "Google AI returned HTTP \(status): \(body)"
        case .noAssistantOutput:
            return "Google AI returned no assistant output."
        }
    }
}
