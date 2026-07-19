import Foundation
import MacrodexAgent

#if canImport(FoundationModels)
import FoundationModels
#endif

enum MacrodexAgentFoundationModelsProviderError: Error, LocalizedError {
    case unavailablePlatform
    case unavailableModel(String)
    case modelAssetsUnavailable(String)
    case generationFailed(String)
    case unsupportedImages
    case noAssistantOutput
    case pccRequiresNewSDK
    case pccRequiresNewOS
    case pccUnavailable(String)
    case pccQuotaLimitReached(String)
    case pccGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailablePlatform:
            return "Foundation Models are not available on this OS."
        case .unavailableModel(let reason):
            return "Foundation Models are unavailable: \(reason)"
        case .modelAssetsUnavailable(let reason):
            return "Foundation Models are unavailable because Apple model assets are missing: \(reason)"
        case .generationFailed(let reason):
            return "Foundation Models generation failed: \(reason)"
        case .unsupportedImages:
            return "Foundation Models in Macrodex currently support text input only."
        case .noAssistantOutput:
            return "Foundation Models returned no assistant output."
        case .pccRequiresNewSDK:
            return "Foundation Models PCC requires building Macrodex with the iOS 27 SDK. Select System on this build."
        case .pccRequiresNewOS:
            return "Foundation Models PCC requires iOS 27. Select System on this device."
        case .pccUnavailable(let reason):
            return "Foundation Models PCC is unavailable: \(reason)"
        case .pccQuotaLimitReached(let reason):
            return "Foundation Models PCC quota limit reached: \(reason)"
        case .pccGenerationFailed(let reason):
            return "Foundation Models PCC generation failed: \(reason)"
        }
    }
}

#if canImport(FoundationModels)
final class MacrodexAgentFoundationModelsProvider: MacrodexAgentStreamingProviderClient, @unchecked Sendable {
    private final class StreamHandlerBox: @unchecked Sendable {
        let handler: MacrodexAgentProviderStreamEventHandler?

        init(_ handler: MacrodexAgentProviderStreamEventHandler?) {
            self.handler = handler
        }
    }

    @available(iOS 26.0, *)
    private final class ToolCallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [MacrodexAgentToolCall] = []

        func append(name: String, arguments: MacrodexAgentJSONValue) {
            let call = MacrodexAgentToolCall(
                id: UUID().uuidString.lowercased(),
                name: name,
                arguments: arguments
            )
            lock.lock()
            calls.append(call)
            lock.unlock()
        }

        func recordedCalls() -> [MacrodexAgentToolCall] {
            lock.lock()
            let snapshot = calls
            lock.unlock()
            return snapshot
        }
    }

    @available(iOS 26.0, *)
    private struct RuntimeToolBridge: Tool {
        typealias Arguments = GeneratedContent
        typealias Output = String

        let name: String
        let description: String
        let parameters: GenerationSchema
        private let recorder: ToolCallRecorder

        init(definition: MacrodexAgentToolDefinition, recorder: ToolCallRecorder) {
            self.name = definition.name
            self.description = definition.description
            self.parameters = Self.schema(from: definition)
            self.recorder = recorder
        }

        func call(arguments: GeneratedContent) async throws -> String {
            recorder.append(
                name: name,
                arguments: Self.jsonValue(from: arguments)
            )
            return "Macrodex recorded the \(name) tool call. Do not invent tool results. Wait for Macrodex to provide the real tool output before answering the user."
        }

        private static func schema(from definition: MacrodexAgentToolDefinition) -> GenerationSchema {
            do {
                var dependencies: [DynamicGenerationSchema] = []
                let root = dynamicSchema(
                    from: definition.inputSchema,
                    name: safeSchemaName("\(definition.name)_arguments"),
                    description: "Arguments for \(definition.name).",
                    dependencies: &dependencies
                )
                return try GenerationSchema(root: root, dependencies: dependencies)
            } catch {
                return fallbackSchema(name: definition.name)
            }
        }

        private static func fallbackSchema(name: String) -> GenerationSchema {
            let root = DynamicGenerationSchema(
                name: safeSchemaName("\(name)_arguments"),
                description: "Arguments for \(name).",
                properties: [
                    DynamicGenerationSchema.Property(
                        name: "arguments_json",
                        description: "JSON arguments for the tool.",
                        schema: DynamicGenerationSchema(type: String.self)
                    )
                ]
            )
            return (try? GenerationSchema(root: root, dependencies: []))
                ?? GenerationSchema(
                    type: GeneratedContent.self,
                    description: "Arguments for \(name).",
                    properties: []
                )
        }

        private static func dynamicSchema(
            from value: MacrodexAgentJSONValue,
            name: String,
            description: String?,
            dependencies: inout [DynamicGenerationSchema]
        ) -> DynamicGenerationSchema {
            let object = value.objectValue ?? [:]
            if let enumValues = object["enum"]?.arrayValue?.compactMap(\.stringValue),
               !enumValues.isEmpty {
                return DynamicGenerationSchema(
                    name: name,
                    description: description,
                    anyOf: enumValues
                )
            }

            let type = object["type"]?.stringValue?.lowercased() ?? "object"
            switch type {
            case "string":
                return DynamicGenerationSchema(type: String.self)
            case "integer":
                return DynamicGenerationSchema(type: Int.self)
            case "number":
                return DynamicGenerationSchema(type: Double.self)
            case "boolean", "bool":
                return DynamicGenerationSchema(type: Bool.self)
            case "array":
                let itemSchema = dynamicSchema(
                    from: object["items"] ?? .object([:]),
                    name: safeSchemaName("\(name)_item"),
                    description: nil,
                    dependencies: &dependencies
                )
                return DynamicGenerationSchema(arrayOf: itemSchema)
            case "object":
                let propertiesObject = object["properties"]?.objectValue ?? [:]
                let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                let properties = propertiesObject
                    .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                    .map { key, schemaValue in
                        let propertyObject = schemaValue.objectValue ?? [:]
                        let propertyDescription = propertyObject["description"]?.stringValue
                        return DynamicGenerationSchema.Property(
                            name: key,
                            description: propertyDescription,
                            schema: dynamicSchema(
                                from: schemaValue,
                                name: safeSchemaName("\(name)_\(key)"),
                                description: propertyDescription,
                                dependencies: &dependencies
                            ),
                            isOptional: !required.contains(key)
                        )
                    }
                return DynamicGenerationSchema(
                    name: name,
                    description: object["description"]?.stringValue ?? description,
                    properties: properties
                )
            default:
                return DynamicGenerationSchema(type: String.self)
            }
        }

        private static func safeSchemaName(_ raw: String) -> String {
            let scalars = raw.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
            }
            let collapsed = String(scalars)
                .split(separator: "_")
                .joined(separator: "_")
            if let first = collapsed.unicodeScalars.first,
               CharacterSet.letters.contains(first) {
                return collapsed
            }
            return "Tool_\(collapsed)"
        }

        private static func jsonValue(from content: GeneratedContent) -> MacrodexAgentJSONValue {
            if let data = content.jsonString.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                return (try? MacrodexAgentJSONValue(jsonObject: object)) ?? .object([:])
            }
            return .object(["raw": .string(content.debugDescription)])
        }
    }

    func complete(_ request: MacrodexAgentProviderRequest) throws -> MacrodexAgentProviderResponse {
        try complete(request, eventHandler: nil)
    }

    func complete(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: MacrodexAgentProviderStreamEventHandler?
    ) throws -> MacrodexAgentProviderResponse {
        guard #available(iOS 26.0, *) else {
            throw MacrodexAgentFoundationModelsProviderError.unavailablePlatform
        }
        return try waitFor {
            try await self.completeAsync(request, eventHandler: StreamHandlerBox(eventHandler))
        }
    }

    private func waitFor<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultQueue = DispatchQueue(label: "com.dj.macrodex.foundation-models.result")
        var result: Result<T, Error>?

        Task {
            do {
                let value = try await operation()
                resultQueue.sync {
                    result = .success(value)
                }
            } catch {
                resultQueue.sync {
                    result = .failure(error)
                }
            }
            semaphore.signal()
        }

        semaphore.wait()
        let finalResult = resultQueue.sync { result }
        return try finalResult!.get()
    }

    @available(iOS 26.0, *)
    private func completeAsync(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: StreamHandlerBox
    ) async throws -> MacrodexAgentProviderResponse {
        guard request.messages.allSatisfy({ $0.imageURLs.isEmpty }) else {
            throw MacrodexAgentFoundationModelsProviderError.unsupportedImages
        }

        if Self.isPCCModel(request.model) {
#if compiler(>=6.4)
            guard #available(iOS 27.0, *) else {
                throw MacrodexAgentFoundationModelsProviderError.pccRequiresNewOS
            }
            return try await completePCCAsync(request, eventHandler: eventHandler)
#else
            throw MacrodexAgentFoundationModelsProviderError.pccRequiresNewSDK
#endif
        }

        return try await completeSystemAsync(request, eventHandler: eventHandler)
    }

    @available(iOS 26.0, *)
    private func completeSystemAsync(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: StreamHandlerBox
    ) async throws -> MacrodexAgentProviderResponse {
        let model = foundationModel(for: request.model)
        try validate(model: model)

        let instructions = Self.instructions(from: request)
        let prompt = Self.prompt(from: request.messages)
        let recorder = ToolCallRecorder()
        let tools = Self.runtimeTools(from: request.tools, recorder: recorder)
        let options = Self.generationOptions(allowingTools: !tools.isEmpty)
        let session = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: instructions
        )

        do {
            if eventHandler.handler != nil, tools.isEmpty {
                return try await streamResponse(
                    stream: session.streamResponse(to: prompt, options: options),
                    request: request,
                    eventHandler: eventHandler
                )
            }

            let response = try await session.respond(
                to: prompt,
                options: options
            )
            let toolCalls = recorder.recordedCalls()
            if !toolCalls.isEmpty {
                return MacrodexAgentProviderResponse(
                    toolCalls: toolCalls,
                    usage: Self.usageIfAvailable(from: response)
                )
            }
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw MacrodexAgentFoundationModelsProviderError.noAssistantOutput
            }
            return MacrodexAgentProviderResponse(
                message: MacrodexAgentMessage(role: .assistant, content: content),
                usage: Self.usageIfAvailable(from: response)
            )
        } catch {
            throw Self.providerError(from: error)
        }
    }

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    private func completePCCAsync(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: StreamHandlerBox
    ) async throws -> MacrodexAgentProviderResponse {
        let model = PrivateCloudComputeLanguageModel()
        try validatePCC(model: model)
        try validatePCCQuota(model: model)

        let instructions = Self.instructions(from: request)
        let prompt = Self.prompt(from: request.messages)
        let recorder = ToolCallRecorder()
        let tools = Self.runtimeTools(from: request.tools, recorder: recorder)
        let options = Self.generationOptions(allowingTools: !tools.isEmpty)
        let contextOptions = ContextOptions(reasoningLevel: Self.pccReasoningLevel(from: request))
        let session = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: instructions
        )

        do {
            if eventHandler.handler != nil, tools.isEmpty {
                return try await streamResponse(
                    stream: session.streamResponse(
                        to: prompt,
                        options: options,
                        contextOptions: contextOptions
                    ),
                    request: request,
                    eventHandler: eventHandler
                )
            }

            let response = try await session.respond(
                to: prompt,
                options: options,
                contextOptions: contextOptions
            )
            let toolCalls = recorder.recordedCalls()
            if !toolCalls.isEmpty {
                return MacrodexAgentProviderResponse(
                    toolCalls: toolCalls,
                    usage: Self.usage(from: response)
                )
            }
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw MacrodexAgentFoundationModelsProviderError.noAssistantOutput
            }
            return MacrodexAgentProviderResponse(
                message: MacrodexAgentMessage(role: .assistant, content: content),
                usage: Self.usage(from: response)
            )
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            throw Self.pccProviderError(from: error)
        } catch {
            throw Self.providerError(from: error, isPCC: true)
        }
    }
#endif

    @available(iOS 26.0, *)
    private func streamResponse(
        stream: LanguageModelSession.ResponseStream<String>,
        request: MacrodexAgentProviderRequest,
        eventHandler: StreamHandlerBox
    ) async throws -> MacrodexAgentProviderResponse {
        var previous = ""
        var deltas: [String] = []

        for try await snapshot in stream {
            let content = snapshot.content
            let delta = Self.delta(from: previous, to: content)
            previous = content
            guard !delta.isEmpty else { continue }
            deltas.append(delta)
            eventHandler.handler?(
                MacrodexAgentProviderStreamEvent(
                    type: "output_text.delta",
                    providerID: request.providerID,
                    threadID: request.threadID,
                    payload: [
                        "delta": .string(delta),
                        "aggregate": .string(content)
                    ]
                )
            )
        }

        let content = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw MacrodexAgentFoundationModelsProviderError.noAssistantOutput
        }
        return MacrodexAgentProviderResponse(
            message: MacrodexAgentMessage(role: .assistant, content: content),
            outputDeltas: deltas
        )
    }

    @available(iOS 26.0, *)
    private func foundationModel(for modelID: String) -> SystemLanguageModel {
        switch modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "system", "foundationmodels/system":
            return SystemLanguageModel(useCase: .general)
        default:
            return SystemLanguageModel(useCase: .general)
        }
    }

    @available(iOS 26.0, *)
    private func validate(model: SystemLanguageModel) throws {
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw MacrodexAgentFoundationModelsProviderError.unavailableModel(Self.availabilityReason(reason))
        @unknown default:
            throw MacrodexAgentFoundationModelsProviderError.unavailableModel("unknown")
        }
    }

    @available(iOS 26.0, *)
    private static func runtimeTools(
        from definitions: [MacrodexAgentToolDefinition],
        recorder: ToolCallRecorder
    ) -> [any Tool] {
        definitions.map { RuntimeToolBridge(definition: compactToolDefinition($0), recorder: recorder) }
    }

    private static func compactToolDefinition(_ definition: MacrodexAgentToolDefinition) -> MacrodexAgentToolDefinition {
        switch definition.name {
        case "title":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: "Rename the current thread.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "replaceExisting": ["type": "boolean"]
                    ],
                    "required": ["title"]
                ]
            )
        case "food_search":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: "Search Macrodex food memory, library foods, and recipes.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "purpose": ["type": "string"],
                        "query": ["type": "string"],
                        "limit": ["type": "integer"]
                    ],
                    "required": ["query"]
                ]
            )
        case "log_food":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: "Log one food to Macrodex with meal, serving, calories, and optional macros.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "purpose": ["type": "string"],
                        "foodName": ["type": "string"],
                        "mealType": ["type": "string"],
                        "logDate": ["type": "string"],
                        "quantity": ["type": "number"],
                        "unit": ["type": "string"],
                        "weightGrams": ["type": "number"],
                        "calories": ["type": "number"],
                        "protein": ["type": "number"],
                        "carbs": ["type": "number"],
                        "fat": ["type": "number"],
                        "notes": ["type": "string"],
                        "confirmedZeroCalories": ["type": "boolean"]
                    ],
                    "required": ["foodName"]
                ]
            )
        case "healthkit":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: "Read or sync Apple Health data.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "purpose": ["type": "string"],
                        "command": ["type": "string"],
                        "args": ["type": "array", "items": ["type": "string"]]
                    ],
                    "required": ["command"]
                ]
            )
        case "web_search":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: "Search the web.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "maxResults": ["type": "number"]
                    ],
                    "required": ["query"]
                ]
            )
        case "sql", "db_schema", "db_transaction", "jsc", "save_recipe_from_meal", "finalize_recipe_save":
            return compactDatabaseToolDefinition(definition)
        default:
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: String(definition.description.prefix(220)),
                inputSchema: definition.inputSchema
            )
        }
    }

    private static func compactDatabaseToolDefinition(_ definition: MacrodexAgentToolDefinition) -> MacrodexAgentToolDefinition {
        switch definition.name {
        case "sql":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: "Run labeled SQL against the Macrodex database.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "purpose": ["type": "string"],
                        "statement": ["type": "string"],
                        "bindings": ["type": "array", "items": ["description": "SQL binding value"]],
                        "mode": ["type": "string", "enum": ["auto", "query", "exec", "schema", "validate"]],
                        "tables": ["type": "array", "items": ["type": "string"]]
                    ],
                    "required": ["purpose"]
                ]
            )
        case "db_schema":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: "Inspect Macrodex database tables.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "purpose": ["type": "string"],
                        "tables": ["type": "array", "items": ["type": "string"]]
                    ]
                ]
            )
        case "db_transaction":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: "Run labeled SQL operations atomically.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "purpose": ["type": "string"],
                        "dryRun": ["type": "boolean"],
                        "operations": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "purpose": ["type": "string"],
                                    "statement": ["type": "string"],
                                    "bindings": ["type": "array", "items": ["description": "SQL binding value"]],
                                    "mode": ["type": "string", "enum": ["auto", "query", "exec", "validate"]]
                                ],
                                "required": ["statement"]
                            ]
                        ]
                    ],
                    "required": ["purpose", "operations"]
                ]
            )
        case "jsc":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: "Run JavaScriptCore with optional SQL helpers.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "purpose": ["type": "string"],
                        "script": ["type": "string"],
                        "argv": ["type": "array", "items": ["type": "string"]]
                    ],
                    "required": ["purpose", "script"]
                ]
            )
        case "save_recipe_from_meal", "finalize_recipe_save":
            return MacrodexAgentToolDefinition(
                name: definition.name,
                description: definition.name == "save_recipe_from_meal" ? "Save a logged meal as a recipe." : "Repair or verify a saved recipe.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "purpose": ["type": "string"],
                        "recipeName": ["type": "string"],
                        "logDate": ["type": "string"],
                        "mealType": ["type": "string"],
                        "logItemIds": ["type": "array", "items": ["type": "string"]],
                        "recipeId": ["type": "string"],
                        "dryRun": ["type": "boolean"],
                        "preview": ["type": "boolean"]
                    ],
                    "required": ["recipeName"]
                ]
            )
        default:
            return definition
        }
    }

    @available(iOS 26.0, *)
    private static func generationOptions(allowingTools: Bool) -> GenerationOptions {
        if #available(iOS 27.0, *), allowingTools {
            return GenerationOptions(
                temperature: 0.2,
                maximumResponseTokens: 900,
                toolCallingMode: .allowed
            )
        }
        return GenerationOptions(temperature: 0.2, maximumResponseTokens: 900)
    }

    @available(iOS 26.0, *)
    private static func usageIfAvailable(from response: LanguageModelSession.Response<String>) -> MacrodexAgentUsage? {
        if #available(iOS 27.0, *) {
            return usage(from: response)
        }
        return nil
    }

    @available(iOS 27.0, *)
    private static func usage(from response: LanguageModelSession.Response<String>) -> MacrodexAgentUsage {
        MacrodexAgentUsage(
            inputTokens: response.usage.input.totalTokenCount,
            cachedInputTokens: response.usage.input.cachedTokenCount,
            outputTokens: response.usage.output.totalTokenCount,
            totalTokens: response.usage.totalTokenCount
        )
    }

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    private func validatePCC(model: PrivateCloudComputeLanguageModel) throws {
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw MacrodexAgentFoundationModelsProviderError.pccUnavailable(Self.pccAvailabilityReason(reason))
        @unknown default:
            throw MacrodexAgentFoundationModelsProviderError.pccUnavailable("unknown")
        }
    }

    @available(iOS 27.0, *)
    private func validatePCCQuota(model: PrivateCloudComputeLanguageModel) throws {
        let usage = model.quotaUsage
        guard usage.isLimitReached else { return }
        throw MacrodexAgentFoundationModelsProviderError.pccQuotaLimitReached(
            Self.pccQuotaDescription(resetDate: usage.resetDate)
        )
    }

    @available(iOS 27.0, *)
    private static func pccAvailabilityReason(
        _ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "this device is not eligible"
        case .systemNotReady:
            return "the system is not ready yet"
        @unknown default:
            return "unknown"
        }
    }

    @available(iOS 27.0, *)
    private static func pccProviderError(
        from error: PrivateCloudComputeLanguageModel.Error
    ) -> MacrodexAgentFoundationModelsProviderError {
        switch error {
        case .networkFailure(let networkFailure):
            return .pccUnavailable("network failure: \(networkFailure.debugDescription)")
        case .quotaLimitReached(let quotaLimit):
            return .pccQuotaLimitReached(
                pccQuotaDescription(
                    resetDate: quotaLimit.resetDate,
                    fallback: quotaLimit.debugDescription
                )
            )
        case .serviceUnavailable(let serviceUnavailable):
            return .pccUnavailable("service unavailable: \(serviceUnavailable.debugDescription)")
        @unknown default:
            return .pccUnavailable(error.localizedDescription)
        }
    }

    @available(iOS 27.0, *)
    private static func pccReasoningLevel(from request: MacrodexAgentProviderRequest) -> ContextOptions.ReasoningLevel {
        let effort = request.metadata["reasoning_effort"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch effort {
        case "low", "light", "none":
            return .light
        case "high", "xhigh", "deep":
            return .deep
        default:
            return .moderate
        }
    }

    private static func pccQuotaDescription(resetDate: Date?, fallback: String? = nil) -> String {
        if let resetDate {
            return "try again after \(resetDate.formatted(date: .abbreviated, time: .shortened))"
        }
        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedFallback.isEmpty ? "try again later" : trimmedFallback
    }
#endif

    private static func providerError(from error: Error, isPCC: Bool = false) -> Error {
        if let providerError = error as? MacrodexAgentFoundationModelsProviderError {
            return providerError
        }

        if #available(iOS 27.0, *),
           let languageError = error as? LanguageModelError {
            return providerError(from: languageError, isPCC: isPCC)
        }

        let nsError = error as NSError
        let details = [
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")

        if nsError.domain == "com.apple.UnifiedAssetFramework" && nsError.code == 5000
            || details.localizedCaseInsensitiveContains("com.apple.modelcatalog")
            || details.localizedCaseInsensitiveContains("com.apple.MobileAsset.UAF.FM") {
            return MacrodexAgentFoundationModelsProviderError.modelAssetsUnavailable(
                "enable Apple Intelligence and let Foundation Models finish downloading on this device, or run Macrodex on an eligible iOS 27 device with the model assets installed."
            )
        }

        if nsError.domain.localizedCaseInsensitiveContains("FoundationModels")
            || details.localizedCaseInsensitiveContains("FoundationModels.LanguageModelError") {
            let reason = isPCC
                ? "the Apple PCC runtime failed before returning a typed availability, quota, or service result. On simulator this usually means PCC/model assets are not usable; verify the PCC entitlement, Apple Intelligence/model assets, and network on an eligible iOS 27 device."
                : "the Apple FoundationModels runtime failed before returning a typed result. Verify Apple Intelligence/model assets on this device."
            return isPCC
                ? MacrodexAgentFoundationModelsProviderError.pccGenerationFailed(reason)
                : MacrodexAgentFoundationModelsProviderError.generationFailed(reason)
        }

        return error
    }

    @available(iOS 27.0, *)
    private static func providerError(from error: LanguageModelError, isPCC: Bool) -> MacrodexAgentFoundationModelsProviderError {
        let prefix = isPCC ? "PCC " : ""
        let reason: String
        switch error {
        case .contextSizeExceeded(let context):
            reason = "\(prefix)context size exceeded: \(context.tokenCount) tokens for a \(context.contextSize)-token context."
        case .rateLimited(let rateLimit):
            if let resetDate = rateLimit.resetDate {
                reason = "\(prefix)rate limited; try again after \(resetDate.formatted(date: .abbreviated, time: .shortened))."
            } else {
                reason = "\(prefix)rate limited; try again later."
            }
        case .guardrailViolation(let violation):
            reason = "\(prefix)guardrail violation: \(violation.debugDescription)"
        case .refusal(let refusal):
            reason = "\(prefix)refusal: \(refusal.debugDescription)"
        case .unsupportedCapability(let unsupported):
            reason = "\(prefix)unsupported capability: \(unsupported.debugDescription)"
        case .unsupportedTranscriptContent(let unsupported):
            reason = "\(prefix)unsupported transcript content: \(unsupported.debugDescription)"
        case .unsupportedGenerationGuide(let unsupported):
            reason = "\(prefix)unsupported generation guide: \(unsupported.debugDescription)"
        case .unsupportedLanguageOrLocale(let unsupported):
            reason = "\(prefix)unsupported language or locale: \(unsupported.debugDescription)"
        case .timeout(let timeout):
            reason = "\(prefix)request timed out: \(timeout.debugDescription)"
        @unknown default:
            reason = "\(prefix)unknown language model error: \(error.debugDescription)"
        }
        return isPCC ? .pccGenerationFailed(reason) : .generationFailed(reason)
    }

    @available(iOS 26.0, *)
    private static func availabilityReason(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled"
        case .deviceNotEligible:
            return "this device is not eligible"
        case .modelNotReady:
            return "the model is not ready yet"
        @unknown default:
            return "unknown"
        }
    }

    private static func instructions(from request: MacrodexAgentProviderRequest) -> String {
        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n")
        var parts: [String] = []

        if let dateLine = Self.currentDateLine(from: systemText) {
            parts.append(dateLine)
        }

        parts.append(
            """
            You are Macrodex's Apple Foundation Models assistant. Be concise, useful, and honest.
            Use Macrodex tools for app data or actions; do not invent logged food, HealthKit, SQL, web, or recipe results.
            Food logs require a meal category: breakfast, lunch, dinner, snack, drink, pre_workout, post_workout, or other.
            SQL statements must start with a short `macrodex:` purpose comment.
            """
        )

        if !request.tools.isEmpty {
            let toolNames = request.tools.map(\.name).sorted().joined(separator: ", ")
            parts.append(
                "Available tools this turn: \(toolNames). After a tool call, wait for the real Macrodex tool output before answering."
            )
        }

        return parts.joined(separator: "\n\n")
    }

    private static func currentDateLine(from systemText: String) -> String? {
        systemText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                line.localizedCaseInsensitiveContains("today's local date")
                    || line.localizedCaseInsensitiveContains("today's date")
            }
    }

    private static func isPCCModel(_ modelID: String) -> Bool {
        switch modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pcc",
             "privatecloudcompute",
             "private-cloud-compute",
             "foundationmodels/pcc",
             "foundationmodels/privatecloudcompute",
             "foundationmodels/private-cloud-compute":
            return true
        default:
            return false
        }
    }

    private static func prompt(from messages: [MacrodexAgentMessage]) -> String {
        let parts = messages
            .filter { $0.role != .system }
            .map { message in
                switch message.role {
                case .user:
                    return "User: \(message.content)"
                case .assistant:
                    return "Assistant: \(message.content)"
                case .tool:
                    let trimmedName = message.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let name = trimmedName.isEmpty ? "tool" : trimmedName
                    return "Tool \(name): \(message.content)"
                case .system:
                    return ""
                }
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Self.joinRecentPromptParts(parts, maxCharacters: 6_000)
    }

    private static func joinRecentPromptParts(_ parts: [String], maxCharacters: Int) -> String {
        var kept: [String] = []
        var used = 0

        for part in parts.reversed() {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cost = trimmed.count + (kept.isEmpty ? 0 : 2)
            if used + cost <= maxCharacters {
                kept.append(trimmed)
                used += cost
                continue
            }

            let remaining = maxCharacters - used - 24
            if kept.isEmpty, remaining > 240 {
                kept.append("[Earlier content truncated]\n" + String(trimmed.suffix(remaining)))
            }
            break
        }

        return kept.reversed().joined(separator: "\n\n")
    }

    private static func delta(from previous: String, to current: String) -> String {
        guard !current.isEmpty else { return "" }
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        return current
    }
}
#endif
