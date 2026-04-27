import Foundation

// Pi-only replacement for the former generated bridge.
// Keep these app-facing value types and overrideable bridge classes, but do
// not import or call any external runtime symbols.

enum LocalBridgeError: Error, LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let operation):
            return "\(operation) is only available through the Pi runtime."
        }
    }
}

private func unsupported<T>(_ operation: String) throws -> T {
    throw LocalBridgeError.unsupported(operation)
}

struct AbsolutePath: Equatable, Hashable {
    var value: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(value: String) {
        self.value = value
    }




}

struct AppActivityByDayEntry: Equatable, Hashable {
    var dateEpoch: Int64
    var turnCount: UInt32

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(dateEpoch: Int64, turnCount: UInt32) {
        self.dateEpoch = dateEpoch
        self.turnCount = turnCount
    }




}

struct AppAppendRealtimeAudioRequest: Equatable, Hashable {
    var threadId: String
    var audio: AppRealtimeAudioChunk

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, audio: AppRealtimeAudioChunk) {
        self.threadId = threadId
        self.audio = audio
    }




}

struct AppAppendRealtimeTextRequest: Equatable, Hashable {
    var threadId: String
    var text: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, text: String) {
        self.threadId = threadId
        self.text = text
    }




}

struct AppArchiveThreadRequest: Equatable, Hashable {
    var threadId: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String) {
        self.threadId = threadId
    }




}

struct AppByteRange: Equatable, Hashable {
    var start: UInt64
    var end: UInt64

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(start: UInt64, end: UInt64) {
        self.start = start
        self.end = end
    }




}

struct AppCodeReviewCodeLocation: Equatable, Hashable {
    var absoluteFilePath: String
    var lineRange: AppCodeReviewLineRange?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(absoluteFilePath: String, lineRange: AppCodeReviewLineRange?) {
        self.absoluteFilePath = absoluteFilePath
        self.lineRange = lineRange
    }




}

struct AppCodeReviewFinding: Equatable, Hashable {
    var title: String
    var body: String
    var confidenceScore: Double
    var priority: UInt8?
    var codeLocation: AppCodeReviewCodeLocation?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(title: String, body: String, confidenceScore: Double, priority: UInt8?, codeLocation: AppCodeReviewCodeLocation?) {
        self.title = title
        self.body = body
        self.confidenceScore = confidenceScore
        self.priority = priority
        self.codeLocation = codeLocation
    }




}

struct AppCodeReviewLineRange: Equatable, Hashable {
    var start: UInt32
    var end: UInt32

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(start: UInt32, end: UInt32) {
        self.start = start
        self.end = end
    }




}

struct AppCodeReviewPayload: Equatable, Hashable {
    var findings: [AppCodeReviewFinding]
    var overallCorrectness: String?
    var overallExplanation: String?
    var overallConfidenceScore: Double?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(findings: [AppCodeReviewFinding], overallCorrectness: String?, overallExplanation: String?, overallConfidenceScore: Double?) {
        self.findings = findings
        self.overallCorrectness = overallCorrectness
        self.overallExplanation = overallExplanation
        self.overallConfidenceScore = overallConfidenceScore
    }




}

struct AppCollaborationModePreset: Equatable, Hashable {
    var kind: AppModeKind
    var name: String
    var model: String?
    var reasoningEffort: ReasoningEffort?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(kind: AppModeKind, name: String, model: String?, reasoningEffort: ReasoningEffort?) {
        self.kind = kind
        self.name = name
        self.model = model
        self.reasoningEffort = reasoningEffort
    }




}

struct AppConnectionProgressSnapshot: Equatable, Hashable {
    var steps: [AppConnectionStepSnapshot]
    var pendingInstall: Bool
    var terminalMessage: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(steps: [AppConnectionStepSnapshot], pendingInstall: Bool, terminalMessage: String?) {
        self.steps = steps
        self.pendingInstall = pendingInstall
        self.terminalMessage = terminalMessage
    }




}

struct AppConnectionStepSnapshot: Equatable, Hashable {
    var kind: AppConnectionStepKind
    var state: AppConnectionStepState
    var detail: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(kind: AppConnectionStepKind, state: AppConnectionStepState, detail: String?) {
        self.kind = kind
        self.state = state
        self.detail = detail
    }




}

struct AppConversationStats: Equatable, Hashable {
    var totalMessages: UInt32
    var userMessageCount: UInt32
    var assistantMessageCount: UInt32
    var turnCount: UInt32
    var commandsExecuted: UInt32
    var commandsSucceeded: UInt32
    var commandsFailed: UInt32
    var totalCommandDurationMs: Int64
    var filesChanged: UInt32
    var filesAdded: UInt32
    var filesModified: UInt32
    var filesDeleted: UInt32
    var diffAdditions: UInt32
    var diffDeletions: UInt32
    var toolCallCount: UInt32
    var mcpToolCallCount: UInt32
    var dynamicToolCallCount: UInt32
    var webSearchCount: UInt32
    var imageCount: UInt32
    var codeReviewCount: UInt32
    var widgetCount: UInt32
    var sessionDurationMs: Int64?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(totalMessages: UInt32, userMessageCount: UInt32, assistantMessageCount: UInt32, turnCount: UInt32, commandsExecuted: UInt32, commandsSucceeded: UInt32, commandsFailed: UInt32, totalCommandDurationMs: Int64, filesChanged: UInt32, filesAdded: UInt32, filesModified: UInt32, filesDeleted: UInt32, diffAdditions: UInt32, diffDeletions: UInt32, toolCallCount: UInt32, mcpToolCallCount: UInt32, dynamicToolCallCount: UInt32, webSearchCount: UInt32, imageCount: UInt32, codeReviewCount: UInt32, widgetCount: UInt32, sessionDurationMs: Int64?) {
        self.totalMessages = totalMessages
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.turnCount = turnCount
        self.commandsExecuted = commandsExecuted
        self.commandsSucceeded = commandsSucceeded
        self.commandsFailed = commandsFailed
        self.totalCommandDurationMs = totalCommandDurationMs
        self.filesChanged = filesChanged
        self.filesAdded = filesAdded
        self.filesModified = filesModified
        self.filesDeleted = filesDeleted
        self.diffAdditions = diffAdditions
        self.diffDeletions = diffDeletions
        self.toolCallCount = toolCallCount
        self.mcpToolCallCount = mcpToolCallCount
        self.dynamicToolCallCount = dynamicToolCallCount
        self.webSearchCount = webSearchCount
        self.imageCount = imageCount
        self.codeReviewCount = codeReviewCount
        self.widgetCount = widgetCount
        self.sessionDurationMs = sessionDurationMs
    }




}

struct AppDiscoveredServer: Equatable, Hashable {
    var id: String
    var displayName: String
    var host: String
    var port: UInt16
    var codexPort: UInt16?
    var codexPorts: [UInt16]
    var sshPort: UInt16?
    var source: AppDiscoverySource
    var reachable: Bool
    var os: String?
    var sshBanner: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(id: String, displayName: String, host: String, port: UInt16, codexPort: UInt16?, codexPorts: [UInt16], sshPort: UInt16?, source: AppDiscoverySource, reachable: Bool, os: String?, sshBanner: String?) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.codexPort = codexPort
        self.codexPorts = codexPorts
        self.sshPort = sshPort
        self.source = source
        self.reachable = reachable
        self.os = os
        self.sshBanner = sshBanner
    }




}

struct AppDynamicToolSpec: Equatable, Hashable {
    var name: String
    var description: String
    /**
     * JSON-encoded input schema string.
     */
    var inputSchemaJson: String
    var deferLoading: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(name: String, description: String,
        /**
         * JSON-encoded input schema string.
         */inputSchemaJson: String, deferLoading: Bool = false) {
        self.name = name
        self.description = description
        self.inputSchemaJson = inputSchemaJson
        self.deferLoading = deferLoading
    }




}

struct AppExecCommandRequest: Equatable, Hashable {
    var command: [String]
    var processId: String?
    var tty: Bool
    var streamStdin: Bool
    var streamStdoutStderr: Bool
    var outputBytesCap: UInt64?
    var disableOutputCap: Bool
    var disableTimeout: Bool
    var timeoutMs: Int64?
    var cwd: String?
    var sandboxPolicy: AppSandboxPolicy?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(command: [String], processId: String?, tty: Bool, streamStdin: Bool, streamStdoutStderr: Bool, outputBytesCap: UInt64?, disableOutputCap: Bool, disableTimeout: Bool, timeoutMs: Int64?, cwd: String?, sandboxPolicy: AppSandboxPolicy?) {
        self.command = command
        self.processId = processId
        self.tty = tty
        self.streamStdin = streamStdin
        self.streamStdoutStderr = streamStdoutStderr
        self.outputBytesCap = outputBytesCap
        self.disableOutputCap = disableOutputCap
        self.disableTimeout = disableTimeout
        self.timeoutMs = timeoutMs
        self.cwd = cwd
        self.sandboxPolicy = sandboxPolicy
    }




}

struct AppFinalizeRealtimeHandoffRequest: Equatable, Hashable {
    var threadId: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String) {
        self.threadId = threadId
    }




}

struct AppForkThreadFromMessageRequest: Equatable, Hashable {
    var model: String?
    var cwd: String?
    var approvalPolicy: AppAskForApproval?
    var sandbox: AppSandboxMode?
    var developerInstructions: String?
    var persistExtendedHistory: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(model: String?, cwd: String?, approvalPolicy: AppAskForApproval?, sandbox: AppSandboxMode?, developerInstructions: String?, persistExtendedHistory: Bool) {
        self.model = model
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.developerInstructions = developerInstructions
        self.persistExtendedHistory = persistExtendedHistory
    }




}

struct AppForkThreadRequest: Equatable, Hashable {
    var threadId: String
    var model: String?
    var cwd: String?
    var approvalPolicy: AppAskForApproval?
    var sandbox: AppSandboxMode?
    var developerInstructions: String?
    var persistExtendedHistory: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, model: String?, cwd: String?, approvalPolicy: AppAskForApproval?, sandbox: AppSandboxMode?, developerInstructions: String?, persistExtendedHistory: Bool) {
        self.threadId = threadId
        self.model = model
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.developerInstructions = developerInstructions
        self.persistExtendedHistory = persistExtendedHistory
    }




}

struct AppInterruptTurnRequest: Equatable, Hashable {
    var threadId: String
    var turnId: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, turnId: String) {
        self.threadId = threadId
        self.turnId = turnId
    }




}

struct AppListSkillsRequest: Equatable, Hashable {
    var cwds: [String]
    var forceReload: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(cwds: [String], forceReload: Bool) {
        self.cwds = cwds
        self.forceReload = forceReload
    }




}

struct AppListThreadsRequest: Equatable, Hashable {
    var cursor: String?
    var limit: UInt32?
    var archived: Bool?
    var cwd: String?
    var searchTerm: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(cursor: String? = nil, limit: UInt32? = nil, archived: Bool? = nil, cwd: String? = nil, searchTerm: String? = nil) {
        self.cursor = cursor
        self.limit = limit
        self.archived = archived
        self.cwd = cwd
        self.searchTerm = searchTerm
    }




}

struct AppMdnsSeed: Equatable, Hashable {
    var name: String
    var host: String
    var port: UInt16?
    var serviceType: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(name: String, host: String, port: UInt16?, serviceType: String) {
        self.name = name
        self.host = host
        self.port = port
        self.serviceType = serviceType
    }




}

struct AppModelUsageEntry: Equatable, Hashable {
    var model: String
    var threadCount: UInt32

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(model: String, threadCount: UInt32) {
        self.model = model
        self.threadCount = threadCount
    }




}

struct AppPlanImplementationPromptSnapshot: Equatable, Hashable {
    var sourceTurnId: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(sourceTurnId: String) {
        self.sourceTurnId = sourceTurnId
    }




}

struct AppPlanProgressSnapshot: Equatable, Hashable {
    var turnId: String
    var explanation: String?
    var plan: [AppPlanStep]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(turnId: String, explanation: String?, plan: [AppPlanStep]) {
        self.turnId = turnId
        self.explanation = explanation
        self.plan = plan
    }




}

struct AppPlanStep: Equatable, Hashable {
    var step: String
    var status: AppPlanStepStatus

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(step: String, status: AppPlanStepStatus) {
        self.step = step
        self.status = status
    }




}

struct AppProgressiveDiscoveryUpdate: Equatable, Hashable {
    var kind: ProgressiveDiscoveryUpdateKind
    var source: AppDiscoverySource?
    var servers: [AppDiscoveredServer]
    /**
     * Overall scan progress from 0.0 to 1.0.
     */
    var progress: Float
    /**
     * Human-readable label for the phase that just completed.
     */
    var progressLabel: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(kind: ProgressiveDiscoveryUpdateKind, source: AppDiscoverySource?, servers: [AppDiscoveredServer],
        /**
         * Overall scan progress from 0.0 to 1.0.
         */progress: Float,
        /**
         * Human-readable label for the phase that just completed.
         */progressLabel: String?) {
        self.kind = kind
        self.source = source
        self.servers = servers
        self.progress = progress
        self.progressLabel = progressLabel
    }




}

struct AppProject: Equatable, Hashable {
    var id: String
    var serverId: String
    var cwd: String
    var lastUsedAtMs: Int64?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(id: String, serverId: String, cwd: String, lastUsedAtMs: Int64?) {
        self.id = id
        self.serverId = serverId
        self.cwd = cwd
        self.lastUsedAtMs = lastUsedAtMs
    }




}

struct AppQueuedFollowUpPreview: Equatable, Hashable {
    var id: String
    var kind: AppQueuedFollowUpKind
    var text: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(id: String, kind: AppQueuedFollowUpKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }




}

struct AppReadThreadRequest: Equatable, Hashable {
    var threadId: String
    var includeTurns: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, includeTurns: Bool) {
        self.threadId = threadId
        self.includeTurns = includeTurns
    }




}

struct AppRealtimeAudioChunk: Equatable, Hashable {
    var data: String
    var sampleRate: UInt32
    var numChannels: UInt32
    var samplesPerChannel: UInt32?
    var itemId: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(data: String, sampleRate: UInt32, numChannels: UInt32, samplesPerChannel: UInt32? = nil, itemId: String? = nil) {
        self.data = data
        self.sampleRate = sampleRate
        self.numChannels = numChannels
        self.samplesPerChannel = samplesPerChannel
        self.itemId = itemId
    }




}

struct AppRealtimeClosedNotification: Equatable, Hashable {
    var threadId: String
    var reason: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, reason: String? = nil) {
        self.threadId = threadId
        self.reason = reason
    }




}

struct AppRealtimeErrorNotification: Equatable, Hashable {
    var threadId: String
    var message: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, message: String) {
        self.threadId = threadId
        self.message = message
    }




}

struct AppRealtimeOutputAudioDeltaNotification: Equatable, Hashable {
    var threadId: String
    var audio: AppRealtimeAudioChunk

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, audio: AppRealtimeAudioChunk) {
        self.threadId = threadId
        self.audio = audio
    }




}

struct AppRealtimeStartedNotification: Equatable, Hashable {
    var threadId: String
    var sessionId: String?
    var version: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, sessionId: String? = nil, version: String) {
        self.threadId = threadId
        self.sessionId = sessionId
        self.version = version
    }




}

struct AppRefreshAccountRequest: Equatable, Hashable {
    var refreshToken: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(refreshToken: Bool) {
        self.refreshToken = refreshToken
    }




}

struct AppRefreshModelsRequest: Equatable, Hashable {
    var cursor: String?
    var limit: UInt32?
    var includeHidden: Bool?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(cursor: String? = nil, limit: UInt32? = nil, includeHidden: Bool? = nil) {
        self.cursor = cursor
        self.limit = limit
        self.includeHidden = includeHidden
    }




}

struct AppRenameThreadRequest: Equatable, Hashable {
    var threadId: String
    var name: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, name: String) {
        self.threadId = threadId
        self.name = name
    }




}

struct AppResolveRealtimeHandoffRequest: Equatable, Hashable {
    var threadId: String
    var toolCallOutput: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, toolCallOutput: String) {
        self.threadId = threadId
        self.toolCallOutput = toolCallOutput
    }




}

struct AppResumeThreadRequest: Equatable, Hashable {
    var threadId: String
    var model: String?
    var cwd: String?
    var approvalPolicy: AppAskForApproval?
    var sandbox: AppSandboxMode?
    var developerInstructions: String?
    var persistExtendedHistory: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, model: String?, cwd: String?, approvalPolicy: AppAskForApproval?, sandbox: AppSandboxMode?, developerInstructions: String?, persistExtendedHistory: Bool) {
        self.threadId = threadId
        self.model = model
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.developerInstructions = developerInstructions
        self.persistExtendedHistory = persistExtendedHistory
    }




}

struct AppSearchFilesRequest: Equatable, Hashable {
    var query: String
    var roots: [String]
    var cancellationToken: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(query: String, roots: [String], cancellationToken: String?) {
        self.query = query
        self.roots = roots
        self.cancellationToken = cancellationToken
    }




}

struct AppServerCapabilities: Equatable, Hashable {
    var canUseTransportActions: Bool
    var canBrowseDirectories: Bool
    var canStartThreads: Bool
    var canResumeThreads: Bool
    var canUseIpc: Bool
    var canResumeViaIpc: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(canUseTransportActions: Bool, canBrowseDirectories: Bool, canStartThreads: Bool, canResumeThreads: Bool, canUseIpc: Bool, canResumeViaIpc: Bool) {
        self.canUseTransportActions = canUseTransportActions
        self.canBrowseDirectories = canBrowseDirectories
        self.canStartThreads = canStartThreads
        self.canResumeThreads = canResumeThreads
        self.canUseIpc = canUseIpc
        self.canResumeViaIpc = canResumeViaIpc
    }




}

struct AppServerSnapshot: Equatable, Hashable {
    var serverId: String
    var displayName: String
    var host: String
    var port: UInt16
    var wakeMac: String?
    var isLocal: Bool
    var supportsIpc: Bool
    var hasIpc: Bool
    var health: AppServerHealth
    var transportState: AppServerTransportState
    var ipcState: AppServerIpcState
    var capabilities: AppServerCapabilities
    var account: Account?
    var requiresOpenaiAuth: Bool
    var rateLimits: RateLimitSnapshot?
    var availableModels: [ModelInfo]?
    var connectionProgress: AppConnectionProgressSnapshot?
    var usageStats: AppServerUsageStats?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(serverId: String, displayName: String, host: String, port: UInt16, wakeMac: String?, isLocal: Bool, supportsIpc: Bool, hasIpc: Bool, health: AppServerHealth, transportState: AppServerTransportState, ipcState: AppServerIpcState, capabilities: AppServerCapabilities, account: Account?, requiresOpenaiAuth: Bool, rateLimits: RateLimitSnapshot?, availableModels: [ModelInfo]?, connectionProgress: AppConnectionProgressSnapshot?, usageStats: AppServerUsageStats?) {
        self.serverId = serverId
        self.displayName = displayName
        self.host = host
        self.port = port
        self.wakeMac = wakeMac
        self.isLocal = isLocal
        self.supportsIpc = supportsIpc
        self.hasIpc = hasIpc
        self.health = health
        self.transportState = transportState
        self.ipcState = ipcState
        self.capabilities = capabilities
        self.account = account
        self.requiresOpenaiAuth = requiresOpenaiAuth
        self.rateLimits = rateLimits
        self.availableModels = availableModels
        self.connectionProgress = connectionProgress
        self.usageStats = usageStats
    }




}

struct AppServerUsageStats: Equatable, Hashable {
    var totalThreads: UInt32
    var activeThreads: UInt32
    var totalTokens: UInt64
    var tokensByThread: [AppTokensByThreadEntry]
    var activityByDay: [AppActivityByDayEntry]
    var modelUsage: [AppModelUsageEntry]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(totalThreads: UInt32, activeThreads: UInt32, totalTokens: UInt64, tokensByThread: [AppTokensByThreadEntry], activityByDay: [AppActivityByDayEntry], modelUsage: [AppModelUsageEntry]) {
        self.totalThreads = totalThreads
        self.activeThreads = activeThreads
        self.totalTokens = totalTokens
        self.tokensByThread = tokensByThread
        self.activityByDay = activityByDay
        self.modelUsage = modelUsage
    }




}

struct AppSessionSummary: Equatable, Hashable {
    var key: ThreadKey
    var serverDisplayName: String
    var serverHost: String
    var title: String
    var preview: String
    var cwd: String
    var model: String
    var modelProvider: String
    var parentThreadId: String?
    var agentNickname: String?
    var agentRole: String?
    var agentDisplayLabel: String?
    var agentStatus: AppSubagentStatus
    var updatedAt: Int64?
    var hasActiveTurn: Bool
    var isSubagent: Bool
    var isFork: Bool
    var lastResponsePreview: String?
    var lastResponseTurnId: String?
    var lastUserMessage: String?
    var lastToolLabel: String?
    var recentToolLog: [AppToolLogEntry]
    var lastTurnStartMs: Int64?
    var lastTurnEndMs: Int64?
    var stats: AppConversationStats?
    var tokenUsage: AppTokenUsage?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(key: ThreadKey, serverDisplayName: String, serverHost: String, title: String, preview: String, cwd: String, model: String, modelProvider: String, parentThreadId: String?, agentNickname: String?, agentRole: String?, agentDisplayLabel: String?, agentStatus: AppSubagentStatus, updatedAt: Int64?, hasActiveTurn: Bool, isSubagent: Bool, isFork: Bool, lastResponsePreview: String?, lastResponseTurnId: String?, lastUserMessage: String?, lastToolLabel: String?, recentToolLog: [AppToolLogEntry], lastTurnStartMs: Int64?, lastTurnEndMs: Int64?, stats: AppConversationStats?, tokenUsage: AppTokenUsage?) {
        self.key = key
        self.serverDisplayName = serverDisplayName
        self.serverHost = serverHost
        self.title = title
        self.preview = preview
        self.cwd = cwd
        self.model = model
        self.modelProvider = modelProvider
        self.parentThreadId = parentThreadId
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.agentDisplayLabel = agentDisplayLabel
        self.agentStatus = agentStatus
        self.updatedAt = updatedAt
        self.hasActiveTurn = hasActiveTurn
        self.isSubagent = isSubagent
        self.isFork = isFork
        self.lastResponsePreview = lastResponsePreview
        self.lastResponseTurnId = lastResponseTurnId
        self.lastUserMessage = lastUserMessage
        self.lastToolLabel = lastToolLabel
        self.recentToolLog = recentToolLog
        self.lastTurnStartMs = lastTurnStartMs
        self.lastTurnEndMs = lastTurnEndMs
        self.stats = stats
        self.tokenUsage = tokenUsage
    }




}

struct AppSnapshotRecord: Equatable, Hashable {
    var servers: [AppServerSnapshot]
    var threads: [AppThreadSnapshot]
    var sessionSummaries: [AppSessionSummary]
    var agentDirectoryVersion: UInt64
    var activeThread: ThreadKey?
    var pendingApprovals: [PendingApproval]
    var pendingUserInputs: [PendingUserInputRequest]
    var voiceSession: AppVoiceSessionSnapshot

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(servers: [AppServerSnapshot], threads: [AppThreadSnapshot], sessionSummaries: [AppSessionSummary], agentDirectoryVersion: UInt64, activeThread: ThreadKey?, pendingApprovals: [PendingApproval], pendingUserInputs: [PendingUserInputRequest], voiceSession: AppVoiceSessionSnapshot) {
        self.servers = servers
        self.threads = threads
        self.sessionSummaries = sessionSummaries
        self.agentDirectoryVersion = agentDirectoryVersion
        self.activeThread = activeThread
        self.pendingApprovals = pendingApprovals
        self.pendingUserInputs = pendingUserInputs
        self.voiceSession = voiceSession
    }




}

struct AppSshConnectionResult: Equatable, Hashable {
    var sessionId: String
    var normalizedHost: String
    var serverPort: UInt16
    var tunnelLocalPort: UInt16?
    var serverVersion: String?
    var pid: UInt32?
    var wakeMac: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(sessionId: String, normalizedHost: String, serverPort: UInt16, tunnelLocalPort: UInt16?, serverVersion: String?, pid: UInt32?, wakeMac: String?) {
        self.sessionId = sessionId
        self.normalizedHost = normalizedHost
        self.serverPort = serverPort
        self.tunnelLocalPort = tunnelLocalPort
        self.serverVersion = serverVersion
        self.pid = pid
        self.wakeMac = wakeMac
    }




}

struct AppStartRealtimeSessionRequest: Equatable, Hashable {
    var threadId: String
    var prompt: String
    var sessionId: String?
    var outputModality: AppRealtimeOutputModality?
    var transport: AppRealtimeStartTransport?
    var voice: AppRealtimeVoice?
    var clientControlledHandoff: Bool
    var dynamicTools: [AppDynamicToolSpec]?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, prompt: String, sessionId: String?, outputModality: AppRealtimeOutputModality? = nil, transport: AppRealtimeStartTransport? = nil, voice: AppRealtimeVoice? = nil, clientControlledHandoff: Bool, dynamicTools: [AppDynamicToolSpec]?) {
        self.threadId = threadId
        self.prompt = prompt
        self.sessionId = sessionId
        self.outputModality = outputModality
        self.transport = transport
        self.voice = voice
        self.clientControlledHandoff = clientControlledHandoff
        self.dynamicTools = dynamicTools
    }




}

struct AppStartReviewRequest: Equatable, Hashable {
    var threadId: String
    var target: AppReviewTarget
    var delivery: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, target: AppReviewTarget, delivery: String?) {
        self.threadId = threadId
        self.target = target
        self.delivery = delivery
    }




}

struct AppStartThreadRequest: Equatable, Hashable {
    var model: String?
    var cwd: String?
    var approvalPolicy: AppAskForApproval?
    var sandbox: AppSandboxMode?
    var developerInstructions: String?
    var persistExtendedHistory: Bool
    var dynamicTools: [AppDynamicToolSpec]?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(model: String?, cwd: String?, approvalPolicy: AppAskForApproval?, sandbox: AppSandboxMode?, developerInstructions: String?, persistExtendedHistory: Bool, dynamicTools: [AppDynamicToolSpec]?) {
        self.model = model
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.developerInstructions = developerInstructions
        self.persistExtendedHistory = persistExtendedHistory
        self.dynamicTools = dynamicTools
    }




}

struct AppStartTurnRequest: Equatable, Hashable {
    var threadId: String
    var input: [AppUserInput]
    var approvalPolicy: AppAskForApproval?
    var sandboxPolicy: AppSandboxPolicy?
    var model: String?
    var serviceTier: ServiceTier?
    var effort: ReasoningEffort?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String, input: [AppUserInput], approvalPolicy: AppAskForApproval?, sandboxPolicy: AppSandboxPolicy?, model: String?, serviceTier: ServiceTier?, effort: ReasoningEffort?) {
        self.threadId = threadId
        self.input = input
        self.approvalPolicy = approvalPolicy
        self.sandboxPolicy = sandboxPolicy
        self.model = model
        self.serviceTier = serviceTier
        self.effort = effort
    }




}

struct AppStopRealtimeSessionRequest: Equatable, Hashable {
    var threadId: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadId: String) {
        self.threadId = threadId
    }




}

struct AppTextElement: Equatable, Hashable {
    var byteRange: AppByteRange

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(byteRange: AppByteRange) {
        self.byteRange = byteRange
    }




}

struct AppThreadSnapshot: Equatable, Hashable {
    var key: ThreadKey
    var info: ThreadInfo
    var collaborationMode: AppModeKind
    var model: String?
    var reasoningEffort: String?
    var effectiveApprovalPolicy: AppAskForApproval?
    var effectiveSandboxPolicy: AppSandboxPolicy?
    var hydratedConversationItems: [HydratedConversationItem]
    var queuedFollowUps: [AppQueuedFollowUpPreview]
    var activeTurnId: String?
    var activePlanProgress: AppPlanProgressSnapshot?
    var pendingPlanImplementationPrompt: AppPlanImplementationPromptSnapshot?
    var contextTokensUsed: UInt64?
    var modelContextWindow: UInt64?
    var rateLimits: RateLimits?
    var realtimeSessionId: String?
    var stats: AppConversationStats?
    var tokenUsage: AppTokenUsage?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(key: ThreadKey, info: ThreadInfo, collaborationMode: AppModeKind, model: String?, reasoningEffort: String?, effectiveApprovalPolicy: AppAskForApproval?, effectiveSandboxPolicy: AppSandboxPolicy?, hydratedConversationItems: [HydratedConversationItem], queuedFollowUps: [AppQueuedFollowUpPreview], activeTurnId: String?, activePlanProgress: AppPlanProgressSnapshot?, pendingPlanImplementationPrompt: AppPlanImplementationPromptSnapshot?, contextTokensUsed: UInt64?, modelContextWindow: UInt64?, rateLimits: RateLimits?, realtimeSessionId: String?, stats: AppConversationStats?, tokenUsage: AppTokenUsage?) {
        self.key = key
        self.info = info
        self.collaborationMode = collaborationMode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.effectiveApprovalPolicy = effectiveApprovalPolicy
        self.effectiveSandboxPolicy = effectiveSandboxPolicy
        self.hydratedConversationItems = hydratedConversationItems
        self.queuedFollowUps = queuedFollowUps
        self.activeTurnId = activeTurnId
        self.activePlanProgress = activePlanProgress
        self.pendingPlanImplementationPrompt = pendingPlanImplementationPrompt
        self.contextTokensUsed = contextTokensUsed
        self.modelContextWindow = modelContextWindow
        self.rateLimits = rateLimits
        self.realtimeSessionId = realtimeSessionId
        self.stats = stats
        self.tokenUsage = tokenUsage
    }




}

struct AppThreadStateRecord: Equatable, Hashable {
    var key: ThreadKey
    var info: ThreadInfo
    var collaborationMode: AppModeKind
    var model: String?
    var reasoningEffort: String?
    var effectiveApprovalPolicy: AppAskForApproval?
    var effectiveSandboxPolicy: AppSandboxPolicy?
    var queuedFollowUps: [AppQueuedFollowUpPreview]
    var activeTurnId: String?
    var activePlanProgress: AppPlanProgressSnapshot?
    var pendingPlanImplementationPrompt: AppPlanImplementationPromptSnapshot?
    var contextTokensUsed: UInt64?
    var modelContextWindow: UInt64?
    var rateLimits: RateLimits?
    var realtimeSessionId: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(key: ThreadKey, info: ThreadInfo, collaborationMode: AppModeKind, model: String?, reasoningEffort: String?, effectiveApprovalPolicy: AppAskForApproval?, effectiveSandboxPolicy: AppSandboxPolicy?, queuedFollowUps: [AppQueuedFollowUpPreview], activeTurnId: String?, activePlanProgress: AppPlanProgressSnapshot?, pendingPlanImplementationPrompt: AppPlanImplementationPromptSnapshot?, contextTokensUsed: UInt64?, modelContextWindow: UInt64?, rateLimits: RateLimits?, realtimeSessionId: String?) {
        self.key = key
        self.info = info
        self.collaborationMode = collaborationMode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.effectiveApprovalPolicy = effectiveApprovalPolicy
        self.effectiveSandboxPolicy = effectiveSandboxPolicy
        self.queuedFollowUps = queuedFollowUps
        self.activeTurnId = activeTurnId
        self.activePlanProgress = activePlanProgress
        self.pendingPlanImplementationPrompt = pendingPlanImplementationPrompt
        self.contextTokensUsed = contextTokensUsed
        self.modelContextWindow = modelContextWindow
        self.rateLimits = rateLimits
        self.realtimeSessionId = realtimeSessionId
    }




}

struct AppTokenUsage: Equatable, Hashable {
    var totalTokens: Int64
    var inputTokens: Int64
    var cachedInputTokens: Int64
    var outputTokens: Int64
    var reasoningOutputTokens: Int64
    var contextWindow: Int64?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(totalTokens: Int64, inputTokens: Int64, cachedInputTokens: Int64, outputTokens: Int64, reasoningOutputTokens: Int64, contextWindow: Int64?) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.contextWindow = contextWindow
    }




}

struct AppTokensByThreadEntry: Equatable, Hashable {
    var threadTitle: String
    var threadId: String
    var tokens: UInt64

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(threadTitle: String, threadId: String, tokens: UInt64) {
        self.threadTitle = threadTitle
        self.threadId = threadId
        self.tokens = tokens
    }




}

struct AppToolCallCard: Equatable, Hashable {
    var kind: AppToolCallKind
    var title: String
    var summary: String
    var status: ToolCallStatus
    var durationMs: UInt64?
    var targetLabel: String?
    var sections: [AppToolCallSection]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(kind: AppToolCallKind, title: String, summary: String, status: ToolCallStatus, durationMs: UInt64?, targetLabel: String?, sections: [AppToolCallSection]) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.status = status
        self.durationMs = durationMs
        self.targetLabel = targetLabel
        self.sections = sections
    }




}

struct AppToolCallKeyValue: Equatable, Hashable {
    var key: String
    var value: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(key: String, value: String) {
        self.key = key
        self.value = value
    }




}

struct AppToolCallSection: Equatable, Hashable {
    var label: String
    var content: AppToolCallSectionContent

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(label: String, content: AppToolCallSectionContent) {
        self.label = label
        self.content = content
    }




}

struct AppToolLogEntry: Equatable, Hashable {
    var tool: String
    var detail: String
    var status: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(tool: String, detail: String, status: String) {
        self.tool = tool
        self.detail = detail
        self.status = status
    }




}

struct AppVoiceHandoffRequest: Equatable, Hashable {
    var handoffId: String
    var inputTranscript: String
    var activeTranscript: String
    var serverHint: String?
    var fallbackTranscript: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(handoffId: String, inputTranscript: String, activeTranscript: String, serverHint: String?, fallbackTranscript: String?) {
        self.handoffId = handoffId
        self.inputTranscript = inputTranscript
        self.activeTranscript = activeTranscript
        self.serverHint = serverHint
        self.fallbackTranscript = fallbackTranscript
    }




}

struct AppVoiceSessionSnapshot: Equatable, Hashable {
    var activeThread: ThreadKey?
    var sessionId: String?
    var phase: AppVoiceSessionPhase?
    var lastError: String?
    var transcriptEntries: [AppVoiceTranscriptEntry]
    var handoffThreadKey: ThreadKey?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(activeThread: ThreadKey?, sessionId: String?, phase: AppVoiceSessionPhase?, lastError: String?, transcriptEntries: [AppVoiceTranscriptEntry], handoffThreadKey: ThreadKey?) {
        self.activeThread = activeThread
        self.sessionId = sessionId
        self.phase = phase
        self.lastError = lastError
        self.transcriptEntries = transcriptEntries
        self.handoffThreadKey = handoffThreadKey
    }




}

struct AppVoiceTranscriptEntry: Equatable, Hashable {
    var itemId: String
    var speaker: AppVoiceSpeaker
    var text: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(itemId: String, speaker: AppVoiceSpeaker, text: String) {
        self.itemId = itemId
        self.speaker = speaker
        self.text = text
    }




}

struct AppVoiceTranscriptUpdate: Equatable, Hashable {
    var itemId: String
    var speaker: AppVoiceSpeaker
    var text: String
    var isFinal: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(itemId: String, speaker: AppVoiceSpeaker, text: String, isFinal: Bool) {
        self.itemId = itemId
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
    }




}

struct AppWriteConfigValueRequest: Equatable, Hashable {
    var keyPath: String
    /**
     * JSON-encoded value string.
     */
    var valueJson: String
    var mergeStrategy: AppMergeStrategy
    var filePath: String?
    var expectedVersion: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(keyPath: String,
        /**
         * JSON-encoded value string.
         */valueJson: String, mergeStrategy: AppMergeStrategy, filePath: String?, expectedVersion: String?) {
        self.keyPath = keyPath
        self.valueJson = valueJson
        self.mergeStrategy = mergeStrategy
        self.filePath = filePath
        self.expectedVersion = expectedVersion
    }




}

struct AuthStatus: Equatable, Hashable {
    var authMethod: AuthMode?
    var authToken: String?
    var requiresOpenaiAuth: Bool?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(authMethod: AuthMode? = nil, authToken: String? = nil, requiresOpenaiAuth: Bool? = nil) {
        self.authMethod = authMethod
        self.authToken = authToken
        self.requiresOpenaiAuth = requiresOpenaiAuth
    }




}

struct AuthStatusRequest: Equatable, Hashable {
    var includeToken: Bool?
    var refreshToken: Bool?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(includeToken: Bool? = nil, refreshToken: Bool? = nil) {
        self.includeToken = includeToken
        self.refreshToken = refreshToken
    }




}

struct CommandExecResult: Equatable, Hashable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }




}

struct ComputerUseView: Equatable, Hashable {
    var tool: ComputerUseTool
    var summary: String
    /**
     * PNG bytes. Decoded from the upstream base64 result so platforms
     * receive ready-to-display `Data` / `ByteArray` with no per-platform
     * base64 work.
     */
    var screenshotPng: Data?
    var accessibilityText: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(tool: ComputerUseTool, summary: String,
        /**
         * PNG bytes. Decoded from the upstream base64 result so platforms
         * receive ready-to-display `Data` / `ByteArray` with no per-platform
         * base64 work.
         */screenshotPng: Data?, accessibilityText: String?) {
        self.tool = tool
        self.summary = summary
        self.screenshotPng = screenshotPng
        self.accessibilityText = accessibilityText
    }




}

struct ConnectedServer: Equatable, Hashable {
    var serverId: String
    var name: String
    var hostname: String
    var isLocal: Bool
    var isConnected: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(serverId: String, name: String, hostname: String, isLocal: Bool, isConnected: Bool) {
        self.serverId = serverId
        self.name = name
        self.hostname = hostname
        self.isLocal = isLocal
        self.isConnected = isConnected
    }




}

struct CreditsSnapshot: Equatable, Hashable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(hasCredits: Bool, unlimited: Bool, balance: String? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }




}

struct DirectoryListResult: Equatable, Hashable {
    /**
     * Subdirectory names, sorted case-insensitively.
     */
    var directories: [String]
    /**
     * The resolved path that was listed.
     */
    var path: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(
        /**
         * Subdirectory names, sorted case-insensitively.
         */directories: [String],
        /**
         * The resolved path that was listed.
         */path: String) {
        self.directories = directories
        self.path = path
    }




}

struct DirectoryPathSegment: Equatable, Hashable {
    /**
     * Display label (e.g. "Users" or "C:\").
     */
    var label: String
    /**
     * Full path up to and including this segment.
     */
    var fullPath: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(
        /**
         * Display label (e.g. "Users" or "C:\").
         */label: String,
        /**
         * Full path up to and including this segment.
         */fullPath: String) {
        self.label = label
        self.fullPath = fullPath
    }




}

struct DrainTranscriptResult: Equatable, Hashable {
    var text: String?
    var speaker: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(text: String?, speaker: String?) {
        self.text = text
        self.speaker = speaker
    }




}

struct ExecResult: Equatable, Hashable {
    var exitCode: UInt32
    var stdout: String
    var stderr: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(exitCode: UInt32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }




}

struct FileSearchResult: Equatable, Hashable {
    var root: String
    var path: String
    var matchType: FileSearchMatchType
    var fileName: String
    var score: UInt32
    var indices: [UInt32]?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(root: String, path: String, matchType: FileSearchMatchType, fileName: String, score: UInt32, indices: [UInt32]? = nil) {
        self.root = root
        self.path = path
        self.matchType = matchType
        self.fileName = fileName
        self.score = score
        self.indices = indices
    }




}

struct HandoffTurnConfig: Equatable, Hashable {
    var model: String?
    var effort: String?
    var fastMode: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(model: String?, effort: String?, fastMode: Bool) {
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
    }




}

struct HomeSelection: Equatable, Hashable {
    var selectedServerId: String?
    var selectedProjectId: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(selectedServerId: String?, selectedProjectId: String?) {
        self.selectedServerId = selectedServerId
        self.selectedProjectId = selectedProjectId
    }




}

struct HydratedAssistantMessageData: Equatable, Hashable {
    var text: String
    var agentNickname: String?
    var agentRole: String?
    var phase: AppMessagePhase?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(text: String, agentNickname: String?, agentRole: String?, phase: AppMessagePhase?) {
        self.text = text
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.phase = phase
    }




}

struct HydratedCodeReviewCodeLocationData: Equatable, Hashable {
    var absoluteFilePath: String
    var lineRange: HydratedCodeReviewLineRangeData?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(absoluteFilePath: String, lineRange: HydratedCodeReviewLineRangeData?) {
        self.absoluteFilePath = absoluteFilePath
        self.lineRange = lineRange
    }




}

struct HydratedCodeReviewData: Equatable, Hashable {
    var findings: [HydratedCodeReviewFindingData]
    var overallCorrectness: String?
    var overallExplanation: String?
    var overallConfidenceScore: Double?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(findings: [HydratedCodeReviewFindingData], overallCorrectness: String?, overallExplanation: String?, overallConfidenceScore: Double?) {
        self.findings = findings
        self.overallCorrectness = overallCorrectness
        self.overallExplanation = overallExplanation
        self.overallConfidenceScore = overallConfidenceScore
    }




}

struct HydratedCodeReviewFindingData: Equatable, Hashable {
    var title: String
    var body: String
    var confidenceScore: Double
    var priority: UInt8?
    var codeLocation: HydratedCodeReviewCodeLocationData?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(title: String, body: String, confidenceScore: Double, priority: UInt8?, codeLocation: HydratedCodeReviewCodeLocationData?) {
        self.title = title
        self.body = body
        self.confidenceScore = confidenceScore
        self.priority = priority
        self.codeLocation = codeLocation
    }




}

struct HydratedCodeReviewLineRangeData: Equatable, Hashable {
    var start: UInt32
    var end: UInt32

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(start: UInt32, end: UInt32) {
        self.start = start
        self.end = end
    }




}

struct HydratedCommandActionData: Equatable, Hashable {
    var kind: HydratedCommandActionKind
    var command: String
    var name: String?
    var path: String?
    var query: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(kind: HydratedCommandActionKind, command: String, name: String?, path: String?, query: String?) {
        self.kind = kind
        self.command = command
        self.name = name
        self.path = path
        self.query = query
    }




}

struct HydratedCommandExecutionData: Equatable, Hashable {
    var command: String
    var cwd: String
    var status: AppOperationStatus
    var output: String?
    var exitCode: Int32?
    var durationMs: Int64?
    var processId: String?
    var actions: [HydratedCommandActionData]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(command: String, cwd: String, status: AppOperationStatus, output: String?, exitCode: Int32?, durationMs: Int64?, processId: String?, actions: [HydratedCommandActionData]) {
        self.command = command
        self.cwd = cwd
        self.status = status
        self.output = output
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.processId = processId
        self.actions = actions
    }




}

struct HydratedConversationItem: Equatable, Hashable {
    var id: String
    var content: HydratedConversationItemContent
    var sourceTurnId: String?
    var sourceTurnIndex: UInt32?
    var timestamp: Double?
    var isFromUserTurnBoundary: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(id: String, content: HydratedConversationItemContent, sourceTurnId: String?, sourceTurnIndex: UInt32?, timestamp: Double?, isFromUserTurnBoundary: Bool) {
        self.id = id
        self.content = content
        self.sourceTurnId = sourceTurnId
        self.sourceTurnIndex = sourceTurnIndex
        self.timestamp = timestamp
        self.isFromUserTurnBoundary = isFromUserTurnBoundary
    }




}

struct HydratedDynamicToolCallData: Equatable, Hashable {
    var tool: String
    var status: AppOperationStatus
    var durationMs: Int64?
    var success: Bool?
    var argumentsJson: String?
    var contentSummary: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(tool: String, status: AppOperationStatus, durationMs: Int64?, success: Bool?, argumentsJson: String?, contentSummary: String?) {
        self.tool = tool
        self.status = status
        self.durationMs = durationMs
        self.success = success
        self.argumentsJson = argumentsJson
        self.contentSummary = contentSummary
    }




}

struct HydratedErrorData: Equatable, Hashable {
    var title: String
    var message: String
    var details: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(title: String, message: String, details: String?) {
        self.title = title
        self.message = message
        self.details = details
    }




}

struct HydratedFileChangeData: Equatable, Hashable {
    var status: AppOperationStatus
    var changes: [HydratedFileChangeEntryData]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(status: AppOperationStatus, changes: [HydratedFileChangeEntryData]) {
        self.status = status
        self.changes = changes
    }




}

struct HydratedFileChangeEntryData: Equatable, Hashable {
    var path: String
    var kind: String
    var diff: String
    var additions: UInt32
    var deletions: UInt32

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(path: String, kind: String, diff: String, additions: UInt32, deletions: UInt32) {
        self.path = path
        self.kind = kind
        self.diff = diff
        self.additions = additions
        self.deletions = deletions
    }




}

struct HydratedImageGenerationData: Equatable, Hashable {
    var status: AppOperationStatus
    var revisedPrompt: String?
    /**
     * Decoded PNG bytes from the upstream base64 `result` payload. `None`
     * while the model is still streaming or when decoding fails.
     */
    var imagePng: Data?
    var savedPath: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(status: AppOperationStatus, revisedPrompt: String?,
        /**
         * Decoded PNG bytes from the upstream base64 `result` payload. `None`
         * while the model is still streaming or when decoding fails.
         */imagePng: Data?, savedPath: String?) {
        self.status = status
        self.revisedPrompt = revisedPrompt
        self.imagePng = imagePng
        self.savedPath = savedPath
    }




}

struct HydratedImageViewData: Equatable, Hashable {
    var path: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(path: String) {
        self.path = path
    }




}

struct HydratedMcpToolCallData: Equatable, Hashable {
    var server: String
    var tool: String
    var status: AppOperationStatus
    var durationMs: Int64?
    var argumentsJson: String?
    var contentSummary: String?
    var structuredContentJson: String?
    var rawOutputJson: String?
    var errorMessage: String?
    var progressMessages: [String]
    var computerUse: ComputerUseView?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(server: String, tool: String, status: AppOperationStatus, durationMs: Int64?, argumentsJson: String?, contentSummary: String?, structuredContentJson: String?, rawOutputJson: String?, errorMessage: String?, progressMessages: [String], computerUse: ComputerUseView?) {
        self.server = server
        self.tool = tool
        self.status = status
        self.durationMs = durationMs
        self.argumentsJson = argumentsJson
        self.contentSummary = contentSummary
        self.structuredContentJson = structuredContentJson
        self.rawOutputJson = rawOutputJson
        self.errorMessage = errorMessage
        self.progressMessages = progressMessages
        self.computerUse = computerUse
    }




}

struct HydratedMultiAgentActionData: Equatable, Hashable {
    var tool: String
    var status: AppOperationStatus
    var prompt: String?
    var targets: [String]
    var receiverThreadIds: [String]
    var agentStates: [HydratedMultiAgentStateData]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(tool: String, status: AppOperationStatus, prompt: String?, targets: [String], receiverThreadIds: [String], agentStates: [HydratedMultiAgentStateData]) {
        self.tool = tool
        self.status = status
        self.prompt = prompt
        self.targets = targets
        self.receiverThreadIds = receiverThreadIds
        self.agentStates = agentStates
    }




}

struct HydratedMultiAgentStateData: Equatable, Hashable {
    var targetId: String
    var status: AppSubagentStatus
    var message: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(targetId: String, status: AppSubagentStatus, message: String?) {
        self.targetId = targetId
        self.status = status
        self.message = message
    }




}

struct HydratedNoteData: Equatable, Hashable {
    var title: String
    var body: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(title: String, body: String) {
        self.title = title
        self.body = body
    }




}

struct HydratedPlanStep: Equatable, Hashable {
    var step: String
    var status: HydratedPlanStepStatus

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(step: String, status: HydratedPlanStepStatus) {
        self.step = step
        self.status = status
    }




}

struct HydratedProposedPlanData: Equatable, Hashable {
    var content: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(content: String) {
        self.content = content
    }




}

struct HydratedReasoningData: Equatable, Hashable {
    var summary: [String]
    var content: [String]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(summary: [String], content: [String]) {
        self.summary = summary
        self.content = content
    }




}

struct HydratedTodoListData: Equatable, Hashable {
    var steps: [HydratedPlanStep]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(steps: [HydratedPlanStep]) {
        self.steps = steps
    }




}

struct HydratedTurnDiffData: Equatable, Hashable {
    var diff: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(diff: String) {
        self.diff = diff
    }




}

struct HydratedUserInputResponseData: Equatable, Hashable {
    var questions: [HydratedUserInputResponseQuestionData]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(questions: [HydratedUserInputResponseQuestionData]) {
        self.questions = questions
    }




}

struct HydratedUserInputResponseOptionData: Equatable, Hashable {
    var label: String
    var description: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(label: String, description: String?) {
        self.label = label
        self.description = description
    }




}

struct HydratedUserInputResponseQuestionData: Equatable, Hashable {
    var id: String
    var header: String?
    var question: String
    var answer: String
    var options: [HydratedUserInputResponseOptionData]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(id: String, header: String?, question: String, answer: String, options: [HydratedUserInputResponseOptionData]) {
        self.id = id
        self.header = header
        self.question = question
        self.answer = answer
        self.options = options
    }




}

struct HydratedUserMessageData: Equatable, Hashable {
    var text: String
    var imageDataUris: [String]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(text: String, imageDataUris: [String]) {
        self.text = text
        self.imageDataUris = imageDataUris
    }




}

struct HydratedWebSearchData: Equatable, Hashable {
    var query: String
    var actionJson: String?
    var isInProgress: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(query: String, actionJson: String?, isInProgress: Bool) {
        self.query = query
        self.actionJson = actionJson
        self.isInProgress = isInProgress
    }




}

struct HydratedWidgetData: Equatable, Hashable {
    var title: String
    var widgetHtml: String
    var width: Double
    var height: Double
    var status: String
    var isFinalized: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(title: String, widgetHtml: String, width: Double, height: Double, status: String, isFinalized: Bool) {
        self.title = title
        self.widgetHtml = widgetHtml
        self.width = width
        self.height = height
        self.status = status
        self.isFinalized = isFinalized
    }




}

struct MobilePreferences: Equatable, Hashable {
    var pinnedThreads: [PinnedThreadKey]
    /**
     * Threads the user swiped to hide from the home list. Does not delete
     * the thread — just suppresses it from the home merge.
     */
    var hiddenThreads: [PinnedThreadKey]
    var homeSelection: HomeSelection

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(pinnedThreads: [PinnedThreadKey],
        /**
         * Threads the user swiped to hide from the home list. Does not delete
         * the thread — just suppresses it from the home merge.
         */hiddenThreads: [PinnedThreadKey], homeSelection: HomeSelection) {
        self.pinnedThreads = pinnedThreads
        self.hiddenThreads = hiddenThreads
        self.homeSelection = homeSelection
    }




}

struct ModelInfo: Equatable, Hashable {
    var id: String
    var model: String
    var upgrade: String?
    var upgradeModel: String?
    var upgradeCopy: String?
    var modelLink: String?
    var migrationMarkdown: String?
    var availabilityNuxMessage: String?
    var displayName: String
    var description: String
    var hidden: Bool
    var supportedReasoningEfforts: [ReasoningEffortOption]
    var defaultReasoningEffort: ReasoningEffort
    var inputModalities: [InputModality]
    var supportsPersonality: Bool
    var isDefault: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(id: String, model: String, upgrade: String? = nil, upgradeModel: String? = nil, upgradeCopy: String? = nil, modelLink: String? = nil, migrationMarkdown: String? = nil, availabilityNuxMessage: String? = nil, displayName: String, description: String, hidden: Bool, supportedReasoningEfforts: [ReasoningEffortOption], defaultReasoningEffort: ReasoningEffort, inputModalities: [InputModality], supportsPersonality: Bool = false, isDefault: Bool) {
        self.id = id
        self.model = model
        self.upgrade = upgrade
        self.upgradeModel = upgradeModel
        self.upgradeCopy = upgradeCopy
        self.modelLink = modelLink
        self.migrationMarkdown = migrationMarkdown
        self.availabilityNuxMessage = availabilityNuxMessage
        self.displayName = displayName
        self.description = description
        self.hidden = hidden
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.inputModalities = inputModalities
        self.supportsPersonality = supportsPersonality
        self.isDefault = isDefault
    }




}

struct PendingApproval: Equatable, Hashable {
    /**
     * The JSON-RPC request ID as a string (could originally be string or integer).
     */
    var id: String
    /**
     * Server that owns this approval.
     */
    var serverId: String
    /**
     * What kind of approval is being requested.
     */
    var kind: ApprovalKind
    /**
     * Thread this approval belongs to.
     */
    var threadId: String?
    /**
     * Turn this approval belongs to.
     */
    var turnId: String?
    /**
     * Item ID this approval is associated with.
     */
    var itemId: String?
    /**
     * The command to approve, if applicable.
     */
    var command: String?
    /**
     * The file path involved, if applicable.
     */
    var path: String?
    /**
     * Grant root involved in a file change request, if applicable.
     */
    var grantRoot: String?
    /**
     * Working directory for the command, if applicable.
     */
    var cwd: String?
    /**
     * Human-readable reason/explanation for the approval request.
     */
    var reason: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(
        /**
         * The JSON-RPC request ID as a string (could originally be string or integer).
         */id: String,
        /**
         * Server that owns this approval.
         */serverId: String,
        /**
         * What kind of approval is being requested.
         */kind: ApprovalKind,
        /**
         * Thread this approval belongs to.
         */threadId: String?,
        /**
         * Turn this approval belongs to.
         */turnId: String?,
        /**
         * Item ID this approval is associated with.
         */itemId: String?,
        /**
         * The command to approve, if applicable.
         */command: String?,
        /**
         * The file path involved, if applicable.
         */path: String?,
        /**
         * Grant root involved in a file change request, if applicable.
         */grantRoot: String?,
        /**
         * Working directory for the command, if applicable.
         */cwd: String?,
        /**
         * Human-readable reason/explanation for the approval request.
         */reason: String?) {
        self.id = id
        self.serverId = serverId
        self.kind = kind
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.command = command
        self.path = path
        self.grantRoot = grantRoot
        self.cwd = cwd
        self.reason = reason
    }




}

struct PendingUserInputAnswer: Equatable, Hashable {
    var questionId: String
    var answers: [String]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(questionId: String, answers: [String]) {
        self.questionId = questionId
        self.answers = answers
    }




}

struct PendingUserInputOption: Equatable, Hashable {
    var label: String
    var description: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(label: String, description: String?) {
        self.label = label
        self.description = description
    }




}

struct PendingUserInputQuestion: Equatable, Hashable {
    var id: String
    var header: String?
    var question: String
    var isOtherAllowed: Bool
    var isSecret: Bool
    var options: [PendingUserInputOption]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(id: String, header: String?, question: String, isOtherAllowed: Bool, isSecret: Bool, options: [PendingUserInputOption]) {
        self.id = id
        self.header = header
        self.question = question
        self.isOtherAllowed = isOtherAllowed
        self.isSecret = isSecret
        self.options = options
    }




}

struct PendingUserInputRequest: Equatable, Hashable {
    var id: String
    var serverId: String
    var threadId: String
    var turnId: String
    var itemId: String
    var questions: [PendingUserInputQuestion]
    var requesterAgentNickname: String?
    var requesterAgentRole: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(id: String, serverId: String, threadId: String, turnId: String, itemId: String, questions: [PendingUserInputQuestion], requesterAgentNickname: String?, requesterAgentRole: String?) {
        self.id = id
        self.serverId = serverId
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.questions = questions
        self.requesterAgentNickname = requesterAgentNickname
        self.requesterAgentRole = requesterAgentRole
    }




}

struct PinnedThreadKey: Equatable, Hashable {
    var serverId: String
    var threadId: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(serverId: String, threadId: String) {
        self.serverId = serverId
        self.threadId = threadId
    }




}

struct RateLimitSnapshot: Equatable, Hashable {
    var limitId: String?
    var limitName: String?
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?
    var credits: CreditsSnapshot?
    var planType: PlanType?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(limitId: String? = nil, limitName: String? = nil, primary: RateLimitWindow? = nil, secondary: RateLimitWindow? = nil, credits: CreditsSnapshot? = nil, planType: PlanType? = nil) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.planType = planType
    }




}

struct RateLimitWindow: Equatable, Hashable {
    var usedPercent: Int32
    var windowDurationMins: Int64?
    var resetsAt: Int64?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(usedPercent: Int32, windowDurationMins: Int64? = nil, resetsAt: Int64? = nil) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }




}

struct RateLimits: Equatable, Hashable {
    /**
     * Number of requests remaining in the current window.
     */
    var requestsRemaining: UInt64?
    /**
     * Number of tokens remaining in the current window.
     */
    var tokensRemaining: UInt64?
    /**
     * ISO 8601 timestamp when the rate limit window resets.
     */
    var resetAt: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(
        /**
         * Number of requests remaining in the current window.
         */requestsRemaining: UInt64?,
        /**
         * Number of tokens remaining in the current window.
         */tokensRemaining: UInt64?,
        /**
         * ISO 8601 timestamp when the rate limit window resets.
         */resetAt: String?) {
        self.requestsRemaining = requestsRemaining
        self.tokensRemaining = tokensRemaining
        self.resetAt = resetAt
    }




}

struct ReasoningEffortOption: Equatable, Hashable {
    var reasoningEffort: ReasoningEffort
    var description: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(reasoningEffort: ReasoningEffort, description: String) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }




}

struct ReconnectResult: Equatable, Hashable {
    var serverId: String
    var success: Bool
    var needsLocalAuthRestore: Bool
    var errorMessage: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(serverId: String, success: Bool, needsLocalAuthRestore: Bool, errorMessage: String?) {
        self.serverId = serverId
        self.success = success
        self.needsLocalAuthRestore = needsLocalAuthRestore
        self.errorMessage = errorMessage
    }




}

struct ResolvedImageViewResult: Equatable, Hashable {
    var path: String
    var bytes: Data

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(path: String, bytes: Data) {
        self.path = path
        self.bytes = bytes
    }




}

struct SavedServerRecord: Equatable, Hashable {
    var id: String
    var name: String
    var hostname: String
    var port: UInt16
    var codexPorts: [UInt16]
    var sshPort: UInt16?
    var source: String
    var hasCodexServer: Bool
    var wakeMac: String?
    var preferredConnectionMode: String?
    var preferredCodexPort: UInt16?
    var sshPortForwardingEnabled: Bool?
    var websocketUrl: String?
    var rememberedByUser: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(id: String, name: String, hostname: String, port: UInt16, codexPorts: [UInt16], sshPort: UInt16?, source: String, hasCodexServer: Bool, wakeMac: String?, preferredConnectionMode: String?, preferredCodexPort: UInt16?, sshPortForwardingEnabled: Bool?, websocketUrl: String?, rememberedByUser: Bool) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.codexPorts = codexPorts
        self.sshPort = sshPort
        self.source = source
        self.hasCodexServer = hasCodexServer
        self.wakeMac = wakeMac
        self.preferredConnectionMode = preferredConnectionMode
        self.preferredCodexPort = preferredCodexPort
        self.sshPortForwardingEnabled = sshPortForwardingEnabled
        self.websocketUrl = websocketUrl
        self.rememberedByUser = rememberedByUser
    }




}

struct SkillDependencies: Equatable, Hashable {
    var tools: [SkillToolDependency]

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(tools: [SkillToolDependency]) {
        self.tools = tools
    }




}

struct SkillInterface: Equatable, Hashable {
    var displayName: String?
    var shortDescription: String?
    var iconSmall: AbsolutePath?
    var iconLarge: AbsolutePath?
    var brandColor: String?
    var defaultPrompt: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(displayName: String? = nil, shortDescription: String? = nil, iconSmall: AbsolutePath? = nil, iconLarge: AbsolutePath? = nil, brandColor: String? = nil, defaultPrompt: String? = nil) {
        self.displayName = displayName
        self.shortDescription = shortDescription
        self.iconSmall = iconSmall
        self.iconLarge = iconLarge
        self.brandColor = brandColor
        self.defaultPrompt = defaultPrompt
    }




}

struct SkillMetadata: Equatable, Hashable {
    var name: String
    var description: String
    var shortDescription: String?
    var interface: SkillInterface?
    var dependencies: SkillDependencies?
    var path: AbsolutePath
    var scope: SkillScope
    var enabled: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(name: String, description: String, shortDescription: String? = nil, interface: SkillInterface? = nil, dependencies: SkillDependencies? = nil, path: AbsolutePath, scope: SkillScope, enabled: Bool) {
        self.name = name
        self.description = description
        self.shortDescription = shortDescription
        self.interface = interface
        self.dependencies = dependencies
        self.path = path
        self.scope = scope
        self.enabled = enabled
    }




}

struct SkillToolDependency: Equatable, Hashable {
    var type: String
    var value: String
    var description: String?
    var transport: String?
    var command: String?
    var url: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(type: String, value: String, description: String? = nil, transport: String? = nil, command: String? = nil, url: String? = nil) {
        self.type = type
        self.value = value
        self.description = description
        self.transport = transport
        self.command = command
        self.url = url
    }




}

struct SshCredentialRecord: Equatable, Hashable {
    var username: String
    var authMethod: SshAuthMethodRecord
    var password: String?
    var privateKeyPem: String?
    var passphrase: String?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(username: String, authMethod: SshAuthMethodRecord, password: String?, privateKeyPem: String?, passphrase: String?) {
        self.username = username
        self.authMethod = authMethod
        self.password = password
        self.privateKeyPem = privateKeyPem
        self.passphrase = passphrase
    }




}

struct StreamedItem: Equatable, Hashable {
    var itemId: String
    var text: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(itemId: String, text: String) {
        self.itemId = itemId
        self.text = text
    }




}

struct ThreadInfo: Equatable, Hashable {
    /**
     * Unique identifier for the thread.
     */
    var id: String
    /**
     * User-facing title, if set.
     */
    var title: String?
    /**
     * The model used for this thread, if known.
     */
    var model: String?
    /**
     * Current status of the thread.
     */
    var status: ThreadSummaryStatus
    /**
     * Preview text (usually the first user message).
     */
    var preview: String?
    /**
     * Working directory for the thread.
     */
    var cwd: String?
    /**
     * Rollout path on the server filesystem.
     */
    var path: String?
    /**
     * Model provider (e.g. "openai").
     */
    var modelProvider: String?
    /**
     * Agent nickname for subagent threads.
     */
    var agentNickname: String?
    /**
     * Agent role for subagent threads.
     */
    var agentRole: String?
    /**
     * Parent thread id for spawned/forked threads when known.
     */
    var parentThreadId: String?
    /**
     * Best-effort subagent lifecycle status string.
     */
    var agentStatus: String?
    /**
     * Unix timestamp (seconds) when the thread was created.
     */
    var createdAt: Int64?
    /**
     * Unix timestamp (seconds) when the thread was last updated.
     */
    var updatedAt: Int64?

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(
        /**
         * Unique identifier for the thread.
         */id: String,
        /**
         * User-facing title, if set.
         */title: String?,
        /**
         * The model used for this thread, if known.
         */model: String?,
        /**
         * Current status of the thread.
         */status: ThreadSummaryStatus,
        /**
         * Preview text (usually the first user message).
         */preview: String?,
        /**
         * Working directory for the thread.
         */cwd: String?,
        /**
         * Rollout path on the server filesystem.
         */path: String?,
        /**
         * Model provider (e.g. "openai").
         */modelProvider: String?,
        /**
         * Agent nickname for subagent threads.
         */agentNickname: String?,
        /**
         * Agent role for subagent threads.
         */agentRole: String?,
        /**
         * Parent thread id for spawned/forked threads when known.
         */parentThreadId: String?,
        /**
         * Best-effort subagent lifecycle status string.
         */agentStatus: String?,
        /**
         * Unix timestamp (seconds) when the thread was created.
         */createdAt: Int64?,
        /**
         * Unix timestamp (seconds) when the thread was last updated.
         */updatedAt: Int64?) {
        self.id = id
        self.title = title
        self.model = model
        self.status = status
        self.preview = preview
        self.cwd = cwd
        self.path = path
        self.modelProvider = modelProvider
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.parentThreadId = parentThreadId
        self.agentStatus = agentStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }




}

struct ThreadKey: Equatable, Hashable {
    var serverId: String
    var threadId: String

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(serverId: String, threadId: String) {
        self.serverId = serverId
        self.threadId = threadId
    }




}

struct TranscriptDeltaResult: Equatable, Hashable {
    var fullText: String
    var previousText: String?
    var speakerChanged: Bool

    // Default memberwise initializers are never by default, so we
    // declare one manually.
    init(fullText: String, previousText: String?, speakerChanged: Bool) {
        self.fullText = fullText
        self.previousText = previousText
        self.speakerChanged = speakerChanged
    }




}

enum Account: Equatable, Hashable {

    case apiKey
    case chatgpt(email: String, planType: PlanType
    )





}

enum AppAskForApproval: Equatable, Hashable {

    case unlessTrusted
    case onFailure
    case onRequest
    case granular(sandboxApproval: Bool, rules: Bool, skillApproval: Bool, requestPermissions: Bool, mcpElicitations: Bool
    )
    case never





}

enum AppConnectionStepKind: Equatable, Hashable {

    case connectingToSsh
    case findingCodex
    case installingCodex
    case startingAppServer
    case openingTunnel
    case connected





}

enum AppConnectionStepState: Equatable, Hashable {

    case pending
    case inProgress
    case completed
    case failed
    case awaitingUserInput
    case cancelled





}

enum AppDiscoverySource: Equatable, Hashable {

    case bonjour
    case tailscale
    case lanProbe
    case arpScan
    case manual
    case local





}

enum AppLoginAccountRequest: Equatable, Hashable {

    case apiKey(apiKey: String
    )
    case chatgpt
    case chatgptAuthTokens(accessToken: String, chatgptAccountId: String, chatgptPlanType: String?
    )





}

enum AppMergeStrategy: Equatable, Hashable {

    case replace
    case upsert





}

enum AppMessagePhase: Equatable, Hashable {

    case commentary
    case finalAnswer





}

enum AppMessageRenderBlock: Equatable, Hashable {

    case markdown(markdown: String
    )
    case codeBlock(language: String?, code: String
    )
    case inlineImage(data: Data, mimeType: String
    )





}

enum AppMessageSegment: Equatable, Hashable {

    case text(text: String
    )
    case inlineImage(data: Data, mimeType: String
    )
    case inlineMath(latex: String
    )
    case displayMath(latex: String
    )
    case codeBlock(language: String?, code: String
    )





}

enum AppModeKind: Equatable, Hashable {

    case `default`
    case plan





}

enum AppNetworkAccess: Equatable, Hashable {

    case restricted
    case enabled





}

enum AppOperationStatus: Equatable, Hashable {

    case unknown
    case pending
    case inProgress
    case completed
    case failed
    case declined





}

enum AppPlanStepStatus: Equatable, Hashable {

    case pending
    case inProgress
    case completed





}

enum AppQueuedFollowUpKind: Equatable, Hashable {

    case message
    case pendingSteer
    case retryingSteer





}

enum AppReadOnlyAccess: Equatable, Hashable {

    case restricted(includePlatformDefaults: Bool, readableRoots: [AbsolutePath]
    )
    case fullAccess





}

enum AppRealtimeOutputModality: Equatable, Hashable {

    case text
    case audio





}

enum AppRealtimeStartTransport: Equatable, Hashable {

    case websocket
    case webrtc(sdp: String
    )





}

enum AppRealtimeVoice: Equatable, Hashable {

    case alloy
    case arbor
    case ash
    case ballad
    case breeze
    case cedar
    case coral
    case cove
    case echo
    case ember
    case juniper
    case maple
    case marin
    case sage
    case shimmer
    case sol
    case spruce
    case vale
    case verse





}

enum AppReviewTarget: Equatable, Hashable {

    case uncommittedChanges
    case baseBranch(branch: String
    )
    case commit(sha: String, title: String?
    )
    case custom(instructions: String
    )





}

enum AppSandboxMode: Equatable, Hashable {

    case readOnly
    case workspaceWrite
    case dangerFullAccess





}

enum AppSandboxPolicy: Equatable, Hashable {

    case dangerFullAccess
    case readOnly(access: AppReadOnlyAccess, networkAccess: Bool
    )
    case externalSandbox(networkAccess: AppNetworkAccess
    )
    case workspaceWrite(writableRoots: [AbsolutePath], readOnlyAccess: AppReadOnlyAccess, networkAccess: Bool, excludeTmpdirEnvVar: Bool, excludeSlashTmp: Bool
    )





}

enum AppServerHealth: Equatable, Hashable {

    case disconnected
    case connecting
    case connected
    case unresponsive
    case unknown





}

enum AppServerIpcState: Equatable, Hashable {

    case unsupported
    case disconnected
    case ready





}

enum AppServerTransportState: Equatable, Hashable {

    case disconnected
    case connecting
    case connected
    case unresponsive
    case unknown





}

enum AppStoreUpdateRecord: Equatable, Hashable {

    case fullResync
    case serverChanged(serverId: String
    )
    case serverRemoved(serverId: String
    )
    case threadUpserted(thread: AppThreadSnapshot, sessionSummary: AppSessionSummary, agentDirectoryVersion: UInt64
    )
    case threadMetadataChanged(state: AppThreadStateRecord, sessionSummary: AppSessionSummary, agentDirectoryVersion: UInt64
    )
    case threadItemChanged(key: ThreadKey, item: HydratedConversationItem,
        /**
         * Per-item derivation (`last_response_preview`, `last_tool_label`,
         * `stats`, etc.) computed at the point of the mutation. Lets
         * platform listeners patch their local `AppSessionSummary` without
         * another FFI roundtrip or a full snapshot rebuild, so the home
         * dashboard's zoom-2 meta line stays in sync with streaming items.
         */sessionSummary: AppSessionSummary
    )
    case threadStreamingDelta(key: ThreadKey, itemId: String, kind: ThreadStreamingDeltaKind, text: String
    )
    case threadRemoved(key: ThreadKey, agentDirectoryVersion: UInt64
    )
    case activeThreadChanged(key: ThreadKey?
    )
    case pendingApprovalsChanged(approvals: [PendingApproval]
    )
    case pendingUserInputsChanged(requests: [PendingUserInputRequest]
    )
    case voiceSessionChanged
    case realtimeTranscriptUpdated(key: ThreadKey, update: AppVoiceTranscriptUpdate
    )
    case realtimeHandoffRequested(key: ThreadKey, request: AppVoiceHandoffRequest
    )
    case realtimeSpeechStarted(key: ThreadKey
    )
    case realtimeStarted(key: ThreadKey, notification: AppRealtimeStartedNotification
    )
    case realtimeOutputAudioDelta(key: ThreadKey, notification: AppRealtimeOutputAudioDeltaNotification
    )
    case realtimeError(key: ThreadKey, notification: AppRealtimeErrorNotification
    )
    case realtimeClosed(key: ThreadKey, notification: AppRealtimeClosedNotification
    )





}

enum AppSubagentStatus: Equatable, Hashable {

    case unknown
    case pendingInit
    case running
    case interrupted
    case completed
    case errored
    case shutdown





}

enum AppThreadPermissionPreset: Equatable, Hashable {

    case unknown
    case supervised
    case fullAccess
    case custom





}

enum AppToolCallKind: Equatable, Hashable {

    case commandExecution
    case commandOutput
    case fileChange
    case fileDiff
    case mcpToolCall
    case mcpToolProgress
    case webSearch
    case collaboration
    case imageView
    case widget
    case unknown(raw: String
    )





}

enum AppToolCallSectionContent: Equatable, Hashable {

    case keyValue(entries: [AppToolCallKeyValue]
    )
    case code(language: String, content: String
    )
    case json(content: String
    )
    case diff(content: String
    )
    case text(content: String
    )
    case itemList(items: [String]
    )
    case progressList(items: [String]
    )





}

enum AppUserInput: Equatable, Hashable {

    case text(text: String, textElements: [AppTextElement]
    )
    case image(url: String
    )
    case localImage(path: AbsolutePath
    )
    case skill(name: String, path: AbsolutePath
    )
    case mention(name: String, path: String
    )





}

enum AppVoiceSessionPhase: Equatable, Hashable {

    case connecting
    case listening
    case speaking
    case thinking
    case handoff
    case error





}

enum AppVoiceSpeaker: Equatable, Hashable {

    case user
    case assistant





}

enum ApprovalDecisionValue: Equatable, Hashable {

    case accept
    case acceptForSession
    case decline
    case cancel





}

enum ApprovalKind: Equatable, Hashable {

    case command
    case fileChange
    case permissions
    case mcpElicitation





}

enum AuthMode: Equatable, Hashable {

    case apiKey
    case chatgpt
    case chatgptAuthTokens





}

enum ClientError: Swift.Error, Equatable, Hashable, Foundation.LocalizedError {



    case Transport(String
    )
    case Rpc(String
    )
    case InvalidParams(String
    )
    case Serialization(String
    )
    case EventClosed(String
    )






    var errorDescription: String? {
        String(reflecting: self)
    }

}

enum ComputerUseTool: Equatable, Hashable {

    case listApps
    case getAppState(app: String
    )
    /**
     * `click` accepts either `element_index` or `{x, y}` pixel coordinates.
     */
    case click(app: String, elementIndex: String?, x: Double?, y: Double?, button: String?
    )
    case performSecondaryAction(app: String, elementIndex: String?, action: String?
    )
    case scroll(app: String, elementIndex: String?, direction: String?, pages: Double?
    )
    case drag(app: String, fromX: Double?, fromY: Double?, toX: Double?, toY: Double?
    )
    case typeText(app: String, text: String
    )
    case pressKey(app: String, key: String
    )
    case setValue(app: String, elementIndex: String?, value: String?
    )
    case unknown(name: String
    )





}

enum FileSearchMatchType: Equatable, Hashable {

    case file
    case directory





}

enum HandoffAction: Equatable, Hashable {

    /**
     * Start or reuse a thread on the target server.
     */
    case startThread(handoffId: String, targetServerId: String, isLocal: Bool, cwd: String
    )
    /**
     * Send a turn on the remote thread.
     */
    case sendTurn(handoffId: String, targetServerId: String, threadId: String, transcript: String, config: HandoffTurnConfig
    )
    /**
     * Resolve the handoff with output text (stream a chunk).
     */
    case resolveHandoff(handoffId: String, voiceThreadKey: ThreadKey, text: String
    )
    /**
     * Finalize the handoff (no more chunks).
     */
    case finalizeHandoff(handoffId: String, voiceThreadKey: ThreadKey
    )
    /**
     * Update UI: set the handoff item's thread key.
     */
    case updateHandoffItem(handoffId: String, voiceThreadKey: ThreadKey, remoteThreadKey: ThreadKey
    )
    /**
     * Update UI: mark the handoff item as completed.
     */
    case completeHandoffItem(handoffId: String, voiceThreadKey: ThreadKey
    )
    /**
     * Set the voice session phase.
     */
    case setVoicePhase(phaseName: String
    )
    /**
     * Report an error.
     */
    case error(handoffId: String, message: String
    )





}

enum HandoffPhase: Equatable, Hashable {

    /**
     * Handoff received, waiting for thread creation / reuse.
     */
    case pending
    /**
     * Thread obtained, turn sent — streaming remote items.
     */
    case streaming
    /**
     * All items streamed, waiting for finalization RPC.
     */
    case waitingFinalize
    /**
     * Handoff fully resolved.
     */
    case completed
    /**
     * An error occurred.
     */
    case failed





}

enum HydratedCommandActionKind: Equatable, Hashable {

    case read
    case search
    case listFiles
    case unknown





}

enum HydratedConversationItemContent: Equatable, Hashable {

    case user(HydratedUserMessageData
    )
    case assistant(HydratedAssistantMessageData
    )
    case codeReview(HydratedCodeReviewData
    )
    case reasoning(HydratedReasoningData
    )
    case todoList(HydratedTodoListData
    )
    case proposedPlan(HydratedProposedPlanData
    )
    case commandExecution(HydratedCommandExecutionData
    )
    case fileChange(HydratedFileChangeData
    )
    case turnDiff(HydratedTurnDiffData
    )
    case mcpToolCall(HydratedMcpToolCallData
    )
    case dynamicToolCall(HydratedDynamicToolCallData
    )
    case multiAgentAction(HydratedMultiAgentActionData
    )
    case webSearch(HydratedWebSearchData
    )
    case imageView(HydratedImageViewData
    )
    case widget(HydratedWidgetData
    )
    case userInputResponse(HydratedUserInputResponseData
    )
    case divider(HydratedDividerData
    )
    case error(HydratedErrorData
    )
    case note(HydratedNoteData
    )
    case imageGeneration(HydratedImageGenerationData
    )





}

enum HydratedDividerData: Equatable, Hashable {

    case contextCompaction(isComplete: Bool
    )
    case modelRerouted(fromModel: String?, toModel: String, reason: String?
    )
    case reviewEntered(review: String
    )
    case reviewExited(review: String
    )





}

enum HydratedPlanStepStatus: Equatable, Hashable {

    case pending
    case inProgress
    case completed





}

enum InputModality: Equatable, Hashable {

    case text
    case image





}

enum PlanType: Equatable, Hashable {

    case free
    case go
    case plus
    case pro
    case team
    case business
    case enterprise
    case edu
    case unknown





}

enum ProgressiveDiscoveryUpdateKind: Equatable, Hashable {

    case partialResults
    case scanComplete





}

enum ReasoningEffort: Equatable, Hashable {

    case none
    case minimal
    case low
    case medium
    case high
    case xHigh





}

enum ServiceTier: Equatable, Hashable {

    case fast
    case flex





}

enum SkillScope: Equatable, Hashable {

    case user
    case repo
    case system
    case admin





}

enum SshAuthMethodRecord: Equatable, Hashable {

    case password
    case key





}

enum ThreadStreamingDeltaKind: Equatable, Hashable {

    case assistantText
    case reasoningText
    case planText
    case commandOutput
    case mcpProgress





}

enum ThreadSummaryStatus: Equatable, Hashable {

    case notLoaded
    case idle
    case active
    case systemError





}

enum TitleSegment: Equatable, Hashable {

    case text(text: String
    )
    case pluginRef(displayName: String, pluginName: String, marketplace: String
    )





}

enum ToolCallStatus: Equatable, Hashable {

    case inProgress
    case completed
    case failed
    case unknown





}
#if compiler(>=6)
extension AbsolutePath: Sendable {}
#endif

#if compiler(>=6)
extension AppActivityByDayEntry: Sendable {}
#endif

#if compiler(>=6)
extension AppAppendRealtimeAudioRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppAppendRealtimeTextRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppArchiveThreadRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppByteRange: Sendable {}
#endif

#if compiler(>=6)
extension AppCodeReviewCodeLocation: Sendable {}
#endif

#if compiler(>=6)
extension AppCodeReviewFinding: Sendable {}
#endif

#if compiler(>=6)
extension AppCodeReviewLineRange: Sendable {}
#endif

#if compiler(>=6)
extension AppCodeReviewPayload: Sendable {}
#endif

#if compiler(>=6)
extension AppCollaborationModePreset: Sendable {}
#endif

#if compiler(>=6)
extension AppConnectionProgressSnapshot: Sendable {}
#endif

#if compiler(>=6)
extension AppConnectionStepSnapshot: Sendable {}
#endif

#if compiler(>=6)
extension AppConversationStats: Sendable {}
#endif

#if compiler(>=6)
extension AppDiscoveredServer: Sendable {}
#endif

#if compiler(>=6)
extension AppDynamicToolSpec: Sendable {}
#endif

#if compiler(>=6)
extension AppExecCommandRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppFinalizeRealtimeHandoffRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppForkThreadFromMessageRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppForkThreadRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppInterruptTurnRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppListSkillsRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppListThreadsRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppMdnsSeed: Sendable {}
#endif

#if compiler(>=6)
extension AppModelUsageEntry: Sendable {}
#endif

#if compiler(>=6)
extension AppPlanImplementationPromptSnapshot: Sendable {}
#endif

#if compiler(>=6)
extension AppPlanProgressSnapshot: Sendable {}
#endif

#if compiler(>=6)
extension AppPlanStep: Sendable {}
#endif

#if compiler(>=6)
extension AppProgressiveDiscoveryUpdate: Sendable {}
#endif

#if compiler(>=6)
extension AppProject: Sendable {}
#endif

#if compiler(>=6)
extension AppQueuedFollowUpPreview: Sendable {}
#endif

#if compiler(>=6)
extension AppReadThreadRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppRealtimeAudioChunk: Sendable {}
#endif

#if compiler(>=6)
extension AppRealtimeClosedNotification: Sendable {}
#endif

#if compiler(>=6)
extension AppRealtimeErrorNotification: Sendable {}
#endif

#if compiler(>=6)
extension AppRealtimeOutputAudioDeltaNotification: Sendable {}
#endif

#if compiler(>=6)
extension AppRealtimeStartedNotification: Sendable {}
#endif

#if compiler(>=6)
extension AppRefreshAccountRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppRefreshModelsRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppRenameThreadRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppResolveRealtimeHandoffRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppResumeThreadRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppSearchFilesRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppServerCapabilities: Sendable {}
#endif

#if compiler(>=6)
extension AppServerSnapshot: Sendable {}
#endif

#if compiler(>=6)
extension AppServerUsageStats: Sendable {}
#endif

#if compiler(>=6)
extension AppSessionSummary: Sendable {}
#endif

#if compiler(>=6)
extension AppSnapshotRecord: Sendable {}
#endif

#if compiler(>=6)
extension AppSshConnectionResult: Sendable {}
#endif

#if compiler(>=6)
extension AppStartRealtimeSessionRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppStartReviewRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppStartThreadRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppStartTurnRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppStopRealtimeSessionRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppTextElement: Sendable {}
#endif

#if compiler(>=6)
extension AppThreadSnapshot: Sendable {}
#endif

#if compiler(>=6)
extension AppThreadStateRecord: Sendable {}
#endif

#if compiler(>=6)
extension AppTokenUsage: Sendable {}
#endif

#if compiler(>=6)
extension AppTokensByThreadEntry: Sendable {}
#endif

#if compiler(>=6)
extension AppToolCallCard: Sendable {}
#endif

#if compiler(>=6)
extension AppToolCallKeyValue: Sendable {}
#endif

#if compiler(>=6)
extension AppToolCallSection: Sendable {}
#endif

#if compiler(>=6)
extension AppToolLogEntry: Sendable {}
#endif

#if compiler(>=6)
extension AppVoiceHandoffRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppVoiceSessionSnapshot: Sendable {}
#endif

#if compiler(>=6)
extension AppVoiceTranscriptEntry: Sendable {}
#endif

#if compiler(>=6)
extension AppVoiceTranscriptUpdate: Sendable {}
#endif

#if compiler(>=6)
extension AppWriteConfigValueRequest: Sendable {}
#endif

#if compiler(>=6)
extension AuthStatus: Sendable {}
#endif

#if compiler(>=6)
extension AuthStatusRequest: Sendable {}
#endif

#if compiler(>=6)
extension CommandExecResult: Sendable {}
#endif

#if compiler(>=6)
extension ComputerUseView: Sendable {}
#endif

#if compiler(>=6)
extension ConnectedServer: Sendable {}
#endif

#if compiler(>=6)
extension CreditsSnapshot: Sendable {}
#endif

#if compiler(>=6)
extension DirectoryListResult: Sendable {}
#endif

#if compiler(>=6)
extension DirectoryPathSegment: Sendable {}
#endif

#if compiler(>=6)
extension DrainTranscriptResult: Sendable {}
#endif

#if compiler(>=6)
extension ExecResult: Sendable {}
#endif

#if compiler(>=6)
extension FileSearchResult: Sendable {}
#endif

#if compiler(>=6)
extension HandoffTurnConfig: Sendable {}
#endif

#if compiler(>=6)
extension HomeSelection: Sendable {}
#endif

#if compiler(>=6)
extension HydratedAssistantMessageData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedCodeReviewCodeLocationData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedCodeReviewData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedCodeReviewFindingData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedCodeReviewLineRangeData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedCommandActionData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedCommandExecutionData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedConversationItem: Sendable {}
#endif

#if compiler(>=6)
extension HydratedDynamicToolCallData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedErrorData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedFileChangeData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedFileChangeEntryData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedImageGenerationData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedImageViewData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedMcpToolCallData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedMultiAgentActionData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedMultiAgentStateData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedNoteData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedPlanStep: Sendable {}
#endif

#if compiler(>=6)
extension HydratedProposedPlanData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedReasoningData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedTodoListData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedTurnDiffData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedUserInputResponseData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedUserInputResponseOptionData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedUserInputResponseQuestionData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedUserMessageData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedWebSearchData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedWidgetData: Sendable {}
#endif

#if compiler(>=6)
extension MobilePreferences: Sendable {}
#endif

#if compiler(>=6)
extension ModelInfo: Sendable {}
#endif

#if compiler(>=6)
extension PendingApproval: Sendable {}
#endif

#if compiler(>=6)
extension PendingUserInputAnswer: Sendable {}
#endif

#if compiler(>=6)
extension PendingUserInputOption: Sendable {}
#endif

#if compiler(>=6)
extension PendingUserInputQuestion: Sendable {}
#endif

#if compiler(>=6)
extension PendingUserInputRequest: Sendable {}
#endif

#if compiler(>=6)
extension PinnedThreadKey: Sendable {}
#endif

#if compiler(>=6)
extension RateLimitSnapshot: Sendable {}
#endif

#if compiler(>=6)
extension RateLimitWindow: Sendable {}
#endif

#if compiler(>=6)
extension RateLimits: Sendable {}
#endif

#if compiler(>=6)
extension ReasoningEffortOption: Sendable {}
#endif

#if compiler(>=6)
extension ReconnectResult: Sendable {}
#endif

#if compiler(>=6)
extension ResolvedImageViewResult: Sendable {}
#endif

#if compiler(>=6)
extension SavedServerRecord: Sendable {}
#endif

#if compiler(>=6)
extension SkillDependencies: Sendable {}
#endif

#if compiler(>=6)
extension SkillInterface: Sendable {}
#endif

#if compiler(>=6)
extension SkillMetadata: Sendable {}
#endif

#if compiler(>=6)
extension SkillToolDependency: Sendable {}
#endif

#if compiler(>=6)
extension SshCredentialRecord: Sendable {}
#endif

#if compiler(>=6)
extension StreamedItem: Sendable {}
#endif

#if compiler(>=6)
extension ThreadInfo: Sendable {}
#endif

#if compiler(>=6)
extension ThreadKey: Sendable {}
#endif

#if compiler(>=6)
extension TranscriptDeltaResult: Sendable {}
#endif

#if compiler(>=6)
extension Account: Sendable {}
#endif

#if compiler(>=6)
extension AppAskForApproval: Sendable {}
#endif

#if compiler(>=6)
extension AppConnectionStepKind: Sendable {}
#endif

#if compiler(>=6)
extension AppConnectionStepState: Sendable {}
#endif

#if compiler(>=6)
extension AppDiscoverySource: Sendable {}
#endif

#if compiler(>=6)
extension AppLoginAccountRequest: Sendable {}
#endif

#if compiler(>=6)
extension AppMergeStrategy: Sendable {}
#endif

#if compiler(>=6)
extension AppMessagePhase: Sendable {}
#endif

#if compiler(>=6)
extension AppMessageRenderBlock: Sendable {}
#endif

#if compiler(>=6)
extension AppMessageSegment: Sendable {}
#endif

#if compiler(>=6)
extension AppModeKind: Sendable {}
#endif

#if compiler(>=6)
extension AppNetworkAccess: Sendable {}
#endif

#if compiler(>=6)
extension AppOperationStatus: Sendable {}
#endif

#if compiler(>=6)
extension AppPlanStepStatus: Sendable {}
#endif

#if compiler(>=6)
extension AppQueuedFollowUpKind: Sendable {}
#endif

#if compiler(>=6)
extension AppReadOnlyAccess: Sendable {}
#endif

#if compiler(>=6)
extension AppRealtimeOutputModality: Sendable {}
#endif

#if compiler(>=6)
extension AppRealtimeStartTransport: Sendable {}
#endif

#if compiler(>=6)
extension AppRealtimeVoice: Sendable {}
#endif

#if compiler(>=6)
extension AppReviewTarget: Sendable {}
#endif

#if compiler(>=6)
extension AppSandboxMode: Sendable {}
#endif

#if compiler(>=6)
extension AppSandboxPolicy: Sendable {}
#endif

#if compiler(>=6)
extension AppServerHealth: Sendable {}
#endif

#if compiler(>=6)
extension AppServerIpcState: Sendable {}
#endif

#if compiler(>=6)
extension AppServerTransportState: Sendable {}
#endif

#if compiler(>=6)
extension AppStoreUpdateRecord: Sendable {}
#endif

#if compiler(>=6)
extension AppSubagentStatus: Sendable {}
#endif

#if compiler(>=6)
extension AppThreadPermissionPreset: Sendable {}
#endif

#if compiler(>=6)
extension AppToolCallKind: Sendable {}
#endif

#if compiler(>=6)
extension AppToolCallSectionContent: Sendable {}
#endif

#if compiler(>=6)
extension AppUserInput: Sendable {}
#endif

#if compiler(>=6)
extension AppVoiceSessionPhase: Sendable {}
#endif

#if compiler(>=6)
extension AppVoiceSpeaker: Sendable {}
#endif

#if compiler(>=6)
extension ApprovalDecisionValue: Sendable {}
#endif

#if compiler(>=6)
extension ApprovalKind: Sendable {}
#endif

#if compiler(>=6)
extension AuthMode: Sendable {}
#endif

#if compiler(>=6)
extension ClientError: Sendable {}
#endif

#if compiler(>=6)
extension ComputerUseTool: Sendable {}
#endif

#if compiler(>=6)
extension FileSearchMatchType: Sendable {}
#endif

#if compiler(>=6)
extension HandoffAction: Sendable {}
#endif

#if compiler(>=6)
extension HandoffPhase: Sendable {}
#endif

#if compiler(>=6)
extension HydratedCommandActionKind: Sendable {}
#endif

#if compiler(>=6)
extension HydratedConversationItemContent: Sendable {}
#endif

#if compiler(>=6)
extension HydratedDividerData: Sendable {}
#endif

#if compiler(>=6)
extension HydratedPlanStepStatus: Sendable {}
#endif

#if compiler(>=6)
extension InputModality: Sendable {}
#endif

#if compiler(>=6)
extension PlanType: Sendable {}
#endif

#if compiler(>=6)
extension ProgressiveDiscoveryUpdateKind: Sendable {}
#endif

#if compiler(>=6)
extension ReasoningEffort: Sendable {}
#endif

#if compiler(>=6)
extension ServiceTier: Sendable {}
#endif

#if compiler(>=6)
extension SkillScope: Sendable {}
#endif

#if compiler(>=6)
extension SshAuthMethodRecord: Sendable {}
#endif

#if compiler(>=6)
extension ThreadStreamingDeltaKind: Sendable {}
#endif

#if compiler(>=6)
extension ThreadSummaryStatus: Sendable {}
#endif

#if compiler(>=6)
extension TitleSegment: Sendable {}
#endif

#if compiler(>=6)
extension ToolCallStatus: Sendable {}
#endif

class AppClient: @unchecked Sendable {
    struct NoHandle { init() {} }
    required init(unsafeFromHandle handle: UInt64) {}
    init(noHandle: NoHandle) {}
    convenience init() { self.init(noHandle: NoHandle()) }

    func appendRealtimeAudio(serverId: String, params: AppAppendRealtimeAudioRequest) async throws { throw LocalBridgeError.unsupported("append realtime audio") }
    func appendRealtimeText(serverId: String, params: AppAppendRealtimeTextRequest) async throws { throw LocalBridgeError.unsupported("append realtime text") }
    func archiveThread(serverId: String, params: AppArchiveThreadRequest) async throws { throw LocalBridgeError.unsupported("archive thread") }
    func authStatus(serverId: String, params: AuthStatusRequest) async throws -> AuthStatus { try unsupported("auth status") }
    func createRemoteDirectory(serverId: String, path: String) async throws { throw LocalBridgeError.unsupported("create remote directory") }
    func execCommand(serverId: String, params: AppExecCommandRequest) async throws -> CommandExecResult { try unsupported("execute command") }
    func finalizeRealtimeHandoff(serverId: String, params: AppFinalizeRealtimeHandoffRequest) async throws { throw LocalBridgeError.unsupported("finalize realtime handoff") }
    func forkThread(serverId: String, params: AppForkThreadRequest) async throws -> ThreadKey { try unsupported("fork thread") }
    func interruptTurn(serverId: String, params: AppInterruptTurnRequest) async throws { throw LocalBridgeError.unsupported("interrupt turn") }
    func listCollaborationModes(serverId: String) async throws -> [AppCollaborationModePreset] { [] }
    func listRemoteDirectory(serverId: String, path: String) async throws -> DirectoryListResult { try unsupported("list remote directory") }
    func listSkills(serverId: String, params: AppListSkillsRequest) async throws -> [SkillMetadata] { [] }
    func listThreads(serverId: String, params: AppListThreadsRequest) async throws { throw LocalBridgeError.unsupported("list threads") }
    func loginAccount(serverId: String, params: AppLoginAccountRequest) async throws { throw LocalBridgeError.unsupported("login account") }
    func logoutAccount(serverId: String) async throws { throw LocalBridgeError.unsupported("logout account") }
    func readThread(serverId: String, params: AppReadThreadRequest) async throws -> ThreadKey { try unsupported("read thread") }
    func refreshAccount(serverId: String, params: AppRefreshAccountRequest) async throws { throw LocalBridgeError.unsupported("refresh account") }
    func refreshModels(serverId: String, params: AppRefreshModelsRequest) async throws { throw LocalBridgeError.unsupported("refresh models") }
    func refreshRateLimits(serverId: String) async throws { throw LocalBridgeError.unsupported("refresh rate limits") }
    func renameThread(serverId: String, params: AppRenameThreadRequest) async throws { throw LocalBridgeError.unsupported("rename thread") }
    func resolveImageView(serverId: String, path: String) async throws -> ResolvedImageViewResult { try unsupported("resolve image view") }
    func resolveRealtimeHandoff(serverId: String, params: AppResolveRealtimeHandoffRequest) async throws { throw LocalBridgeError.unsupported("resolve realtime handoff") }
    func resolveRemoteHome(serverId: String) async throws -> String { NSHomeDirectory() }
    func resumeThread(serverId: String, params: AppResumeThreadRequest) async throws -> ThreadKey { try unsupported("resume thread") }
    func searchFiles(serverId: String, params: AppSearchFilesRequest) async throws -> [FileSearchResult] { [] }
    func startRealtimeSession(serverId: String, params: AppStartRealtimeSessionRequest) async throws { throw LocalBridgeError.unsupported("start realtime session") }
    func startRemoteSshOauthLogin(serverId: String) async throws -> String { try unsupported("start remote SSH OAuth") }
    func startReview(serverId: String, params: AppStartReviewRequest) async throws { throw LocalBridgeError.unsupported("start review") }
    func startThread(serverId: String, params: AppStartThreadRequest) async throws -> ThreadKey { try unsupported("start thread") }
    func stopRealtimeSession(serverId: String, params: AppStopRealtimeSessionRequest) async throws {}
    func writeConfigValue(serverId: String, params: AppWriteConfigValueRequest) async throws {}
}

class AppStore: @unchecked Sendable {
    struct NoHandle { init() {} }
    required init(unsafeFromHandle handle: UInt64) {}
    init(noHandle: NoHandle) {}
    convenience init() { self.init(noHandle: NoHandle()) }

    func deleteQueuedFollowUp(key: ThreadKey, previewId: String) async throws {}
    func dismissPlanImplementationPrompt(key: ThreadKey) {}
    func editMessage(key: ThreadKey, selectedTurnIndex: UInt32) async throws -> String { "" }
    func externalResumeThread(key: ThreadKey, hostId: String?) async throws { throw LocalBridgeError.unsupported("external resume thread") }
    func forkThreadFromMessage(key: ThreadKey, selectedTurnIndex: UInt32, params: AppForkThreadFromMessageRequest) async throws -> ThreadKey { try unsupported("fork thread from message") }
    func implementPlan(key: ThreadKey) async throws {}
    func isRecording() -> Bool { false }
    func renameServer(serverId: String, displayName: String) {}
    func respondToApproval(requestId: String, decision: ApprovalDecisionValue) async throws { throw LocalBridgeError.unsupported("respond to approval") }
    func respondToUserInput(requestId: String, answers: [PendingUserInputAnswer]) async throws { throw LocalBridgeError.unsupported("respond to user input") }
    func setActiveThread(key: ThreadKey?) {}
    func setThreadCollaborationMode(key: ThreadKey, mode: AppModeKind) async throws { throw LocalBridgeError.unsupported("set collaboration mode") }
    func setVoiceHandoffThread(key: ThreadKey?) {}
    func snapshot() async throws -> AppSnapshotRecord { try unsupported("snapshot") }
    func startRecording() {}
    func startReplay(data: String, targetKey: ThreadKey) async throws { throw LocalBridgeError.unsupported("start replay") }
    func startTurn(key: ThreadKey, params: AppStartTurnRequest) async throws { throw LocalBridgeError.unsupported("start turn") }
    func steerQueuedFollowUp(key: ThreadKey, previewId: String) async throws {}
    func stopRecording() -> String { "{}" }
    func subscribeUpdates() -> AppStoreSubscription { AppStoreSubscription(noHandle: AppStoreSubscription.NoHandle()) }
    func threadSnapshot(key: ThreadKey) async throws -> AppThreadSnapshot? { nil }
}

class AppStoreSubscription: @unchecked Sendable {
    struct NoHandle { init() {} }
    required init(unsafeFromHandle handle: UInt64) {}
    init(noHandle: NoHandle) {}
    convenience init() { self.init(noHandle: NoHandle()) }
    func nextUpdate() async throws -> AppStoreUpdateRecord { try unsupported("next update") }
}

class ServerBridge: @unchecked Sendable {
    struct NoHandle { init() {} }
    required init(unsafeFromHandle handle: UInt64) {}
    init(noHandle: NoHandle) {}
    convenience init() { self.init(noHandle: NoHandle()) }
    func connectLocalServer(serverId: String, displayName: String, host: String, port: UInt16) async throws -> String { try unsupported("connect local server") }
    func connectRemoteServer(serverId: String, displayName: String, host: String, port: UInt16) async throws -> String { try unsupported("connect remote server") }
    func connectRemoteUrlServer(serverId: String, displayName: String, websocketUrl: String) async throws -> String { try unsupported("connect remote URL server") }
    func disconnectServer(serverId: String) {}
}

class MessageParser: @unchecked Sendable {
    init() {}
    required init(unsafeFromHandle handle: UInt64) {}
    func extractRenderBlocksTyped(text: String) -> [AppMessageRenderBlock] { [.markdown(markdown: text)] }
    func extractSegmentsTyped(text: String) -> [AppMessageSegment] { [.text(text: text)] }
    func parseCodeReviewTyped(text: String) -> AppCodeReviewPayload? { nil }
    func parseToolCallsTyped(text: String) -> [AppToolCallCard] { [] }
}

class RemotePath: @unchecked Sendable {
    private let path: String
    private init(path: String) { self.path = path.isEmpty ? "/" : path }
    required init(unsafeFromHandle handle: UInt64) { self.path = "/" }
    static func parse(path: String) -> RemotePath { RemotePath(path: path) }
    func asString() -> String { path }
    func isRoot() -> Bool { path == "/" || path.isEmpty }
    func isWindows() -> Bool { path.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil }
    func join(name: String) -> RemotePath {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        if path == "/" { return RemotePath(path: "/" + trimmed) }
        return RemotePath(path: (path as NSString).appendingPathComponent(trimmed))
    }
    func parent() -> RemotePath {
        guard !isRoot() else { return self }
        let parent = (path as NSString).deletingLastPathComponent
        return RemotePath(path: parent.isEmpty ? "/" : parent)
    }
    func segments() -> [DirectoryPathSegment] {
        let parts = path.split(separator: "/").map(String.init)
        var running = ""
        return parts.map { part in
            running += "/" + part
            return DirectoryPathSegment(label: part, fullPath: running)
        }
    }
}

class HandoffManager: @unchecked Sendable {
    static func create(localServerId: String) -> HandoffManager { HandoffManager() }
    init() {}
    required init(unsafeFromHandle handle: UInt64) {}
    func uniffiRegisterServer(serverId: String, name: String, hostname: String, isLocal: Bool, isConnected: Bool) {}
    func uniffiUnregisterServer(serverId: String) {}
    func uniffiSetTurnConfig(model: String?, effort: String?, fastMode: Bool) {}
    func uniffiHandleHandoffRequest(handoffId: String, voiceServerId: String, voiceThreadId: String, inputTranscript: String, activeTranscript: String, serverHint: String?, fallbackTranscript: String?) {}
    func uniffiReportThreadCreated(handoffId: String, serverId: String, threadId: String) {}
    func uniffiReportThreadFailed(handoffId: String, error: String) {}
    func uniffiReportTurnSent(handoffId: String, baseItemCount: UInt32) {}
    func uniffiReportTurnFailed(handoffId: String, error: String) {}
    func uniffiReportFinalized(handoffId: String) {}
    func uniffiReset() {}
    func uniffiPollStreamProgress(handoffId: String, items: [StreamedItem], turnActive: Bool) {}
    func uniffiDrainActions() -> [HandoffAction] { [] }
    func uniffiAccumulateTranscriptDelta(delta: String, speaker: String) -> TranscriptDeltaResult {
        TranscriptDeltaResult(fullText: delta, previousText: nil, speakerChanged: false)
    }
    func uniffiListServersJson() -> String { "[]" }
}

func threadPermissionPreset(approvalPolicy: AppAskForApproval?, sandboxPolicy: AppSandboxPolicy?) -> AppThreadPermissionPreset {
    if case .never? = approvalPolicy, case .dangerFullAccess? = sandboxPolicy { return .fullAccess }
    if approvalPolicy != nil || sandboxPolicy != nil { return .custom }
    return .supervised
}

func threadPermissionsAreAuthoritative(approvalPolicy: AppAskForApproval?, sandboxPolicy: AppSandboxPolicy?) -> Bool {
    approvalPolicy != nil || sandboxPolicy != nil
}

func parsePluginRefs(input: String) -> [TitleSegment] {
    [.text(text: input)]
}

private struct PreferencesPayload: Codable {
    var pinnedThreads: [PinnedThreadKeyPayload] = []
    var hiddenThreads: [PinnedThreadKeyPayload] = []
    var selectedServerId: String?
    var selectedProjectId: String?
}

private struct PinnedThreadKeyPayload: Codable, Hashable {
    var serverId: String
    var threadId: String
}

private func preferencesURL(directory: String) -> URL {
    URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("mobile-preferences.json")
}

private func loadPreferencesPayload(directory: String) -> PreferencesPayload {
    let url = preferencesURL(directory: directory)
    guard let data = try? Data(contentsOf: url), let payload = try? JSONDecoder().decode(PreferencesPayload.self, from: data) else {
        return PreferencesPayload()
    }
    return payload
}

private func savePreferencesPayload(_ payload: PreferencesPayload, directory: String) {
    let url = preferencesURL(directory: directory)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(payload) {
        try? data.write(to: url, options: .atomic)
    }
}

private func mobilePreferences(from payload: PreferencesPayload) -> MobilePreferences {
    MobilePreferences(
        pinnedThreads: payload.pinnedThreads.map { PinnedThreadKey(serverId: $0.serverId, threadId: $0.threadId) },
        hiddenThreads: payload.hiddenThreads.map { PinnedThreadKey(serverId: $0.serverId, threadId: $0.threadId) },
        homeSelection: HomeSelection(selectedServerId: payload.selectedServerId, selectedProjectId: payload.selectedProjectId)
    )
}

private func payload(from preferences: MobilePreferences) -> PreferencesPayload {
    PreferencesPayload(
        pinnedThreads: preferences.pinnedThreads.map { PinnedThreadKeyPayload(serverId: $0.serverId, threadId: $0.threadId) },
        hiddenThreads: preferences.hiddenThreads.map { PinnedThreadKeyPayload(serverId: $0.serverId, threadId: $0.threadId) },
        selectedServerId: preferences.homeSelection.selectedServerId,
        selectedProjectId: preferences.homeSelection.selectedProjectId
    )
}

func preferencesLoad(directory: String) -> MobilePreferences {
    mobilePreferences(from: loadPreferencesPayload(directory: directory))
}

func preferencesSave(directory: String, value: MobilePreferences) -> MobilePreferences {
    savePreferencesPayload(payload(from: value), directory: directory)
    return preferencesLoad(directory: directory)
}

func preferencesAddPinnedThread(directory: String, key: PinnedThreadKey) -> MobilePreferences {
    var preferences = preferencesLoad(directory: directory)
    preferences.pinnedThreads.removeAll { $0 == key }
    preferences.pinnedThreads.insert(key, at: 0)
    return preferencesSave(directory: directory, value: preferences)
}

func preferencesRemovePinnedThread(directory: String, key: PinnedThreadKey) -> MobilePreferences {
    var preferences = preferencesLoad(directory: directory)
    preferences.pinnedThreads.removeAll { $0 == key }
    return preferencesSave(directory: directory, value: preferences)
}

func preferencesAddHiddenThread(directory: String, key: PinnedThreadKey) -> MobilePreferences {
    var preferences = preferencesLoad(directory: directory)
    preferences.hiddenThreads.removeAll { $0 == key }
    preferences.hiddenThreads.insert(key, at: 0)
    return preferencesSave(directory: directory, value: preferences)
}

func preferencesRemoveHiddenThread(directory: String, key: PinnedThreadKey) -> MobilePreferences {
    var preferences = preferencesLoad(directory: directory)
    preferences.hiddenThreads.removeAll { $0 == key }
    return preferencesSave(directory: directory, value: preferences)
}

func preferencesSetHomeSelection(directory: String, selection: HomeSelection) -> MobilePreferences {
    var preferences = preferencesLoad(directory: directory)
    preferences.homeSelection = selection
    return preferencesSave(directory: directory, value: preferences)
}

func deriveProjects(sessions: [AppSessionSummary]) -> [AppProject] {
    let grouped = Dictionary(grouping: sessions.filter { !$0.cwd.isEmpty }) { session in
        projectIdFor(serverId: session.key.serverId, cwd: session.cwd)
    }
    return grouped.compactMap { id, sessions in
        guard let first = sessions.first else { return nil }
        let latest = sessions.compactMap(\.updatedAt).max()
        return AppProject(id: id, serverId: first.key.serverId, cwd: first.cwd, lastUsedAtMs: latest)
    }.sorted { ($0.lastUsedAtMs ?? 0) > ($1.lastUsedAtMs ?? 0) }
}

func projectDefaultLabel(cwd: String) -> String {
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Home" }
    let label = URL(fileURLWithPath: trimmed).lastPathComponent
    return label.isEmpty ? trimmed : label
}

func projectIdFor(serverId: String, cwd: String) -> String {
    "\(serverId):\(cwd)"
}

func generativeUiDynamicToolSpecs() -> [AppDynamicToolSpec] { [] }
