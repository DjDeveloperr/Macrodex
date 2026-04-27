import Foundation
import Observation

struct ConversationTranscriptSnapshot: Equatable {
    var items: [ConversationItem]
    var threadStatus: ConversationStatus
    var agentDirectoryVersion: UInt64
    var renderDigest: Int

    static let empty = ConversationTranscriptSnapshot(
        items: [],
        threadStatus: .ready,
        agentDirectoryVersion: 0,
        renderDigest: 0
    )

    static func == (lhs: ConversationTranscriptSnapshot, rhs: ConversationTranscriptSnapshot) -> Bool {
        lhs.threadStatus == rhs.threadStatus
            && lhs.agentDirectoryVersion == rhs.agentDirectoryVersion
            && lhs.renderDigest == rhs.renderDigest
    }
}

struct ConversationComposerSnapshot: Equatable {
    var threadKey: ThreadKey
    var collaborationMode: AppModeKind
    var activePlanProgress: AppPlanProgressSnapshot?
    var pendingPlanImplementationPrompt: AppPlanImplementationPromptSnapshot?
    var pendingUserInputRequest: PendingUserInputRequest?
    var activeTaskSummary: ConversationActiveTaskSummary?
    var queuedFollowUps: [AppQueuedFollowUpPreview]
    var composerPrefillRequest: AppModel.ComposerPrefillRequest?
    var activeTurnId: String?
    var isTurnActive: Bool
    var threadPreview: String
    var threadModel: String
    var threadReasoningEffort: String?
    var modelContextWindow: Int64?
    var contextTokensUsed: Int64?
    var rateLimits: RateLimitSnapshot?
    var availableModels: [ModelInfo]
    var isConnected: Bool

    static let empty = ConversationComposerSnapshot(
        threadKey: ThreadKey(serverId: "", threadId: ""),
        collaborationMode: .`default`,
        activePlanProgress: nil,
        pendingPlanImplementationPrompt: nil,
        pendingUserInputRequest: nil,
        activeTaskSummary: nil,
        queuedFollowUps: [],
        composerPrefillRequest: nil,
        activeTurnId: nil,
        isTurnActive: false,
        threadPreview: "",
        threadModel: "",
        threadReasoningEffort: nil,
        modelContextWindow: nil,
        contextTokensUsed: nil,
        rateLimits: nil,
        availableModels: [],
        isConnected: false
    )
}

struct ConversationActiveTaskSummary: Equatable {
    var progressLabel: String
    var title: String
    var detail: String
}

@MainActor
@Observable
final class ConversationScreenModel {
    private(set) var transcript: ConversationTranscriptSnapshot = .empty
    private(set) var pinnedContextItems: [ConversationItem] = []
    private(set) var composer: ConversationComposerSnapshot = .empty
    private(set) var followScrollToken = 0

    @ObservationIgnored private var thread: AppThreadSnapshot?
    @ObservationIgnored private var appModel: AppModel?
    @ObservationIgnored private var agentDirectoryVersion: UInt64 = 0
    @ObservationIgnored private var cachedConversationItemProjections: [String: CachedConversationItemProjection] = [:]
    @ObservationIgnored private var cachedHydratedConversationItems: [HydratedConversationItem] = []
    @ObservationIgnored private var cachedProjectedConversationItems: [ConversationItem] = []
    @ObservationIgnored private var transcriptRevision: Int = 0
    @ObservationIgnored private var forceNextTranscriptRefresh = false

    func bind(
        thread: AppThreadSnapshot,
        appModel: AppModel,
        agentDirectoryVersion: UInt64
    ) {
        let threadChanged =
            self.thread?.key != thread.key ||
            self.appModel !== appModel

        self.thread = thread
        self.appModel = appModel
        self.agentDirectoryVersion = agentDirectoryVersion

        if threadChanged {
            followScrollToken = 0
            cachedHydratedConversationItems = []
            cachedConversationItemProjections = [:]
            cachedProjectedConversationItems = []
            transcriptRevision = 0
            forceNextTranscriptRefresh = true
        }

        refreshState()
    }

    private func refreshState() {
        guard let thread, let appModel else {
            transcript = .empty
            pinnedContextItems = []
            composer = .empty
            followScrollToken = 0
            return
        }

        let currentTranscript = transcript

        let projection = projectConversationItems(from: thread.hydratedConversationItems)
        let items = projection.items
        let threadStatus = conversationStatus(from: thread)
        let activeTurnId: String?
        if let value = thread.activeTurnId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            activeTurnId = value
        } else {
            activeTurnId = nil
        }
        let hasTurnInFlight = activeTurnId != nil || thread.info.status == .active
        let pendingUserInputRequest = appModel.snapshot?.pendingUserInputs.first {
            $0.serverId == thread.key.serverId && $0.threadId == thread.key.threadId
        }
        let activeTaskSummary = items.latestActiveTaskSummary
        let composerPrefillRequest = appModel.composerPrefillRequest.flatMap { request in
            request.threadKey == thread.key ? request : nil
        }
        let composerSnapshot = ConversationComposerSnapshot(
            threadKey: thread.key,
            collaborationMode: thread.collaborationMode,
            activePlanProgress: thread.activePlanProgress,
            pendingPlanImplementationPrompt: thread.pendingPlanImplementationPrompt,
            pendingUserInputRequest: pendingUserInputRequest,
            activeTaskSummary: activeTaskSummary,
            queuedFollowUps: thread.queuedFollowUps,
            composerPrefillRequest: composerPrefillRequest,
            activeTurnId: activeTurnId,
            isTurnActive: activeTurnId != nil,
            threadPreview: thread.resolvedPreview,
            threadModel: thread.resolvedModel,
            threadReasoningEffort: thread.reasoningEffort,
            modelContextWindow: thread.modelContextWindow.map(Int64.init),
            contextTokensUsed: thread.contextTokensUsed.map(Int64.init),
            rateLimits: appModel.rateLimits(for: thread.key.serverId),
            availableModels: appModel.availableModels(for: thread.key.serverId),
            isConnected: appModel.snapshot?.serverSnapshot(for: thread.key.serverId)?.isConnected ?? false
        )

        let transcriptChanged =
            forceNextTranscriptRefresh
            ||
            projection.didChange
            || currentTranscript.threadStatus != threadStatus
            || currentTranscript.agentDirectoryVersion != agentDirectoryVersion
        if transcriptChanged {
            transcriptRevision &+= 1
            forceNextTranscriptRefresh = false
            if hasTurnInFlight {
                LLog.trace("streaming", "transcript changed during turn", fields: [
                    "projDidChange": projection.didChange,
                    "itemCount": items.count,
                    "revision": transcriptRevision,
                    "threadStatus": String(describing: threadStatus)
                ])
            }
        }
        let nextTranscript = ConversationTranscriptSnapshot(
            items: transcriptChanged ? items : currentTranscript.items,
            threadStatus: threadStatus,
            agentDirectoryVersion: agentDirectoryVersion,
            renderDigest: transcriptChanged ? transcriptRevision : currentTranscript.renderDigest
        )
        var nextFollowScrollToken = followScrollToken
        if hasTurnInFlight,
           projection.didChange {
            nextFollowScrollToken &+= 1
        }
        if transcript != nextTranscript {
            transcript = nextTranscript
            pinnedContextItems = items
        }
        if composer != composerSnapshot {
            composer = composerSnapshot
        }
        if followScrollToken != nextFollowScrollToken {
            followScrollToken = nextFollowScrollToken
        }
    }
}

private struct CachedConversationItemProjection {
    let hydratedItem: HydratedConversationItem
    let conversationItem: ConversationItem
}

private struct ProjectedConversationItemsResult {
    let items: [ConversationItem]
    let didChange: Bool
}

private extension ConversationScreenModel {
    func projectConversationItems(from hydratedItems: [HydratedConversationItem]) -> ProjectedConversationItemsResult {
        let previousHydratedItems = cachedHydratedConversationItems
        if previousHydratedItems == hydratedItems {
            return ProjectedConversationItemsResult(
                items: cachedProjectedConversationItems,
                didChange: false
            )
        }

        var nextCache: [String: CachedConversationItemProjection] = [:]
        nextCache.reserveCapacity(hydratedItems.count)

        var rawItems: [ConversationItem] = []
        rawItems.reserveCapacity(hydratedItems.count)

        for hydratedItem in hydratedItems {
            let conversationItem: ConversationItem
            if let cached = cachedConversationItemProjections[hydratedItem.id],
               cached.hydratedItem == hydratedItem {
                conversationItem = cached.conversationItem
            } else {
                conversationItem = hydratedItem.conversationItem
            }

            rawItems.append(conversationItem)
            nextCache[hydratedItem.id] = CachedConversationItemProjection(
                hydratedItem: hydratedItem,
                conversationItem: conversationItem
            )
        }

        let projectedItems = collapseAdjacentToolItems(rawItems)
        cachedHydratedConversationItems = hydratedItems
        cachedConversationItemProjections = nextCache
        cachedProjectedConversationItems = projectedItems
        return ProjectedConversationItemsResult(items: projectedItems, didChange: true)
    }

    func collapseAdjacentToolItems(_ items: [ConversationItem]) -> [ConversationItem] {
        var collapsed: [ConversationItem] = []
        collapsed.reserveCapacity(items.count)

        for item in items {
            if let last = collapsed.last,
               let merged = mergeAdjacentToolItems(last, item) {
                collapsed[collapsed.count - 1] = merged
            } else {
                collapsed.append(item)
            }
        }

        return collapsed
    }

    func mergeAdjacentToolItems(_ lhs: ConversationItem, _ rhs: ConversationItem) -> ConversationItem? {
        guard let lhsTurnId = lhs.sourceTurnId,
              lhsTurnId == rhs.sourceTurnId else {
            return nil
        }

        if case .webSearch(let lhsData) = lhs.content,
           case .webSearch(let rhsData) = rhs.content {
            let entries = webSearchEntries(from: lhsData) + [webSearchEntry(from: rhsData)]
            return ConversationItem(
                id: lhs.id,
                content: .webSearch(ConversationWebSearchData(
                    query: rhsData.query,
                    actionJSON: jsonString(["searches": entries]),
                    isInProgress: lhsData.isInProgress || rhsData.isInProgress
                )),
                sourceTurnId: lhs.sourceTurnId,
                sourceTurnIndex: lhs.sourceTurnIndex,
                timestamp: rhs.timestamp,
                isFromUserTurnBoundary: lhs.isFromUserTurnBoundary
            )
        }

        guard let lhsEntry = workingToolEntry(from: lhs),
              let rhsEntry = workingToolEntry(from: rhs) else {
            return nil
        }

        let entries = workingToolEntries(from: lhs) ?? [lhsEntry]
        let mergedEntries = entries + [rhsEntry]
        return ConversationItem(
            id: lhs.id,
            content: .dynamicToolCall(ConversationDynamicToolCallData(
                tool: "Working",
                status: mergedWorkingStatus(lhs: lhs, rhs: rhs),
                durationMs: nil,
                success: nil,
                argumentsJSON: nil,
                contentSummary: jsonString(["calls": mergedEntries])
            )),
            sourceTurnId: lhs.sourceTurnId,
            sourceTurnIndex: lhs.sourceTurnIndex,
            timestamp: rhs.timestamp,
            isFromUserTurnBoundary: lhs.isFromUserTurnBoundary
        )
    }

    func commonPrefixCount(
        lhs: [HydratedConversationItem],
        rhs: [HydratedConversationItem]
    ) -> Int {
        let maxCount = min(lhs.count, rhs.count)
        var index = 0
        while index < maxCount, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    func commonSuffixCount(
        lhs: [HydratedConversationItem],
        rhs: [HydratedConversationItem],
        excludingPrefix prefixCount: Int
    ) -> Int {
        let maxCount = min(lhs.count, rhs.count) - prefixCount
        guard maxCount > 0 else { return 0 }

        var suffixCount = 0
        while suffixCount < maxCount {
            let lhsIndex = lhs.index(lhs.endIndex, offsetBy: -suffixCount - 1)
            let rhsIndex = rhs.index(rhs.endIndex, offsetBy: -suffixCount - 1)
            guard lhs[lhsIndex] == rhs[rhsIndex] else { break }
            suffixCount += 1
        }
        return suffixCount
    }

    func webSearchEntries(from data: ConversationWebSearchData) -> [[String: Any]] {
        guard let actionJSON = data.actionJSON,
              let actionData = actionJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: actionData) as? [String: Any],
              let searches = object["searches"] as? [[String: Any]] else {
            return [webSearchEntry(from: data)]
        }
        return searches
    }

    func webSearchEntry(from data: ConversationWebSearchData) -> [String: Any] {
        var entry: [String: Any] = [
            "query": data.query,
            "status": data.isInProgress ? "in_progress" : "completed"
        ]
        if let actionJSON = data.actionJSON, !actionJSON.isEmpty {
            entry["action"] = decodedJSONValue(from: actionJSON) ?? actionJSON
        }
        return entry
    }

    func workingToolEntries(from item: ConversationItem) -> [[String: Any]]? {
        guard case .dynamicToolCall(let data) = item.content,
              data.tool == "Working",
              let contentSummary = data.contentSummary,
              let summaryData = contentSummary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any],
              let calls = object["calls"] as? [[String: Any]] else {
            return nil
        }
        return calls
    }

    func workingToolEntry(from item: ConversationItem) -> [String: Any]? {
        switch item.content {
        case .dynamicToolCall(let data):
            guard !data.isHiddenMetadataTool,
                  !CrossServerTools.isRichTool(data.tool) else {
                return nil
            }
            var entry: [String: Any] = [
                "kind": "dynamic_tool",
                "tool": data.tool,
                "status": statusString(data.status)
            ]
            if let argumentsJSON = data.argumentsJSON, !argumentsJSON.isEmpty {
                entry["arguments"] = decodedJSONValue(from: argumentsJSON) ?? argumentsJSON
            }
            if let contentSummary = data.contentSummary, !contentSummary.isEmpty {
                entry["result"] = decodedJSONValue(from: contentSummary) ?? contentSummary
            }
            if let success = data.success {
                entry["success"] = success
            }
            return entry
        case .mcpToolCall(let data):
            guard data.computerUse == nil else { return nil }
            var entry: [String: Any] = [
                "kind": "mcp_tool",
                "server": data.server,
                "tool": data.tool,
                "status": statusString(data.status)
            ]
            if let argumentsJSON = data.argumentsJSON, !argumentsJSON.isEmpty {
                entry["arguments"] = decodedJSONValue(from: argumentsJSON) ?? argumentsJSON
            }
            if let contentSummary = data.contentSummary, !contentSummary.isEmpty {
                entry["result"] = decodedJSONValue(from: contentSummary) ?? contentSummary
            }
            if let structuredContentJSON = data.structuredContentJSON, !structuredContentJSON.isEmpty {
                entry["structured"] = decodedJSONValue(from: structuredContentJSON) ?? structuredContentJSON
            }
            if let rawOutputJSON = data.rawOutputJSON, !rawOutputJSON.isEmpty {
                entry["raw_output"] = decodedJSONValue(from: rawOutputJSON) ?? rawOutputJSON
            }
            if let errorMessage = data.errorMessage, !errorMessage.isEmpty {
                entry["error"] = errorMessage
            }
            if !data.progressMessages.isEmpty {
                entry["progress"] = data.progressMessages
            }
            return entry
        default:
            return nil
        }
    }

    func mergedWorkingStatus(lhs: ConversationItem, rhs: ConversationItem) -> AppOperationStatus {
        let statuses = [workingStatus(from: lhs), workingStatus(from: rhs)]
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.inProgress) { return .inProgress }
        if statuses.contains(.pending) { return .pending }
        if statuses.contains(.declined) { return .declined }
        if statuses.allSatisfy({ $0 == .completed }) { return .completed }
        return statuses.last ?? .unknown
    }

    func workingStatus(from item: ConversationItem) -> AppOperationStatus {
        switch item.content {
        case .dynamicToolCall(let data):
            return data.status
        case .mcpToolCall(let data):
            return data.status
        default:
            return .unknown
        }
    }

    func statusString(_ status: AppOperationStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .inProgress: return "in_progress"
        case .completed: return "completed"
        case .failed: return "failed"
        case .declined: return "declined"
        }
    }

    func decodedJSONValue(from string: String) -> Any? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private func conversationStatus(from thread: AppThreadSnapshot) -> ConversationStatus {
    switch thread.info.status {
    case .active:
        return .thinking
    case .systemError:
        return .error("Chat error")
    case .notLoaded:
        return .connecting
    case .idle:
        return .ready
    }
}

private extension Array where Element == ConversationItem {
    var latestActiveTaskSummary: ConversationActiveTaskSummary? {
        for item in reversed() {
            guard case .todoList(let data) = item.content else { continue }
            let total = data.steps.count
            guard total > 0 else { continue }

            let activeSteps = data.steps.filter { $0.status != .completed }
            guard !activeSteps.isEmpty else { continue }

            let completed = data.completedCount
            let focusStep = data.steps.first(where: { $0.status == .inProgress })
                ?? data.steps.first(where: { $0.status == .pending })
                ?? activeSteps.first
            let detail = focusStep?.step.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title: String
            if activeSteps.count == 1 {
                title = "1 active task"
            } else {
                title = "\(activeSteps.count) active tasks"
            }

            return ConversationActiveTaskSummary(
                progressLabel: "\(completed)/\(total)",
                title: title,
                detail: detail.isEmpty ? title : detail
            )
        }

        return nil
    }
}

#if DEBUG
extension ConversationScreenModel {
    func _testProjectConversationItems(
        from hydratedItems: [HydratedConversationItem]
    ) -> [ConversationItem] {
        projectConversationItems(from: hydratedItems).items
    }
}
#endif
