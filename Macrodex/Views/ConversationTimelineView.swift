import SwiftUI
import HairballUI
import UIKit

enum ConversationLiveDetailRetentionPolicy {
    static func retainedRichDetailItemIDs(for items: [ConversationItem]) -> Set<String> {
        var retained = Set<String>()

        if let active = items.last(where: { $0.liveDetailStatus == .inProgress }) {
            retained.insert(active.id)
        }

        if let latestCompleted = items.reversed().first(where: { item in
            guard let status = item.liveDetailStatus else { return false }
            return status != .inProgress
        }) {
            retained.insert(latestCompleted.id)
        }

        return retained
    }
}

struct ConversationTurnTimeline: View {
    let items: [ConversationItem]
    let isLive: Bool
    let serverId: String
    let agentDirectoryVersion: UInt64
    let messageActionsDisabled: Bool
    let onStreamingSnapshotRendered: (() -> Void)?
    let resolveTargetLabel: (String) -> String?
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil

    var body: some View {
        timelineContent
    }

    private var timelineContent: some View {
        let rows = rowDescriptors
        let retainedRichDetailItemIDs = ConversationLiveDetailRetentionPolicy.retainedRichDetailItemIDs(for: items)
        let latestCommandExecutionItemId = rows.reversed().compactMap { row -> String? in
            guard case .item(let item) = row,
                  case .commandExecution(let data) = item.content,
                  !data.isPureExploration else { return nil }
            return item.id
        }.first

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(
                    row,
                    isLastRow: index == rows.indices.last,
                    isPreferredExpandedCommandRow: row.preferredExpandedCommandRow(
                        latestCommandExecutionItemId: latestCommandExecutionItemId
                    ),
                    retainedRichDetailItemIDs: retainedRichDetailItemIDs
                )
                    .id(row.id)
                    .modifier(RowEntranceModifier(isAssistantRow: row.isAssistantRow))
            }
        }
    }

    private var rowDescriptors: [ConversationTimelineRowDescriptor] {
        ConversationTimelineRowDescriptor.mergeConsecutiveExplorationRows(
            ConversationTimelineRowDescriptor.build(from: items)
        )
    }

    private var streamingAssistantItemId: String? {
        guard isLive else { return nil }
        return items.last(where: \.isAssistantItem)?.id
    }

    // Returns AnyView rather than `some View` with @ViewBuilder so the result
    // type doesn't fan out to Group<_ConditionalContent<_ConditionalContent<…>, …>>.
    // Time Profiler showed 44% of main-thread CPU in `outlined destroy` of that
    // nested union; AnyView's per-node diff overhead is cheaper than destroying
    // the union every SwiftUI pass.
    private func rowView(
        _ row: ConversationTimelineRowDescriptor,
        isLastRow: Bool,
        isPreferredExpandedCommandRow: Bool,
        retainedRichDetailItemIDs: Set<String>
    ) -> AnyView {
        switch row {
        case .item(let item):
            return AnyView(
                ConversationTimelineItemRow(
                    item: item,
                    serverId: serverId,
                    agentDirectoryVersion: agentDirectoryVersion,
                    isPreferredExpandedCommandRow: isPreferredExpandedCommandRow,
                    isLiveTurn: isLive,
                    isStreamingMessage: item.id == streamingAssistantItemId,
                    shouldPreserveRichDetail: retainedRichDetailItemIDs.contains(item.id),
                    messageActionsDisabled: messageActionsDisabled,
                    onStreamingSnapshotRendered: item.id == streamingAssistantItemId ? onStreamingSnapshotRendered : nil,
                    resolveTargetLabel: resolveTargetLabel,
                    onEditUserItem: onEditUserItem,
                    onForkFromUserItem: onForkFromUserItem,
                    onOpenConversation: onOpenConversation
                )
                .equatable()
            )
        case .exploration(let id, let items):
            return AnyView(
                ConversationExplorationGroupRow(
                    id: id,
                    items: items,
                    showsCollapsedPreview: isLastRow
                )
            )
        case .subagentGroup(_, let merged, _):
            return AnyView(
                SubagentCardView(
                    data: merged,
                    serverId: serverId
                )
            )
        case .toolGroup(_, let items):
            return AnyView(
                ConversationToolGroupRow(
                    items: items,
                    serverId: serverId
                )
            )
        }
    }
}

private enum ConversationTimelineRowDescriptor: Identifiable, Equatable {
    case item(ConversationItem)
    case exploration(id: String, items: [ConversationItem])
    case subagentGroup(id: String, merged: ConversationMultiAgentActionData, sourceItems: [ConversationItem])
    case toolGroup(id: String, items: [ConversationItem])

    var id: String {
        switch self {
        case .item(let item):
            return item.id
        case .exploration(let id, _):
            return id
        case .subagentGroup(let id, _, _):
            return id
        case .toolGroup(let id, _):
            return id
        }
    }

    var isAssistantRow: Bool {
        guard case .item(let item) = self else { return false }
        return item.isAssistantItem
    }

    func preferredExpandedCommandRow(latestCommandExecutionItemId: String?) -> Bool {
        guard case .item(let item) = self,
              case .commandExecution(let data) = item.content,
              !data.isPureExploration else {
            return false
        }
        return item.id == latestCommandExecutionItemId
    }

    static func build(from items: [ConversationItem]) -> [ConversationTimelineRowDescriptor] {
        var rows: [ConversationTimelineRowDescriptor] = []
        var explorationBuffer: [ConversationItem] = []
        var subagentBuffer: [(item: ConversationItem, data: ConversationMultiAgentActionData)] = []
        var subagentTool: String?
        var toolBuffer: [ConversationItem] = []
        var toolTurnId: String?

        func flushExplorationBuffer() {
            guard !explorationBuffer.isEmpty else { return }
            let seed = explorationBuffer.first?.id ?? UUID().uuidString
            rows.append(.exploration(id: "exploration-\(seed)", items: explorationBuffer))
            explorationBuffer.removeAll(keepingCapacity: true)
        }

        func flushToolBuffer() {
            guard !toolBuffer.isEmpty else { return }
            if toolBuffer.count == 1 {
                rows.append(.item(toolBuffer[0]))
            } else {
                let seed = toolBuffer.first?.id ?? UUID().uuidString
                rows.append(.toolGroup(id: "tool-group-\(seed)", items: toolBuffer))
            }
            toolBuffer.removeAll(keepingCapacity: true)
            toolTurnId = nil
        }

        func flushSubagentBuffer() {
            guard !subagentBuffer.isEmpty else { return }
            if subagentBuffer.count == 1 {
                rows.append(.item(subagentBuffer[0].item))
            } else {
                let seed = subagentBuffer.first?.item.id ?? UUID().uuidString
                // Merge all targets, threadIds, states, pick the latest status
                var mergedTargets: [String] = []
                var mergedThreadIds: [String] = []
                var mergedStates: [ConversationMultiAgentState] = []
                var mergedPrompts: [String] = []
                var latestStatus: AppOperationStatus = .completed
                let tool = subagentBuffer.first?.data.tool ?? "spawnAgent"

                for entry in subagentBuffer {
                    mergedTargets.append(contentsOf: entry.data.targets)
                    mergedThreadIds.append(contentsOf: entry.data.receiverThreadIds)
                    mergedStates.append(contentsOf: entry.data.agentStates)
                    if let p = entry.data.prompt, !p.isEmpty {
                        mergedPrompts.append(p)
                    }
                    if entry.data.isInProgress {
                        latestStatus = .inProgress
                    }
                }

                let merged = ConversationMultiAgentActionData(
                    tool: tool,
                    status: latestStatus,
                    prompt: nil,
                    targets: mergedTargets,
                    receiverThreadIds: mergedThreadIds,
                    agentStates: mergedStates,
                    perAgentPrompts: mergedPrompts
                )
                rows.append(.subagentGroup(
                    id: "subagent-group-\(seed)",
                    merged: merged,
                    sourceItems: subagentBuffer.map(\.item)
                ))
            }
            subagentBuffer.removeAll(keepingCapacity: true)
            subagentTool = nil
        }

        for item in items {
            if item.isVisuallyEmptyNeutralItem {
                continue
            } else if case .multiAgentAction(let data) = item.content {
                let tool = data.tool.lowercased()
                if let currentTool = subagentTool, currentTool == tool {
                    subagentBuffer.append((item, data))
                } else {
                    flushExplorationBuffer()
                    flushToolBuffer()
                    flushSubagentBuffer()
                    subagentBuffer.append((item, data))
                    subagentTool = tool
                }
            } else if item.isTimelineToolCallItem {
                flushExplorationBuffer()
                flushSubagentBuffer()
                let turnId = item.sourceTurnId
                if let currentToolTurnId = toolTurnId, currentToolTurnId != turnId {
                    flushToolBuffer()
                }
                toolBuffer.append(item)
                toolTurnId = turnId
            } else if case .commandExecution(let data) = item.content, data.isPureExploration {
                flushSubagentBuffer()
                flushToolBuffer()
                explorationBuffer.append(item)
            } else {
                flushExplorationBuffer()
                flushSubagentBuffer()
                flushToolBuffer()
                rows.append(.item(item))
            }
        }

        flushExplorationBuffer()
        flushSubagentBuffer()
        flushToolBuffer()
        return rows
    }

    static func mergeConsecutiveExplorationRows(
        _ rows: [ConversationTimelineRowDescriptor]
    ) -> [ConversationTimelineRowDescriptor] {
        var mergedRows: [ConversationTimelineRowDescriptor] = []
        var explorationAccumulator: (id: String, items: [ConversationItem])?

        func flushAccumulator() {
            guard let accumulator = explorationAccumulator else { return }
            mergedRows.append(
                .exploration(
                    id: accumulator.id,
                    items: accumulator.items
                )
            )
            explorationAccumulator = nil
        }

        for row in rows {
            switch row {
            case .exploration(let id, let items):
                if var existing = explorationAccumulator {
                    existing.items.append(contentsOf: items)
                    explorationAccumulator = existing
                } else {
                    explorationAccumulator = (id: id, items: items)
                }
            case .item(let item) where item.isExplorationCommandItem:
                if var existing = explorationAccumulator {
                    existing.items.append(item)
                    explorationAccumulator = existing
                } else {
                    explorationAccumulator = (id: "exploration-\(item.id)", items: [item])
                }
            default:
                flushAccumulator()
                mergedRows.append(row)
            }
        }

        flushAccumulator()
        return mergedRows
    }
}

private struct RowEntranceModifier: ViewModifier {
    let isAssistantRow: Bool

    func body(content: Content) -> some View {
        if isAssistantRow {
            // Block the ambient withAnimation transaction from leaking into
            // the streaming markdown renderer, which would replay the token
            // reveal animation on every snapshot update.
            content
                .transaction { $0.animation = nil }
        } else {
            content
                .transition(.asymmetric(
                    insertion: .rowEntranceReveal,
                    removal: .opacity
                ))
        }
    }
}

struct RowEntranceEffect: ViewModifier, Animatable {
    var progress: CGFloat
    var yOffset: CGFloat
    var minScale: CGFloat
    var maxBlur: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let clampedProgress = min(max(progress, 0), 1)
        let revealProgress = max(clampedProgress, 0.001)

        content
            .compositingGroup()
            .scaleEffect(
                x: 1,
                y: minScale + ((1 - minScale) * clampedProgress),
                anchor: .topLeading
            )
            .offset(y: yOffset * (1 - clampedProgress))
            .opacity(clampedProgress)
            .blur(radius: maxBlur * (1 - clampedProgress))
            .mask(alignment: .topLeading) {
                Rectangle()
                    .scaleEffect(x: 1, y: revealProgress, anchor: .topLeading)
            }
    }
}

extension AnyTransition {
    static var rowEntranceReveal: AnyTransition {
        .modifier(
            active: RowEntranceEffect(progress: 0, yOffset: 10, minScale: 0.965, maxBlur: 2.5),
            identity: RowEntranceEffect(progress: 1, yOffset: 0, minScale: 1, maxBlur: 0)
        )
    }

    static var sectionReveal: AnyTransition {
        .modifier(
            active: RowEntranceEffect(progress: 0, yOffset: 6, minScale: 0.985, maxBlur: 1.2),
            identity: RowEntranceEffect(progress: 1, yOffset: 0, minScale: 1, maxBlur: 0)
        )
    }
}

private struct ConversationTimelineItemRow: View, Equatable {
    private let renderCache = MessageRenderCache.shared
    @Environment(ThemeManager.self) private var themeManager

    let item: ConversationItem
    let serverId: String
    let agentDirectoryVersion: UInt64
    let isPreferredExpandedCommandRow: Bool
    let isLiveTurn: Bool
    let isStreamingMessage: Bool
    let shouldPreserveRichDetail: Bool
    let messageActionsDisabled: Bool
    let onStreamingSnapshotRendered: (() -> Void)?
    let resolveTargetLabel: (String) -> String?
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil

    static func == (lhs: ConversationTimelineItemRow, rhs: ConversationTimelineItemRow) -> Bool {
        let isAssistant = lhs.item.isAssistantItem
        // For assistant rows: the StreamingRendererCoordinator owns the
        // streaming→finished lifecycle.  Skip digest, richDetail, AND
        // isStreamingMessage so the bubble body never re-evaluates when
        // a tool call arrives and a new assistant message takes over as
        // the "streaming" item.  Re-rendering the bubble would recreate
        // StreamingMarkdownContentView and replay the token reveal.
        let result = lhs.item.id == rhs.item.id &&
            (isAssistant || lhs.item.renderDigest == rhs.item.renderDigest) &&
            (isAssistant || lhs.shouldPreserveRichDetail == rhs.shouldPreserveRichDetail) &&
            (isAssistant || lhs.isStreamingMessage == rhs.isStreamingMessage) &&
            lhs.serverId == rhs.serverId &&
            lhs.agentDirectoryVersion == rhs.agentDirectoryVersion &&
            lhs.isPreferredExpandedCommandRow == rhs.isPreferredExpandedCommandRow &&
            lhs.isLiveTurn == rhs.isLiveTurn &&
            lhs.messageActionsDisabled == rhs.messageActionsDisabled
        return result
    }

    // 16-case switch returns AnyView rather than `some View` so the body type
    // doesn't resolve to a 4-deep `Group<_ConditionalContent<…>>` nested union.
    // Time Profiler on 2026-04-18 showed that union's `outlined destroy` +
    // witness-table accessor accounting for ~49% of main-thread CPU on device.
    var body: AnyView {
        switch item.content {
        case .user(let data):
            return AnyView(userRow(data))
        case .assistant(let data):
            return AnyView(assistantRow(data))
        case .codeReview(let data):
            return AnyView(ConversationCodeReviewRow(data: data))
        case .reasoning(let data):
            return AnyView(ConversationReasoningRow(data: data))
        case .todoList(let data):
            return AnyView(ConversationTodoListRow(data: data))
        case .proposedPlan(let data):
            return AnyView(ConversationProposedPlanRow(data: data))
        case .commandExecution(let data):
            return AnyView(commandExecutionRow(data))
        case .fileChange(let data):
            return AnyView(toolCallRow(makeFileChangeModel(data)))
        case .turnDiff:
            return AnyView(EmptyView())
        case .mcpToolCall(let data):
            if let view = data.computerUse {
                return AnyView(
                    ComputerUseToolCallView(
                        data: data,
                        view: view,
                        externalExpanded: !isLiveTurn && shouldPreserveRichDetail
                    )
                )
            } else if let groupedModels = ToolCallTimelineModelFactory.groupedMcpModels(from: data) {
                return AnyView(ToolCallGroupCardView(models: groupedModels, serverId: serverId))
            } else {
                return AnyView(toolCallRow(makeMcpModel(data)))
            }
        case .dynamicToolCall(let data):
            if CrossServerTools.isRichTool(data.tool) {
                return AnyView(CrossServerToolResultView(data: data))
            } else {
                return AnyView(toolCallRow(makeDynamicToolModel(data)))
            }
        case .multiAgentAction(let data):
            return AnyView(
                SubagentCardView(
                    data: data,
                    serverId: serverId
                )
            )
        case .webSearch(let data):
            return AnyView(toolCallRow(makeWebSearchModel(data)))
        case .imageView(let data):
            return AnyView(toolCallRow(makeImageViewModel(data)))
        case .imageGeneration(let data):
            return AnyView(
                ImageGenerationToolCallView(
                    data: data,
                    externalExpanded: !isLiveTurn && shouldPreserveRichDetail
                )
            )
        case .userInputResponse(let data):
            return AnyView(ConversationUserInputResponseRow(data: data))
        case .divider(let kind):
            return AnyView(ConversationDividerRow(kind: kind, isLiveTurn: isLiveTurn))
        case .error(let data):
            return AnyView(
                ConversationSystemCardRow(
                    title: data.title.isEmpty ? "Error" : data.title,
                    content: [data.message, data.details].compactMap { $0 }.joined(separator: "\n\n"),
                    accent: MacrodexTheme.danger,
                    iconName: "exclamationmark.triangle.fill",
                )
            )
        case .note(let data):
            return AnyView(
                ConversationSystemCardRow(
                    title: data.title,
                    content: data.body,
                    accent: MacrodexTheme.accent,
                    iconName: "info.circle.fill"
                )
            )
        }
    }

    @ViewBuilder
    private func commandExecutionRow(_ data: ConversationCommandExecutionData) -> some View {
        ConversationCommandExecutionRow(
            data: data,
            isPreferredExpanded: isPreferredExpandedCommandRow
                || data.isInProgress
                || (!isLiveTurn && shouldPreserveRichDetail)
        )
    }

    @ViewBuilder
    private func toolCallRow(_ model: ToolCallCardModel) -> some View {
        ToolCallCardView(
            model: model,
            serverId: serverId,
            externalExpanded: !isLiveTurn && shouldPreserveRichDetail
        )
    }

    private func userRow(_ data: ConversationUserMessageData) -> some View {
        UserBubble(text: data.text, images: data.images)
            .contextMenu {
                if item.isFromUserTurnBoundary {
                    Button("Edit Message") {
                        onEditUserItem(item)
                    }
                    .disabled(messageActionsDisabled)

                    Button("Fork From Here") {
                        onForkFromUserItem(item)
                    }
                    .disabled(messageActionsDisabled)
                }
            }
    }

    @ViewBuilder
    private func assistantRow(_ data: ConversationAssistantMessageData) -> some View {
        let assistantLabel = AgentLabelFormatter.format(
            nickname: data.agentNickname,
            role: data.agentRole
        )

        StreamingAssistantBubble(
            itemId: item.id,
            text: data.text,
            isStreaming: isStreamingMessage,
            label: assistantLabel,
            themeVersion: themeManager.themeVersion,
            onSnapshotRendered: isStreamingMessage ? onStreamingSnapshotRendered : nil
        )
    }

    private func makeFileChangeModel(_ data: ConversationFileChangeData) -> ToolCallCardModel {
        let changedPaths = data.changes.map(\.path)
        let summary = fileChangeSummary(for: data)

        var sections: [ToolCallSection] = []
        if !changedPaths.isEmpty {
            sections.append(.list(label: "Files", items: changedPaths.map(workspaceTitle(for:))))
        }
        if let outputDelta = data.outputDelta?.trimmingCharacters(in: .whitespacesAndNewlines), !outputDelta.isEmpty {
            sections.append(.text(label: "Output", content: outputDelta))
        }

        return ToolCallCardModel(
            kind: .fileChange,
            title: "File Change",
            summary: summary.plainText,
            attributedSummary: summary.attributedText,
            status: data.status.toolCallStatus,
            duration: nil,
            sections: sections
        )
    }

    private func fileChangeSummary(for data: ConversationFileChangeData) -> (plainText: String, attributedText: AttributedString?) {
        guard !data.changes.isEmpty else {
            return ("File changes", nil)
        }

        let additions = data.changes.reduce(0) { $0 + $1.additions }
        let deletions = data.changes.reduce(0) { $0 + $1.deletions }
        let hasCountSummary = additions > 0 || deletions > 0

        if data.changes.count == 1, let change = data.changes.first {
            let verb = fileChangeVerb(for: change.kind)
            let filename = workspaceTitle(for: change.path)
            guard hasCountSummary else {
                return ("\(verb) \(filename)", nil)
            }

            let plainText = "\(verb) \(filename) +\(additions) -\(deletions)"

            var attributed = AttributedString()

            var verbText = AttributedString("\(verb) ")
            verbText.foregroundColor = MacrodexTheme.textSecondary
            attributed.append(verbText)

            var fileText = AttributedString(filename)
            fileText.foregroundColor = MacrodexTheme.accent
            attributed.append(fileText)

            var additionsText = AttributedString(" +\(additions)")
            additionsText.foregroundColor = MacrodexTheme.success
            attributed.append(additionsText)

            var deletionsText = AttributedString(" -\(deletions)")
            deletionsText.foregroundColor = MacrodexTheme.danger
            attributed.append(deletionsText)

            return (plainText, attributed)
        }

        guard hasCountSummary else {
            return ("Changed \(data.changes.count) files", nil)
        }

        let plainText = "Changed \(data.changes.count) files +\(additions) -\(deletions)"
        var attributed = AttributedString("Changed \(data.changes.count) files")
        attributed.foregroundColor = MacrodexTheme.textSystem

        var additionsText = AttributedString(" +\(additions)")
        additionsText.foregroundColor = MacrodexTheme.success
        attributed.append(additionsText)

        var deletionsText = AttributedString(" -\(deletions)")
        deletionsText.foregroundColor = MacrodexTheme.danger
        attributed.append(deletionsText)

        return (plainText, attributed)
    }

    private func fileChangeVerb(for kind: String) -> String {
        switch kind.lowercased() {
        case "add":
            return "Added"
        case "delete":
            return "Deleted"
        case "update":
            return "Edited"
        default:
            return "Changed"
        }
    }

    private func makeMcpModel(_ data: ConversationMcpToolCallData) -> ToolCallCardModel {
        var sections: [ToolCallSection] = []
        if let arguments = data.argumentsJSON, !arguments.isEmpty {
            sections.append(.json(label: "Arguments", content: arguments))
        }
        if let contentSummary = data.contentSummary, !contentSummary.isEmpty {
            if data.tool == "Working",
               contentSummary.contains("\"calls\"") {
                sections.append(.json(label: "Calls", content: contentSummary))
            } else {
                sections.append(.text(label: "Result", content: contentSummary))
            }
        }
        if let structured = data.structuredContentJSON, !structured.isEmpty {
            sections.append(.json(label: "Structured", content: structured))
        }
        if let raw = data.rawOutputJSON, !raw.isEmpty {
            sections.append(.json(label: "Raw Output", content: raw))
        }
        if !data.progressMessages.isEmpty {
            sections.append(.progress(label: "Progress", items: data.progressMessages))
        }
        if let error = data.errorMessage, !error.isEmpty {
            sections.append(.text(label: "Error", content: error))
        }

        let summary = data.server.isEmpty
            ? data.tool
            : "\(data.server).\(data.tool)"

        return ToolCallCardModel(
            kind: .mcpToolCall,
            title: "MCP Tool Call",
            summary: summary,
            status: data.status.toolCallStatus,
            duration: nil,
            sections: sections
        )
    }

    private func makeDynamicToolModel(_ data: ConversationDynamicToolCallData) -> ToolCallCardModel {
        var sections: [ToolCallSection] = []
        if let arguments = data.argumentsJSON, !arguments.isEmpty {
            sections.append(.json(label: "Arguments", content: arguments))
        }
        if let contentSummary = data.contentSummary, !contentSummary.isEmpty {
            sections.append(.text(label: "Result", content: contentSummary))
        }
        if let success = data.success {
            sections.insert(
                .kv(label: "Metadata", entries: [ToolCallKeyValue(key: "Success", value: success ? "true" : "false")]),
                at: 0
            )
        }

        return ToolCallCardModel(
            kind: .mcpToolCall,
            title: "Dynamic Tool Call",
            summary: data.tool,
            status: data.status.toolCallStatus,
            duration: nil,
            sections: sections
        )
    }

    private func makeWebSearchModel(_ data: ConversationWebSearchData) -> ToolCallCardModel {
        var sections: [ToolCallSection] = []
        if !data.query.isEmpty {
            sections.append(.text(label: "Query", content: data.query))
        }
        if let action = data.actionJSON, !action.isEmpty {
            sections.append(.json(label: action.contains("\"searches\"") ? "Searches" : "Action", content: action))
        }
        return ToolCallCardModel(
            kind: .webSearch,
            title: "Web Search",
            summary: data.query.isEmpty ? "Web search" : "Web search for \(data.query)",
            status: data.isInProgress ? .inProgress : .completed,
            duration: nil,
            sections: sections
        )
    }

    private func makeImageViewModel(_ data: ConversationImageViewData) -> ToolCallCardModel {
        let trimmedPath = data.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = workspaceTitle(for: trimmedPath)
        return ToolCallCardModel(
            kind: .imageView,
            title: "Image View",
            summary: displayName.isEmpty ? "Image" : displayName,
            status: .completed,
            duration: nil,
            sections: [
                .kv(
                    label: "Metadata",
                    entries: [ToolCallKeyValue(key: "Path", value: trimmedPath)]
                )
            ],
            initiallyExpanded: true
        )
    }
}

private struct ConversationToolGroupRow: View {
    let items: [ConversationItem]
    let serverId: String

    var body: some View {
        ToolCallGroupCardView(models: models, serverId: serverId)
    }

    private var models: [ToolCallCardModel] {
        items.flatMap(ToolCallTimelineModelFactory.models(for:))
    }
}

private enum ToolCallTimelineModelFactory {
    static func models(for item: ConversationItem) -> [ToolCallCardModel] {
        switch item.content {
        case .mcpToolCall(let data):
            if data.computerUse != nil { return [] }
            return groupedMcpModels(from: data) ?? [makeMcpModel(data)]
        case .dynamicToolCall(let data):
            if CrossServerTools.isRichTool(data.tool) { return [] }
            return [makeDynamicToolModel(data)]
        case .webSearch(let data):
            return [makeWebSearchModel(data)]
        default:
            return []
        }
    }

    static func groupedMcpModels(from data: ConversationMcpToolCallData) -> [ToolCallCardModel]? {
        guard data.tool == "Working",
              let contentSummary = data.contentSummary,
              contentSummary.contains("\"calls\""),
              let root = jsonObject(from: contentSummary) as? [String: Any],
              let calls = root["calls"] as? [[String: Any]],
              !calls.isEmpty else {
            return nil
        }

        return calls.enumerated().map { index, call in
            makeWorkingCallModel(call, fallbackData: data, index: index)
        }
    }

    private static func makeMcpModel(_ data: ConversationMcpToolCallData) -> ToolCallCardModel {
        var sections: [ToolCallSection] = []
        if let arguments = data.argumentsJSON, !arguments.isEmpty {
            sections.append(.json(label: "Arguments", content: arguments))
        }
        if let contentSummary = data.contentSummary, !contentSummary.isEmpty {
            if data.tool == "Working",
               contentSummary.contains("\"calls\"") {
                sections.append(.json(label: "Calls", content: contentSummary))
            } else {
                sections.append(.text(label: "Result", content: contentSummary))
            }
        }
        if let structured = data.structuredContentJSON, !structured.isEmpty {
            sections.append(.json(label: "Structured", content: structured))
        }
        if let raw = data.rawOutputJSON, !raw.isEmpty {
            sections.append(.json(label: "Raw Output", content: raw))
        }
        if !data.progressMessages.isEmpty {
            sections.append(.progress(label: "Progress", items: data.progressMessages))
        }
        if let error = data.errorMessage, !error.isEmpty {
            sections.append(.text(label: "Error", content: error))
        }

        let summary = data.server.isEmpty
            ? data.tool
            : "\(data.server).\(data.tool)"

        return ToolCallCardModel(
            kind: .mcpToolCall,
            title: "MCP Tool Call",
            summary: summary,
            status: data.status.toolCallStatus,
            duration: nil,
            sections: sections
        )
    }

    private static func makeDynamicToolModel(_ data: ConversationDynamicToolCallData) -> ToolCallCardModel {
        var sections: [ToolCallSection] = []
        if let arguments = data.argumentsJSON, !arguments.isEmpty {
            sections.append(.json(label: "Arguments", content: arguments))
        }
        if let contentSummary = data.contentSummary, !contentSummary.isEmpty {
            sections.append(.text(label: "Result", content: contentSummary))
        }
        if let success = data.success {
            sections.insert(
                .kv(label: "Metadata", entries: [ToolCallKeyValue(key: "Success", value: success ? "true" : "false")]),
                at: 0
            )
        }

        return ToolCallCardModel(
            kind: .mcpToolCall,
            title: "Dynamic Tool Call",
            summary: data.tool,
            status: data.status.toolCallStatus,
            duration: nil,
            sections: sections
        )
    }

    private static func makeWebSearchModel(_ data: ConversationWebSearchData) -> ToolCallCardModel {
        var sections: [ToolCallSection] = []
        if !data.query.isEmpty {
            sections.append(.text(label: "Query", content: data.query))
        }
        if let action = data.actionJSON, !action.isEmpty {
            sections.append(.json(label: action.contains("\"searches\"") ? "Searches" : "Action", content: action))
        }
        return ToolCallCardModel(
            kind: .webSearch,
            title: "Web Search",
            summary: data.query.isEmpty ? "Web search" : "Web search for \(data.query)",
            status: data.isInProgress ? .inProgress : .completed,
            duration: nil,
            sections: sections
        )
    }

    private static func makeWorkingCallModel(
        _ call: [String: Any],
        fallbackData: ConversationMcpToolCallData,
        index: Int
    ) -> ToolCallCardModel {
        let tool = stringValue(call["tool"])
            ?? stringValue(call["name"])
            ?? stringValue(call["function"])
            ?? "Tool \(index + 1)"
        let server = stringValue(call["server"]) ?? fallbackData.server
        let purpose = stringValue(call["purpose"])
        let summary = server.isEmpty ? tool : "\(server).\(tool)"
        var sections: [ToolCallSection] = []

        if let arguments = call["arguments"] ?? call["args"] ?? call["input"],
           let section = payloadSection(label: "Arguments", value: arguments) {
            sections.append(section)
        }
        if let purpose, !sections.description.localizedCaseInsensitiveContains("\"purpose\"") {
            sections.insert(
                .json(label: "Arguments", content: jsonObjectString(["purpose": purpose]) ?? #"{"purpose":"\#(purpose)"}"#),
                at: 0
            )
        }
        if let result = call["result"] ?? call["output"] ?? call["content"] ?? call["contentSummary"],
           let section = payloadSection(label: "Result", value: result) {
            sections.append(section)
        }
        if let error = stringValue(call["error"] ?? call["errorMessage"]), !error.isEmpty {
            sections.append(.text(label: "Error", content: error))
        }
        if let success = boolValue(call["success"]) {
            sections.insert(
                .kv(label: "Metadata", entries: [ToolCallKeyValue(key: "Success", value: success ? "true" : "false")]),
                at: 0
            )
        }

        return ToolCallCardModel(
            kind: .mcpToolCall,
            title: "Tool Call",
            summary: summary,
            status: statusValue(call["status"]) ?? fallbackData.status.toolCallStatus,
            duration: nil,
            sections: sections
        )
    }

    private static func payloadSection(label: String, value: Any) -> ToolCallSection? {
        if value is NSNull { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                return .json(label: label, content: trimmed)
            }
            return .text(label: label, content: trimmed)
        }
        if let json = jsonObjectString(value) {
            return .json(label: label, content: json)
        }
        return .text(label: label, content: String(describing: value))
    }

    private static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        let slice = String(text[start...end])
        guard let sliceData = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: sliceData)
    }

    private static func jsonObjectString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func statusValue(_ value: Any?) -> ToolCallStatus? {
        guard let raw = stringValue(value)?.lowercased() else { return nil }
        if raw.contains("progress") || raw.contains("running") || raw.contains("pending") {
            return .inProgress
        }
        if raw.contains("fail") || raw.contains("error") {
            return .failed
        }
        if raw.contains("complete") || raw.contains("success") || raw.contains("done") {
            return .completed
        }
        return nil
    }
}

private extension ConversationItem {
    var isTimelineToolCallItem: Bool {
        switch content {
        case .mcpToolCall(let data):
            return data.computerUse == nil
        case .dynamicToolCall(let data):
            return !CrossServerTools.isRichTool(data.tool)
        case .webSearch:
            return true
        default:
            return false
        }
    }
}

private struct ConversationExplorationGroupRow: View {
    @Environment(\.textScale) private var textScale

    let id: String
    let items: [ConversationItem]
    let showsCollapsedPreview: Bool

    @State private var isDetailPresented = false

    var body: some View {
        Button {
            isDetailPresented = true
        } label: {
            HStack(spacing: 8) {
                Text("Working")
                    .macrodexFont(size: MacrodexFont.conversationBodyPointSize)
                    .foregroundColor(MacrodexTheme.textSystem)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows work details")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .sheet(isPresented: $isDetailPresented) {
            detailSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var summaryText: String {
        let prefix = isActive ? "Exploring" : "Explored"
        return explorationSummaryText(prefix: prefix)
    }

    private var explorationBulletSize: CGFloat {
        6 * textScale
    }

    private var explorationBulletTopPadding: CGFloat {
        5 * textScale
    }

    private var isActive: Bool {
        explorationEntries.contains(where: \.isInProgress)
    }

    private var explorationEntries: [ExplorationDisplayEntry] {
        items.flatMap { item -> [ExplorationDisplayEntry] in
            guard case .commandExecution(let data) = item.content else { return [] }
            if data.actions.isEmpty {
                return [
                    ExplorationDisplayEntry(
                        id: "\(item.id)-command",
                        label: data.command,
                        isInProgress: data.isInProgress
                    )
                ]
            }
            return data.actions.enumerated().map { index, action in
                ExplorationDisplayEntry(
                    id: "\(item.id)-\(index)",
                    label: explorationLabel(for: action, fallback: data.command),
                    isInProgress: data.isInProgress
                )
            }
        }
    }

    private func explorationSummaryText(prefix: String) -> String {
        var readCount = 0
        var searchCount = 0
        var listingCount = 0
        var fallbackCount = 0

        for item in items {
            guard case .commandExecution(let data) = item.content else { continue }
            if data.actions.isEmpty {
                fallbackCount += 1
                continue
            }
            for action in data.actions {
                switch action.kind {
                case .read:
                    readCount += 1
                case .search:
                    searchCount += 1
                case .listFiles:
                    listingCount += 1
                case .unknown:
                    fallbackCount += 1
                }
            }
        }

        var parts: [String] = []
        if readCount > 0 {
            parts.append("\(readCount) \(readCount == 1 ? "file" : "files")")
        }
        if searchCount > 0 {
            parts.append("\(searchCount) \(searchCount == 1 ? "search" : "searches")")
        }
        if listingCount > 0 {
            parts.append("\(listingCount) \(listingCount == 1 ? "listing" : "listings")")
        }
        if fallbackCount > 0 {
            parts.append("\(fallbackCount) \(fallbackCount == 1 ? "step" : "steps")")
        }
        if parts.isEmpty {
            let count = explorationEntries.count
            return count == 1 ? "\(prefix) 1 exploration step" : "\(prefix) \(count) exploration steps"
        }
        return "\(prefix) \(parts.joined(separator: ", "))"
    }

    private func explorationLabel(for action: ConversationCommandAction, fallback: String) -> String {
        switch action.kind {
        case .read:
            return action.path.map { "Read \(workspaceTitle(for: $0))" } ?? fallback
        case .search:
            if let query = action.query, let path = action.path {
                return "Searched for \(query) in \(workspaceTitle(for: path))"
            }
            if let query = action.query {
                return "Searched for \(query)"
            }
            return fallback
        case .listFiles:
            return action.path.map { "Listed files in \(workspaceTitle(for: $0))" } ?? fallback
        case .unknown:
            return fallback
        }
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Working")
                            .macrodexFont(.headline, weight: .semibold)
                            .foregroundColor(MacrodexTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(summaryText)
                            .macrodexFont(.callout)
                            .foregroundColor(MacrodexTheme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(explorationEntries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(entry.isInProgress ? MacrodexTheme.warning : MacrodexTheme.textMuted)
                                    .frame(width: explorationBulletSize, height: explorationBulletSize)
                                    .padding(.top, explorationBulletTopPadding)
                                Text(verbatim: entry.label)
                                    .macrodexFont(.caption)
                                    .foregroundColor(MacrodexTheme.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Work Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isDetailPresented = false
                    }
                }
            }
        }
    }
}

private struct ExplorationDisplayEntry: Identifiable {
    let id: String
    let label: String
    let isInProgress: Bool
}

private struct ConversationReasoningRow: View {
    let data: ConversationReasoningData

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(reasoningText)
                .macrodexFont(.footnote)
                .italic()
                .foregroundColor(MacrodexTheme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 20)
        }
    }

    private var reasoningText: String {
        (data.summary + data.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}

private struct ConversationTodoListRow: View {
    let data: ConversationTodoListData
    private let bodySize: CGFloat = 13
    private let codeSize: CGFloat = 12
    @State private var isDetailPresented = false

    var body: some View {
        Button {
            isDetailPresented = true
        } label: {
            HStack(spacing: 8) {
                Text("Working")
                    .macrodexFont(size: MacrodexFont.conversationBodyPointSize)
                    .foregroundColor(MacrodexTheme.textSystem)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows task details")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .sheet(isPresented: $isDetailPresented) {
            detailSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var completedCount: Int {
        data.completedCount
    }

    private var hasInProgressStep: Bool {
        data.steps.contains { $0.status == .inProgress }
    }

    private var summaryText: String {
        "\(completedCount) out of \(data.steps.count) task\(data.steps.count == 1 ? "" : "s") completed"
    }

    private var progressTint: Color {
        data.isComplete ? MacrodexTheme.success : (hasInProgressStep ? MacrodexTheme.warning : MacrodexTheme.textSecondary)
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Working")
                            .macrodexFont(.headline, weight: .semibold)
                            .foregroundColor(MacrodexTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(summaryText)
                            .macrodexFont(.callout, weight: .semibold)
                            .foregroundColor(progressTint)
                    }

                    todoListContent
                }
                .padding(16)
            }
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isDetailPresented = false
                    }
                }
            }
        }
    }

    private var todoListContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(data.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    todoStatusView(for: step.status)
                        .padding(.top, 2)
                    Text("\(index + 1).")
                        .macrodexFont(.caption, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textMuted)
                        .padding(.top, 1)
                    MacrodexMarkdownView(
                        markdown: step.step,
                        style: .content,
                        bodySize: bodySize,
                        codeSize: codeSize
                    )
                    .strikethrough(step.status == .completed, color: MacrodexTheme.textMuted)
                    .opacity(step.status == .completed ? 0.78 : 1.0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func todoStatusView(for status: HydratedPlanStepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .macrodexFont(size: 11, weight: .semibold)
                .foregroundColor(MacrodexTheme.textMuted)
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
                .tint(MacrodexTheme.warning)
                .frame(width: 11, height: 11)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .macrodexFont(size: 11, weight: .semibold)
                .foregroundColor(MacrodexTheme.success)
        }
    }
}

private struct ConversationProposedPlanRow: View {
    let data: ConversationProposedPlanData

    private var trimmedContent: String? {
        let trimmed = data.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        if let trimmedContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.portrait.fill")
                        .macrodexFont(size: 12, weight: .semibold)
                        .foregroundColor(MacrodexTheme.accent)
                    Text("Plan")
                        .macrodexFont(.caption, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textPrimary)
                }

                MacrodexMarkdownView(
                    markdown: trimmedContent,
                    style: .system
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

private struct ConversationTurnDiffRow: View {
    let data: ConversationTurnDiffData
    @State private var presented: PresentedDiff?

    var body: some View {
        Button {
            presented = PresentedDiff(
                id: "turn-diff",
                title: "Turn Diff",
                diff: data.diff,
                stats: DiffStats(additions: data.additions, deletions: data.deletions),
                sections: presentedDiffSections(from: data.diff)
            )
        } label: {
            DiffIndicatorLabel(additions: data.additions, deletions: data.deletions)
        }
        .buttonStyle(.plain)
        .sheet(item: $presented) { sheet in
            ConversationDiffDetailSheet(
                title: sheet.title,
                diff: sheet.diff ?? "",
                sections: sheet.sections
            )
        }
    }
}

private struct ConversationCommandExecutionRow: View {
    let data: ConversationCommandExecutionData
    let isPreferredExpanded: Bool

    @State private var isDetailPresented = false
    @State private var isCommandExpanded = false
    @State private var isOutputExpanded = false

    var body: some View {
        Button {
            isDetailPresented = true
        } label: {
            shellHeader
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .sheet(isPresented: $isDetailPresented) {
            detailSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var shellHeader: some View {
        HStack(spacing: 8) {
            Text(friendlyLabel)
                .macrodexFont(size: MacrodexFont.conversationBodyPointSize)
                .foregroundColor(MacrodexTheme.textSystem)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows command details")
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(friendlyLabel)
                        .macrodexFont(.headline, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    metadataRows
                    commandBlock
                    outputBlock
                }
                .padding(16)
            }
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isDetailPresented = false
                    }
                }
            }
        }
    }

    private var metadataRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataRow(label: "Status", value: data.status.toolCallStatus.label)
            if let exitCode = data.exitCode {
                metadataRow(label: "Exit Code", value: "\(exitCode)")
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label + ":")
                .macrodexFont(.caption, weight: .semibold)
                .foregroundColor(MacrodexTheme.textSecondary)
            Text(value)
                .macrodexFont(.caption)
                .foregroundColor(MacrodexTheme.textSystem)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commandBlock: some View {
        collapsedDetailBlock(title: "Command", isExpanded: $isCommandExpanded) {
            Text(verbatim: displayedCommand)
                .macrodexMonoFont(size: 12)
                .foregroundColor(MacrodexTheme.textSystem)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outputBlock: some View {
        collapsedDetailBlock(title: "Output", isExpanded: $isOutputExpanded) {
            Text(verbatim: renderedOutput)
                .macrodexMonoFont(size: 12)
                .foregroundColor(MacrodexTheme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func collapsedDetailBlock<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    sectionLabel(title)
                    Spacer(minLength: 0)
                    Text(isExpanded.wrappedValue ? "Hide" : "Show")
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
                    .padding(.vertical, 6)
            }
        }
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .macrodexFont(.caption2, weight: .bold)
            .foregroundColor(MacrodexTheme.textSecondary)
    }

    private var friendlyLabel: String {
        toolCallFriendlyCommandLabel(for: displayedCommand)
    }

    private var renderedOutput: String {
        let trimmed = data.output?.trimmingCharacters(in: .newlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return data.isInProgress ? "Waiting for output…" : "No output"
    }

    private var displayedCommand: String {
        let trimmed = data.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "command" : trimmed
    }
}

private struct ConversationCommandOutputViewport: View {
    let output: String
    @Environment(\.textScale) private var textScale

    private let bottomAnchorId = "command-output-bottom"

    private var lineFontSize: CGFloat {
        11 * textScale
    }

    private var viewportHeight: CGFloat {
        (MacrodexFont.uiMonoFont(size: lineFontSize).lineHeight * 3) + 16
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: output)
                        .macrodexMonoFont(size: 12)
                        .foregroundColor(MacrodexTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorId)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .frame(height: viewportHeight)
            .background(MacrodexTheme.codeBackground.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [MacrodexTheme.codeBackground.opacity(0.96), MacrodexTheme.codeBackground.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MacrodexTheme.border.opacity(0.35), lineWidth: 1)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: output) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        }
    }
}

private struct ConversationUserInputResponseRow: View {
    let data: ConversationUserInputResponseData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(data.questions.enumerated()), id: \.element.id) { _, question in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .macrodexFont(size: 10, weight: .semibold)
                        .foregroundColor(MacrodexTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question.header ?? question.question)
                            .macrodexFont(.caption, weight: .semibold)
                            .foregroundColor(MacrodexTheme.textSecondary)
                        Text(question.answer)
                            .macrodexFont(.caption)
                            .foregroundColor(MacrodexTheme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct ConversationDividerRow: View {
    let kind: ConversationDividerKind
    let isLiveTurn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(MacrodexTheme.border)
                .frame(minWidth: 16, maxHeight: 1)
            dividerContent
                .layoutPriority(1)
            Capsule()
                .fill(MacrodexTheme.border)
                .frame(minWidth: 16, maxHeight: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var dividerContent: some View {
        switch kind {
        case .contextCompaction:
            HStack(spacing: 6) {
                if effectiveContextCompactionComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .macrodexFont(size: 10, weight: .semibold)
                        .foregroundColor(MacrodexTheme.success)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(MacrodexTheme.warning)
                }

                Text(title)
                    .macrodexFont(.caption2, weight: .semibold)
                    .foregroundColor(
                        effectiveContextCompactionComplete ? MacrodexTheme.textMuted : MacrodexTheme.warning
                    )
                    .lineLimit(1)
            }
        default:
            Text(title)
                .macrodexFont(.caption2, weight: .semibold)
                .foregroundColor(MacrodexTheme.textMuted)
                .lineLimit(1)
        }
    }

    private var title: String {
        switch kind {
        case .contextCompaction:
            return effectiveContextCompactionComplete ? "Context compacted" : "Compacting context"
        case .modelRerouted(let fromModel, let toModel, let reason):
            let base = fromModel.map { "\($0) -> \(toModel)" } ?? "Routed to \(toModel)"
            if let reason, !reason.isEmpty {
                return "\(base) · \(reason)"
            }
            return base
        case .reviewEntered(let review):
            return review.isEmpty ? "Entered review" : "Entered review: \(review)"
        case .reviewExited(let review):
            return review.isEmpty ? "Exited review" : "Exited review: \(review)"
        case .workedFor:
            return "Worked"
        case .generic(let title, let detail):
            if let detail, !detail.isEmpty {
                return "\(title): \(detail)"
            }
            return title
        }
    }

    private var effectiveContextCompactionComplete: Bool {
        guard case .contextCompaction(let isComplete) = kind else { return true }
        return isComplete && !isLiveTurn
    }
}

private struct ConversationCodeReviewRow: View {
    let data: ConversationCodeReviewData
    @State private var dismissedFindingIndices: Set<Int> = []

    private var visibleFindings: [(index: Int, finding: ConversationCodeReviewFinding)] {
        data.findings.enumerated().compactMap { index, finding in
            dismissedFindingIndices.contains(index) ? nil : (index, finding)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(visibleFindings, id: \.index) { entry in
                ConversationCodeReviewFindingCard(
                    finding: entry.finding,
                    onDismiss: { dismissedFindingIndices.insert(entry.index) }
                )
            }
        }
    }
}

private struct ConversationCodeReviewFindingCard: View {
    let finding: ConversationCodeReviewFinding
    let onDismiss: () -> Void

    private var priorityLabel: String? {
        finding.priority.map { "P\($0)" }
    }

    private var priorityTint: Color {
        switch finding.priority {
        case 0?, 1?:
            return MacrodexTheme.danger
        case 2?:
            return MacrodexTheme.warning
        case 3?:
            return MacrodexTheme.textSecondary
        default:
            return MacrodexTheme.textSecondary
        }
    }

    private var locationText: String? {
        guard let location = finding.codeLocation else { return nil }
        guard let lineRange = location.lineRange else { return location.absoluteFilePath }
        if lineRange.start == lineRange.end {
            return "\(location.absoluteFilePath):\(lineRange.start)"
        }
        return "\(location.absoluteFilePath):\(lineRange.start)-\(lineRange.end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                if let priorityLabel {
                    Text(priorityLabel)
                        .macrodexFont(.caption2, weight: .bold)
                        .foregroundColor(priorityTint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(priorityTint.opacity(0.12), in: Capsule())
                }

                Text(finding.title)
                    .macrodexFont(.headline, weight: .semibold)
                    .foregroundColor(MacrodexTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.plain)
                    .macrodexFont(.callout, weight: .medium)
                    .foregroundColor(MacrodexTheme.textSecondary)
            }

            MacrodexMarkdownView(markdown: finding.body, style: .content, selectionEnabled: true)

            if let locationText, !locationText.isEmpty {
                Text(locationText)
                    .macrodexFont(.footnote)
                    .foregroundColor(MacrodexTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(MacrodexTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(MacrodexTheme.border.opacity(0.7), lineWidth: 1)
        )
    }
}

private struct ConversationSystemCardRow: View {
    let title: String
    let content: String
    let accent: Color
    let iconName: String

    var bodyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .macrodexFont(size: 11, weight: .semibold)
                    .foregroundColor(accent)
                Text(title.uppercased())
                    .macrodexFont(.caption2, weight: .bold)
                    .foregroundColor(accent)
            }
            if !content.isEmpty {
                MacrodexMarkdownView(
                    markdown: content,
                    style: .system
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View { bodyView }
}

struct ConversationPinnedContextStrip: View {
    let items: [ConversationItem]
    @State private var todoExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = pinnedPlan {
                compactTodoAccordion(for: plan)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var pinnedPlan: ConversationItem? {
        items.last(where: {
            if case .todoList(let data) = $0.content {
                return !data.steps.isEmpty
            }
            return false
        })
    }

    @ViewBuilder
    private func compactTodoAccordion(for item: ConversationItem) -> some View {
        if case .todoList(let data) = item.content {
            let completed = data.completedCount
            let total = data.steps.count
            let summary: String = {
                if completed == 0 {
                    return "To do list created with \(total) tasks"
                }
                return "\(completed) out of \(total) tasks completed"
            }()

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        todoExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: completed == total && total > 0 ? "checkmark.circle.fill" : "checklist")
                            .macrodexFont(size: 11, weight: .semibold)
                            .foregroundColor(completed == total && total > 0 ? MacrodexTheme.success : MacrodexTheme.accent)
                        Text(summary)
                            .macrodexFont(.caption, weight: .semibold)
                            .foregroundColor(MacrodexTheme.textPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .macrodexFont(size: 11, weight: .medium)
                            .foregroundColor(MacrodexTheme.textMuted)
                            .rotationEffect(.degrees(todoExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if todoExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(data.steps.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .top, spacing: 8) {
                                compactTodoStatusView(for: step.status)
                                    .padding(.top, 2)
                                MacrodexMarkdownView(
                                    markdown: step.step,
                                    style: .content,
                                    bodySize: 12,
                                    codeSize: 11
                                )
                                    .strikethrough(step.status == .completed, color: MacrodexTheme.textMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.sectionReveal)
                }
            }
        }
    }

    @ViewBuilder
    private func compactTodoStatusView(for status: HydratedPlanStepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .macrodexFont(size: 10, weight: .semibold)
                .foregroundColor(MacrodexTheme.textMuted)
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
                .tint(MacrodexTheme.warning)
                .frame(width: 10, height: 10)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .macrodexFont(size: 10, weight: .semibold)
                .foregroundColor(MacrodexTheme.success)
        }
    }

}


private struct PresentedDiff: Identifiable {
    let id: String
    let title: String
    let diff: String?
    let stats: DiffStats
    let sections: [PresentedDiffSection]
}

private struct PresentedDiffSection: Identifiable {
    let id: String
    let title: String
    let diff: String

    init(title: String, diff: String) {
        self.title = title
        self.diff = diff
        self.id = "\(title)|\(diff.hashValue)"
    }
}

struct DiffStats: Equatable {
    let additions: Int
    let deletions: Int

    var hasChanges: Bool {
        additions > 0 || deletions > 0
    }

    init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }

    /// Cheap stats-only parse — no per-line allocation.
    init(diff: String) {
        var adds = 0
        var dels = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { adds += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { dels += 1 }
        }
        self.additions = adds
        self.deletions = dels
    }
}

private struct DiffIndicatorLabel: View {
    private let stats: DiffStats

    init(diff: String) {
        self.stats = DiffStats(diff: diff)
    }

    init(additions: Int, deletions: Int) {
        self.stats = DiffStats(additions: additions, deletions: deletions)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .macrodexFont(size: 11, weight: .semibold)
                .foregroundColor(MacrodexTheme.accent)

            if stats.hasChanges {
                HStack(spacing: 6) {
                    Text("+\(stats.additions)")
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.success)
                    Text("-\(stats.deletions)")
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.danger)
                }
            } else {
                Text("Diff")
                    .macrodexFont(.caption2, weight: .semibold)
                    .foregroundColor(MacrodexTheme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(MacrodexTheme.surface.opacity(0.72), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if stats.hasChanges {
            return "Show diff details. \(stats.additions) additions, \(stats.deletions) deletions."
        }
        return "Show diff details."
    }
}

private struct DiffLine: Identifiable {
    enum Kind {
        case addition, deletion, hunk, context

        var foregroundColor: Color {
            switch self {
            case .addition: MacrodexTheme.success
            case .deletion: MacrodexTheme.danger
            case .hunk: MacrodexTheme.accentStrong
            case .context: MacrodexTheme.textBody
            }
        }

        var backgroundColor: Color {
            switch self {
            case .addition: MacrodexTheme.success.opacity(0.12)
            case .deletion: MacrodexTheme.danger.opacity(0.12)
            case .hunk: MacrodexTheme.accentStrong.opacity(0.12)
            case .context: MacrodexTheme.codeBackground.opacity(0.72)
            }
        }
    }

    let id: Int
    let text: String
    let kind: Kind
}

private struct ConversationDiffDetailSheet: View {
    let title: String
    let stats: DiffStats
    let sections: [PresentedDiffSectionModel]
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @State private var collapsedSectionIDs: Set<String> = []
    private let fullDiffFontSize = MacrodexFont.conversationBodyPointSize
    private let maxStickyDiffSections = 8
    private let maxStickyDiffCharacters = 20_000

    init(title: String, diff: String, sections: [PresentedDiffSection]) {
        self.title = title
        let sectionModels = sections.isEmpty
            ? [PresentedDiffSectionModel(PresentedDiffSection(title: "", diff: diff))]
            : sections.map(PresentedDiffSectionModel.init)
        self.stats = DiffStats(
            additions: sectionModels.reduce(0) { $0 + $1.stats.additions },
            deletions: sectionModels.reduce(0) { $0 + $1.stats.deletions }
        )
        self.sections = sectionModels
        _collapsedSectionIDs = State(
            initialValue: Set(
                sectionModels
                    .filter { !$0.title.isEmpty }
                    .map(\.id)
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("+\(stats.additions)")
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.success)
                    Text("-\(stats.deletions)")
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.danger)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ScrollView(.vertical) {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 8,
                        pinnedViews: usesStickyHeaders ? [.sectionHeaders] : []
                    ) {
                        ForEach(sections) { section in
                            if section.title.isEmpty {
                                diffSectionBody(section)
                            } else {
                                Section {
                                    diffSectionBody(section)
                                } header: {
                                    diffSectionHeader(section)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .id(themeManager.themeVersion)
    }

    private var usesStickyHeaders: Bool {
        guard sections.count <= maxStickyDiffSections else { return false }
        return sections.reduce(0) { $0 + $1.diff.count } <= maxStickyDiffCharacters
    }

    @ViewBuilder
    private func diffSection(_ section: PresentedDiffSectionModel) -> some View {
        let isExpanded = !collapsedSectionIDs.contains(section.id)

        VStack(alignment: .leading, spacing: 6) {
            if isExpanded {
                ScrollView(.horizontal, showsIndicators: true) {
                    SyntaxHighlightedDiffText(
                        diff: section.diff,
                        titleHint: section.title.isEmpty ? nil : section.title,
                        fontSize: fullDiffFontSize
                    )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .background(MacrodexTheme.codeBackground.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func diffSectionHeader(_ section: PresentedDiffSectionModel) -> some View {
        let isExpanded = !collapsedSectionIDs.contains(section.id)

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                toggleSection(section.id)
            }
        } label: {
            HStack(spacing: 8) {
                Text(section.title)
                    .macrodexFont(.caption2, weight: .bold)
                    .foregroundColor(MacrodexTheme.textSecondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text("+\(section.stats.additions)")
                    .macrodexFont(.caption2, weight: .semibold)
                    .foregroundColor(MacrodexTheme.success)
                Text("-\(section.stats.deletions)")
                    .macrodexFont(.caption2, weight: .semibold)
                    .foregroundColor(MacrodexTheme.danger)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .macrodexFont(size: 10, weight: .medium)
                    .foregroundColor(MacrodexTheme.textMuted)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(MacrodexTheme.backgroundGradient)
        }
        .buttonStyle(.plain)
    }

    private func diffSectionBody(_ section: PresentedDiffSectionModel) -> some View {
        diffSection(section)
    }

    private func toggleSection(_ id: String) {
        if collapsedSectionIDs.contains(id) {
            collapsedSectionIDs.remove(id)
        } else {
            collapsedSectionIDs.insert(id)
        }
    }
}

private struct PresentedDiffSectionModel: Identifiable {
    let id: String
    let title: String
    let diff: String
    let stats: DiffStats

    init(_ section: PresentedDiffSection) {
        self.id = section.id
        self.title = section.title
        self.diff = section.diff
        self.stats = DiffStats(diff: section.diff)
    }
}

private func presentedDiffSections(from diff: String) -> [PresentedDiffSection] {
    let normalized = diff.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }

    let lines = normalized.components(separatedBy: .newlines)
    let splitIndices = lines.enumerated().compactMap { index, line -> Int? in
        line.hasPrefix("diff --git ") ? index : nil
    }

    if !splitIndices.isEmpty {
        return splitIndices.enumerated().compactMap { offset, start in
            let end = offset + 1 < splitIndices.count ? splitIndices[offset + 1] : lines.count
            let chunk = Array(lines[start..<end]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { return nil }
            return PresentedDiffSection(title: diffSectionTitle(from: chunk), diff: chunk)
        }
    }

    return [PresentedDiffSection(title: diffSectionTitle(from: normalized), diff: normalized)]
}

private func mergePresentedDiffSections(_ sections: [PresentedDiffSection]) -> [PresentedDiffSection] {
    var orderedTitles: [String] = []
    var mergedByTitle: [String: String] = [:]
    var passthrough: [PresentedDiffSection] = []

    for section in sections {
        let normalizedTitle = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            passthrough.append(section)
            continue
        }

        if let existing = mergedByTitle[normalizedTitle] {
            mergedByTitle[normalizedTitle] = existing + "\n\n" + section.diff
        } else {
            orderedTitles.append(normalizedTitle)
            mergedByTitle[normalizedTitle] = section.diff
        }
    }

    let merged = orderedTitles.compactMap { title -> PresentedDiffSection? in
        guard let diff = mergedByTitle[title] else { return nil }
        return PresentedDiffSection(title: title, diff: diff)
    }

    return merged + passthrough
}

private func diffSectionTitle(from diff: String) -> String {
    for line in diff.components(separatedBy: .newlines) {
        if line.hasPrefix("diff --git ") {
            let parts = line.split(separator: " ")
            if let candidate = parts.last {
                return stripDiffPathPrefix(String(candidate))
            }
        }
        if line.hasPrefix("+++ ") {
            let candidate = String(line.dropFirst(4))
            if candidate != "/dev/null" {
                return stripDiffPathPrefix(candidate)
            }
        }
        if line.hasPrefix("--- ") {
            let candidate = String(line.dropFirst(4))
            if candidate != "/dev/null" {
                return stripDiffPathPrefix(candidate)
            }
        }
    }
    return ""
}

private func stripDiffPathPrefix(_ path: String) -> String {
    if path.hasPrefix("a/") || path.hasPrefix("b/") {
        return String(path.dropFirst(2))
    }
    return path
}

private extension ToolCallStatus {
    var themeColor: Color {
        switch self {
        case .completed:
            return MacrodexTheme.success
        case .inProgress:
            return MacrodexTheme.warning
        case .failed:
            return MacrodexTheme.danger
        case .unknown:
            return MacrodexTheme.textSecondary
        }
    }
}

private extension ConversationItem {
    var liveDetailStatus: ToolCallStatus? {
        switch content {
        case .commandExecution(let data):
            return data.status.toolCallStatus
        case .fileChange(let data):
            return data.status.toolCallStatus
        case .mcpToolCall(let data):
            return data.status.toolCallStatus
        case .dynamicToolCall(let data):
            return data.status.toolCallStatus
        case .webSearch(let data):
            return data.isInProgress ? .inProgress : .completed
        case .imageView:
            return .completed
        case .imageGeneration(let data):
            return data.status.toolCallStatus
        default:
            return nil
        }
    }
}
