import Foundation

public struct MacrodexAgentProviderDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var defaultBaseURL: String?
    public var wireAPI: String
    public var authEnvironmentVariable: String?
    public var supportsChatGPTAuth: Bool

    public init(
        id: String,
        displayName: String,
        defaultBaseURL: String?,
        wireAPI: String,
        authEnvironmentVariable: String?,
        supportsChatGPTAuth: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultBaseURL = defaultBaseURL
        self.wireAPI = wireAPI
        self.authEnvironmentVariable = authEnvironmentVariable
        self.supportsChatGPTAuth = supportsChatGPTAuth
    }
}

public enum MacrodexAgentBuiltInProviderRegistry {
    public static let openAI = MacrodexAgentProviderDescriptor(
        id: "openai",
        displayName: "OpenAI",
        defaultBaseURL: "https://api.openai.com/v1",
        wireAPI: "responses",
        authEnvironmentVariable: "OPENAI_API_KEY",
        supportsChatGPTAuth: true
    )

    public static let anthropic = MacrodexAgentProviderDescriptor(
        id: "anthropic",
        displayName: "Anthropic",
        defaultBaseURL: "https://api.anthropic.com",
        wireAPI: "messages",
        authEnvironmentVariable: "ANTHROPIC_API_KEY"
    )

    public static let google = MacrodexAgentProviderDescriptor(
        id: "google",
        displayName: "Google",
        defaultBaseURL: "https://generativelanguage.googleapis.com",
        wireAPI: "generate_content",
        authEnvironmentVariable: "GOOGLE_API_KEY"
    )

    public static let foundationModels = MacrodexAgentProviderDescriptor(
        id: "foundationmodels",
        displayName: "Foundation Models",
        defaultBaseURL: nil,
        wireAPI: "foundationmodels",
        authEnvironmentVariable: nil
    )

    public static let openAICompatible = MacrodexAgentProviderDescriptor(
        id: "openai_compatible",
        displayName: "OpenAI Compatible",
        defaultBaseURL: nil,
        wireAPI: "responses",
        authEnvironmentVariable: nil
    )

    public static let all: [MacrodexAgentProviderDescriptor] = [
        openAI,
        anthropic,
        google,
        foundationModels,
        openAICompatible
    ]
}

public enum MacrodexAgentRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct MacrodexAgentMessage: Codable, Equatable, Sendable {
    public var role: MacrodexAgentRole
    public var content: String
    public var imageURLs: [String]
    public var name: String?
    public var toolCallID: String?
    public var toolCalls: [MacrodexAgentToolCall]?

    public init(
        role: MacrodexAgentRole,
        content: String,
        imageURLs: [String] = [],
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [MacrodexAgentToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.imageURLs = imageURLs
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case imageURLs
        case name
        case toolCallID
        case toolCalls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(MacrodexAgentRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        imageURLs = try container.decodeIfPresent([String].self, forKey: .imageURLs) ?? []
        name = try container.decodeIfPresent(String.self, forKey: .name)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolCalls = try container.decodeIfPresent([MacrodexAgentToolCall].self, forKey: .toolCalls)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        if !imageURLs.isEmpty {
            try container.encode(imageURLs, forKey: .imageURLs)
        }
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
    }
}

public struct MacrodexAgentToolDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: MacrodexAgentJSONValue

    public init(
        name: String,
        description: String,
        inputSchema: MacrodexAgentJSONValue = .object([:])
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum MacrodexAgentBuiltInToolDefinitions {
    public static let title = MacrodexAgentToolDefinition(
        name: "title",
        description: "Rename the current thread with a short, user-facing title.",
        inputSchema: [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "The concise user-facing thread title."
                ],
                "replaceExisting": [
                    "type": "boolean",
                    "description": "Set true only when replacing a previously generated title."
                ]
            ],
            "required": ["title"]
        ]
    )

    public static let sql = MacrodexAgentToolDefinition(
        name: "sql",
        description: "Run SQL against an app-owned SQLite database. SELECT, WITH, PRAGMA, and EXPLAIN return rows; mutating statements return a change count. Use schema or validate modes before uncertain writes. Always include a short user-facing purpose.",
        inputSchema: [
            "type": "object",
            "properties": [
                "purpose": [
                    "type": "string",
                    "description": "Short present-tense user-facing purpose for this SQL call, for example Checking meals, Updating breakfast, or Saving calories."
                ],
                "statement": [
                    "type": "string",
                    "description": "The SQL statement to run."
                ],
                "bindings": [
                    "type": "array",
                    "items": [
                        "description": "JSON value to bind at the next positional SQL placeholder."
                    ],
                    "description": "Optional positional bindings."
                ],
                "mode": [
                    "type": "string",
                    "enum": ["auto", "query", "exec", "schema", "validate"],
                    "description": "Use query for row-returning statements, exec for writes, validate to prepare/check without executing, schema to inspect table columns and foreign keys, or auto to infer."
                ],
                "tables": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "For schema mode, optional table names to inspect. Empty means common Macrodex food tables."
                ]
            ],
            "required": ["purpose"]
        ]
    )

    public static let jsc = MacrodexAgentToolDefinition(
        name: "jsc",
        description: "Run JavaScriptCore script code with console output and optional SQL helper globals. Use sql.schema, sql.validate, and sql.transaction for database repair work. Include a short user-facing purpose.",
        inputSchema: [
            "type": "object",
            "properties": [
                "purpose": [
                    "type": "string",
                    "description": "Short present-tense user-facing purpose for this script."
                ],
                "script": [
                    "type": "string",
                    "description": "JavaScript source to execute."
                ],
                "argv": [
                    "type": "array",
                    "items": [
                        "type": "string"
                    ],
                    "description": "Optional string arguments exposed to the script."
                ]
            ],
            "required": ["purpose", "script"]
        ]
    )

    public static let webSearch = MacrodexAgentToolDefinition(
        name: "web_search",
        description: "Search the web and return concise result titles, URLs, and snippets.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Search query."
                ],
                "maxResults": [
                    "type": "number",
                    "description": "Maximum number of results to return."
                ]
            ],
            "required": ["query"]
        ]
    )
}

public struct MacrodexAgentToolCall: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: MacrodexAgentJSONValue

    public init(
        id: String,
        name: String,
        arguments: MacrodexAgentJSONValue = .object([:])
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct MacrodexAgentToolResult: Codable, Equatable, Sendable {
    public var callID: String
    public var output: MacrodexAgentJSONValue
    public var isError: Bool

    public init(
        callID: String,
        output: MacrodexAgentJSONValue,
        isError: Bool = false
    ) {
        self.callID = callID
        self.output = output
        self.isError = isError
    }
}

public struct MacrodexAgentUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public struct MacrodexAgentProviderConfiguration: Codable, Equatable, Sendable {
    public var id: String
    public var model: String
    public var descriptor: MacrodexAgentProviderDescriptor?

    public init(
        id: String,
        model: String,
        descriptor: MacrodexAgentProviderDescriptor? = nil
    ) {
        self.id = id
        self.model = model
        self.descriptor = descriptor
    }
}

public struct MacrodexAgentTurnRequest: Codable, Equatable, Sendable {
    public var threadID: String?
    public var input: [MacrodexAgentMessage]
    public var provider: MacrodexAgentProviderConfiguration
    public var tools: [MacrodexAgentToolDefinition]
    public var instructions: String?
    public var maxToolRounds: Int
    public var metadata: [String: MacrodexAgentJSONValue]

    public init(
        threadID: String? = nil,
        input: [MacrodexAgentMessage],
        provider: MacrodexAgentProviderConfiguration,
        tools: [MacrodexAgentToolDefinition] = [],
        instructions: String? = nil,
        maxToolRounds: Int = 4,
        metadata: [String: MacrodexAgentJSONValue] = [:]
    ) {
        self.threadID = threadID
        self.input = input
        self.provider = provider
        self.tools = tools
        self.instructions = instructions
        self.maxToolRounds = max(0, maxToolRounds)
        self.metadata = metadata
    }

    public init(
        threadID: String? = nil,
        prompt: String,
        providerID: String,
        model: String,
        tools: [MacrodexAgentToolDefinition] = [],
        instructions: String? = nil,
        maxToolRounds: Int = 4,
        metadata: [String: MacrodexAgentJSONValue] = [:]
    ) {
        self.init(
            threadID: threadID,
            input: [MacrodexAgentMessage(role: .user, content: prompt)],
            provider: MacrodexAgentProviderConfiguration(id: providerID, model: model),
            tools: tools,
            instructions: instructions,
            maxToolRounds: maxToolRounds,
            metadata: metadata
        )
    }
}

public struct MacrodexAgentProviderRequest: Codable, Equatable, Sendable {
    public var threadID: String
    public var providerID: String
    public var model: String
    public var messages: [MacrodexAgentMessage]
    public var tools: [MacrodexAgentToolDefinition]
    public var metadata: [String: MacrodexAgentJSONValue]

    public init(
        threadID: String,
        providerID: String,
        model: String,
        messages: [MacrodexAgentMessage],
        tools: [MacrodexAgentToolDefinition] = [],
        metadata: [String: MacrodexAgentJSONValue] = [:]
    ) {
        self.threadID = threadID
        self.providerID = providerID
        self.model = model
        self.messages = messages
        self.tools = tools
        self.metadata = metadata
    }
}

public struct MacrodexAgentProviderResponse: Codable, Equatable, Sendable {
    public var message: MacrodexAgentMessage?
    public var outputDeltas: [String]
    public var toolCalls: [MacrodexAgentToolCall]
    public var usage: MacrodexAgentUsage?

    public init(
        message: MacrodexAgentMessage? = nil,
        outputDeltas: [String] = [],
        toolCalls: [MacrodexAgentToolCall] = [],
        usage: MacrodexAgentUsage? = nil
    ) {
        self.message = message
        self.outputDeltas = outputDeltas
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

public struct MacrodexAgentProviderStreamEvent: Codable, Equatable, Sendable {
    public var type: String
    public var providerID: String
    public var threadID: String
    public var payload: [String: MacrodexAgentJSONValue]

    public init(
        type: String,
        providerID: String,
        threadID: String,
        payload: [String: MacrodexAgentJSONValue] = [:]
    ) {
        self.type = type
        self.providerID = providerID
        self.threadID = threadID
        self.payload = payload
    }
}

public typealias MacrodexAgentProviderStreamEventHandler = (MacrodexAgentProviderStreamEvent) -> Void

public struct MacrodexAgentRuntimeEvent: Codable, Equatable, Sendable {
    public var type: String
    public var threadID: String
    public var payload: [String: MacrodexAgentJSONValue]

    public init(
        type: String,
        threadID: String,
        payload: [String: MacrodexAgentJSONValue] = [:]
    ) {
        self.type = type
        self.threadID = threadID
        self.payload = payload
    }
}

public struct MacrodexAgentTurnResult: Codable, Equatable, Sendable {
    public var threadID: String
    public var messages: [MacrodexAgentMessage]
    public var finalMessage: MacrodexAgentMessage?
    public var events: [MacrodexAgentRuntimeEvent]
    public var usage: MacrodexAgentUsage?

    public init(
        threadID: String,
        messages: [MacrodexAgentMessage],
        finalMessage: MacrodexAgentMessage?,
        events: [MacrodexAgentRuntimeEvent],
        usage: MacrodexAgentUsage? = nil
    ) {
        self.threadID = threadID
        self.messages = messages
        self.finalMessage = finalMessage
        self.events = events
        self.usage = usage
    }
}

public struct MacrodexAgentThreadSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var messageCount: Int
    public var createdAtMilliseconds: Int64?
    public var updatedAtMilliseconds: Int64?
    public var lastMessage: MacrodexAgentMessage?
    public var messages: [MacrodexAgentMessage]?

    public init(
        id: String,
        messageCount: Int,
        createdAtMilliseconds: Int64? = nil,
        updatedAtMilliseconds: Int64? = nil,
        lastMessage: MacrodexAgentMessage? = nil,
        messages: [MacrodexAgentMessage]? = nil
    ) {
        self.id = id
        self.messageCount = messageCount
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.lastMessage = lastMessage
        self.messages = messages
    }
}

public struct MacrodexAgentModelInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var providerID: String
    public var displayName: String
    public var description: String
    public var supportedReasoningEfforts: [String]
    public var defaultReasoningEffort: String?
    public var inputModalities: [String]
    public var supportsTools: Bool
    public var supportsStreaming: Bool
    public var supportsChatGPTAuth: Bool
    public var hidden: Bool
    public var isDefault: Bool

    public init(
        id: String,
        providerID: String,
        displayName: String,
        description: String = "",
        supportedReasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil,
        inputModalities: [String] = ["text"],
        supportsTools: Bool = true,
        supportsStreaming: Bool = true,
        supportsChatGPTAuth: Bool = false,
        hidden: Bool = false,
        isDefault: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.description = description
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.inputModalities = inputModalities
        self.supportsTools = supportsTools
        self.supportsStreaming = supportsStreaming
        self.supportsChatGPTAuth = supportsChatGPTAuth
        self.hidden = hidden
        self.isDefault = isDefault
    }
}

public struct MacrodexAgentModelCatalog: Codable, Equatable, Sendable {
    public var providerID: String
    public var models: [MacrodexAgentModelInfo]

    public init(providerID: String, models: [MacrodexAgentModelInfo]) {
        self.providerID = providerID
        self.models = models
    }

    public var visibleModels: [MacrodexAgentModelInfo] {
        models.filter { !$0.hidden }
    }

    public var defaultModel: MacrodexAgentModelInfo? {
        visibleModels.first(where: \.isDefault) ?? visibleModels.first
    }

    public func model(id: String) -> MacrodexAgentModelInfo? {
        models.first { $0.id == id }
    }
}

public enum MacrodexAgentBuiltInModelCatalogs {
    public static let chatGPTCodex = MacrodexAgentModelCatalog(
        providerID: MacrodexAgentBuiltInProviderRegistry.openAI.id,
        models: [
            MacrodexAgentModelInfo(
                id: "gpt-5.5",
                providerID: MacrodexAgentBuiltInProviderRegistry.openAI.id,
                displayName: "GPT-5.5",
                description: "Frontier ChatGPT Codex model.",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium",
                inputModalities: ["text", "image"],
                supportsChatGPTAuth: true
            ),
            MacrodexAgentModelInfo(
                id: "gpt-5.4",
                providerID: MacrodexAgentBuiltInProviderRegistry.openAI.id,
                displayName: "GPT-5.4",
                description: "Strong general-purpose ChatGPT Codex model.",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium",
                inputModalities: ["text", "image"],
                supportsChatGPTAuth: true
            ),
            MacrodexAgentModelInfo(
                id: "gpt-5.4-mini",
                providerID: MacrodexAgentBuiltInProviderRegistry.openAI.id,
                displayName: "GPT-5.4 Mini",
                description: "Smaller fast ChatGPT Codex model.",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium",
                inputModalities: ["text", "image"],
                supportsChatGPTAuth: true,
                isDefault: true
            ),
            MacrodexAgentModelInfo(
                id: "gpt-5.3-codex",
                providerID: MacrodexAgentBuiltInProviderRegistry.openAI.id,
                displayName: "GPT-5.3 Codex",
                description: "Coding-optimized ChatGPT Codex model.",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium",
                inputModalities: ["text", "image"],
                supportsChatGPTAuth: true
            ),
            MacrodexAgentModelInfo(
                id: "gpt-5.3-codex-spark",
                providerID: MacrodexAgentBuiltInProviderRegistry.openAI.id,
                displayName: "GPT-5.3 Codex Spark",
                description: "Ultra-fast coding model available through ChatGPT Codex.",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "high",
                supportsChatGPTAuth: true,
                hidden: true
            ),
            MacrodexAgentModelInfo(
                id: "gpt-5.2",
                providerID: MacrodexAgentBuiltInProviderRegistry.openAI.id,
                displayName: "GPT-5.2",
                description: "Long-running professional work model.",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium",
                supportsChatGPTAuth: true
            )
        ]
    )

    public static let googleAI = MacrodexAgentModelCatalog(
        providerID: MacrodexAgentBuiltInProviderRegistry.google.id,
        models: [
            MacrodexAgentModelInfo(
                id: "google/gemini-2.5-flash",
                providerID: MacrodexAgentBuiltInProviderRegistry.google.id,
                displayName: "Gemini 2.5 Flash",
                description: "Fast multimodal Google AI model.",
                inputModalities: ["text", "image"],
                supportsStreaming: false,
                isDefault: true
            ),
            MacrodexAgentModelInfo(
                id: "google/gemini-2.5-pro",
                providerID: MacrodexAgentBuiltInProviderRegistry.google.id,
                displayName: "Gemini 2.5 Pro",
                description: "Higher-capability multimodal Google AI model.",
                inputModalities: ["text", "image"],
                supportsStreaming: false
            ),
            MacrodexAgentModelInfo(
                id: "google/gemini-2.0-flash",
                providerID: MacrodexAgentBuiltInProviderRegistry.google.id,
                displayName: "Gemini 2.0 Flash",
                description: "General-purpose multimodal Google AI model.",
                inputModalities: ["text", "image"],
                supportsStreaming: false
            )
        ]
    )

    public static let foundationModels = MacrodexAgentModelCatalog(
        providerID: MacrodexAgentBuiltInProviderRegistry.foundationModels.id,
        models: [
            MacrodexAgentModelInfo(
                id: "system",
                providerID: MacrodexAgentBuiltInProviderRegistry.foundationModels.id,
                displayName: "System",
                description: "Apple Foundation Models on-device model. No ChatGPT login required.",
                supportsTools: false,
                supportsStreaming: true,
                isDefault: true
            ),
            MacrodexAgentModelInfo(
                id: "pcc",
                providerID: MacrodexAgentBuiltInProviderRegistry.foundationModels.id,
                displayName: "PCC",
                description: "Apple Foundation Models Private Cloud Compute model when available on this OS.",
                supportedReasoningEfforts: ["low", "medium", "high"],
                defaultReasoningEffort: "medium",
                supportsTools: false,
                supportsStreaming: true
            )
        ]
    )
}

public struct MacrodexAgentRuntimeCapabilities: Codable, Equatable, Sendable {
    public var runtime: String
    public var engine: String
    public var version: String
    public var supportsPersistentThreads: Bool
    public var supportsNativeProviderHooks: Bool
    public var supportsNativeToolHooks: Bool
    public var supportsEventStreaming: Bool
    public var supportsThreadSnapshots: Bool
    public var supportsModelCatalogs: Bool
    public var supportedTransports: [String]

    public init(
        runtime: String,
        engine: String,
        version: String,
        supportsPersistentThreads: Bool,
        supportsNativeProviderHooks: Bool,
        supportsNativeToolHooks: Bool,
        supportsEventStreaming: Bool = false,
        supportsThreadSnapshots: Bool = false,
        supportsModelCatalogs: Bool = false,
        supportedTransports: [String]
    ) {
        self.runtime = runtime
        self.engine = engine
        self.version = version
        self.supportsPersistentThreads = supportsPersistentThreads
        self.supportsNativeProviderHooks = supportsNativeProviderHooks
        self.supportsNativeToolHooks = supportsNativeToolHooks
        self.supportsEventStreaming = supportsEventStreaming
        self.supportsThreadSnapshots = supportsThreadSnapshots
        self.supportsModelCatalogs = supportsModelCatalogs
        self.supportedTransports = supportedTransports
    }
}
