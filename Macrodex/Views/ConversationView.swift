import SwiftUI
import PhotosUI
import UIKit
import os
import HairballUI

private let conversationViewSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.dj.Macrodex",
    category: "ConversationView"
)

enum ConversationStreamingViewportPolicy {
    static func shouldMaintainBottomAnchor(
        isStreaming: Bool,
        isNearBottom: Bool,
        autoFollowStreaming: Bool,
        userIsDraggingScroll: Bool
    ) -> Bool {
        guard !userIsDraggingScroll else { return false }
        if isStreaming {
            return autoFollowStreaming
        }
        return isNearBottom
    }

    static func isStreaming(_ threadStatus: ConversationStatus) -> Bool {
        if case .thinking = threadStatus {
            return true
        }
        return false
    }
}

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    @Environment(DrawerController.self) private var drawerController
    let thread: AppThreadSnapshot
    let activeThreadKey: ThreadKey
    let transcript: ConversationTranscriptSnapshot
    let followScrollToken: Int
    let pinnedContextItems: [ConversationItem]
    let composer: ConversationComposerSnapshot
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var onOpenConversation: ((ThreadKey) -> Void)? = nil
    var onResumeSessions: ((String) -> Void)? = nil
    var autoFocusComposer: Bool = false
    var onAutoFocusComposerConsumed: (() -> Void)? = nil
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @AppStorage("fastMode") private var fastMode = false
    @State private var messageActionError: String?
    @State private var hasLoggedFirstRender = false
    @State private var localSendScrollToken = 0
    @State private var dismissComposerToken = 0

    private var items: [ConversationItem] {
        transcript.items
    }

    private var threadStatus: ConversationStatus {
        transcript.threadStatus
    }

    private var agentDirectoryVersion: UInt64 {
        transcript.agentDirectoryVersion
    }

    private var pendingModelOverride: String? {
        let trimmed = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var pendingReasoningOverride: String? {
        let trimmed = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        ConversationMessageList(
            items: items,
            threadStatus: threadStatus,
            threadHasServerData: thread.hasPreviewOrTitle,
            transcriptRenderDigest: transcript.renderDigest,
            followScrollToken: followScrollToken,
            sendScrollToken: localSendScrollToken,
            activeThreadKey: activeThreadKey,
            agentDirectoryVersion: agentDirectoryVersion,
            topInset: thread.isSubagent ? topInset + 32 : topInset,
            textSizeStep: .constant(ConversationTextSize.medium.rawValue),
            resolveTargetLabel: resolveTargetLabel,
            onEditUserItem: editMessage,
            onForkFromUserItem: forkFromMessage,
            onOpenConversation: onOpenConversation,
            onDismissComposer: {
                dismissComposerToken &+= 1
            }
        )
        .activeThreadKey(activeThreadKey)
        .scrollDisabled(drawerController.progress > 0.001)
        .background {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if thread.isSubagent {
                SubagentBreadcrumbBar(
                    thread: thread,
                    topInset: topInset,
                    onNavigateToParent: {
                        if let parentId = thread.info.parentThreadId {
                            onOpenConversation?(ThreadKey(serverId: thread.serverId, threadId: parentId))
                        }
                    }
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConversationBottomChrome(
                pinnedContextItems: pinnedContextItems,
                composer: composer,
                onSend: sendMessage,
                onFileSearch: searchComposerFiles,
                bottomInset: bottomInset,
                dismissComposerToken: dismissComposerToken,
                autoFocusComposer: autoFocusComposer && items.isEmpty && !thread.isSubagent,
                onAutoFocusComposerConsumed: onAutoFocusComposerConsumed,
                onOpenConversation: onOpenConversation,
                onResumeSessions: onResumeSessions
            )
        }
        .alert("Conversation Action Error", isPresented: Binding(
            get: { messageActionError != nil },
            set: { if !$0 { messageActionError = nil } }
        )) {
            Button("OK", role: .cancel) { messageActionError = nil }
        } message: {
            Text(messageActionError ?? "Unknown error")
        }
        .onAppear {
            guard !hasLoggedFirstRender else { return }
            hasLoggedFirstRender = true
            os_signpost(.event, log: conversationViewSignpostLog, name: "ConversationFirstRender")
            appState.hydratePermissions(from: thread)
        }
        .onChange(of: thread) { _, newThread in
            appState.hydratePermissions(from: newThread)
        }
    }

    private func sendMessage(_ text: String, attachmentImages: [UIImage], skillMentions: [SkillMentionSelection]) {
        localSendScrollToken &+= 1
        Task {
            do {
                NSLog(
                    "[ConversationView] sendMessage start server=%@ thread=%@ textLength=%ld",
                    activeThreadKey.serverId,
                    activeThreadKey.threadId,
                    text.count
                )
                let payload = try makeComposerPayload(
                    text: text,
                    attachmentImages: attachmentImages,
                    skillMentions: skillMentions
                )
                try await appModel.startTurn(key: activeThreadKey, payload: payload)
                NSLog(
                    "[ConversationView] sendMessage turnStart returned server=%@ thread=%@",
                    activeThreadKey.serverId,
                    activeThreadKey.threadId
                )
            } catch {
                NSLog(
                    "[ConversationView] sendMessage error server=%@ thread=%@ error=%@",
                    activeThreadKey.serverId,
                    activeThreadKey.threadId,
                    error.localizedDescription
                )
                messageActionError = error.localizedDescription
            }
        }
    }

    private func resolveTargetLabel(_ target: String) -> String? {
        appModel.snapshot?.resolvedAgentTargetLabel(for: target, serverId: activeThreadKey.serverId)
    }

    private func editMessage(_ item: ConversationItem) {
        Task {
            do {
                guard let selectedTurnIndex = item.sourceTurnIndex, item.isUserItem, item.isFromUserTurnBoundary else {
                    throw NSError(
                        domain: "Macrodex",
                        code: 1020,
                        userInfo: [NSLocalizedDescriptionKey: "Only user messages can be edited"]
                    )
                }
                let result = try await appModel.store.editMessage(
                    key: activeThreadKey,
                    selectedTurnIndex: UInt32(selectedTurnIndex)
                )
                appModel.queueComposerPrefill(threadKey: activeThreadKey, text: result)
            } catch {
                messageActionError = error.localizedDescription
            }
        }
    }

    private func forkFromMessage(_ item: ConversationItem) {
        Task {
            do {
                guard let selectedTurnIndex = item.sourceTurnIndex, item.isUserItem, item.isFromUserTurnBoundary else {
                    throw NSError(
                        domain: "Macrodex",
                        code: 1016,
                        userInfo: [NSLocalizedDescriptionKey: "Fork from here is only supported for user messages"]
                    )
                }
                let nextKey = try await appModel.store.forkThreadFromMessage(
                    key: activeThreadKey,
                    selectedTurnIndex: UInt32(selectedTurnIndex),
                    params: launchConfig().forkThreadFromMessageRequest(
                        cwdOverride: thread.info.cwd
                    )
                )
                await appModel.refreshSnapshot()
                let nextCwd = thread.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !nextCwd.isEmpty {
                    workDir = nextCwd
                    appState.currentCwd = nextCwd
                }
                onOpenConversation?(nextKey)
            } catch {
                messageActionError = error.localizedDescription
            }
        }
    }

    private func searchComposerFiles(_ query: String) async throws -> [FileSearchResult] {
        let searchRoot = workDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : workDir
        return try await appModel.client.searchFiles(
            serverId: activeThreadKey.serverId,
            params: AppSearchFilesRequest(
                query: query,
                roots: [searchRoot],
                cancellationToken: "ios-composer-file-search"
            )
        )
    }

    private func makeComposerPayload(
        text: String,
        attachmentImages: [UIImage],
        skillMentions: [SkillMentionSelection]
    ) throws -> AppComposerPayload {
        let preparedAttachments = attachmentImages.compactMap(ConversationAttachmentSupport.prepareImage)
        var additionalInputs = skillMentions.map { mention in
            AppUserInput.skill(name: mention.name, path: AbsolutePath(value: mention.path))
        }
        additionalInputs.append(contentsOf: preparedAttachments.map(\.userInput))
        let modelOverride = preparedAttachments.isEmpty
            ? pendingModelOverride
            : appModel.selectedModelID(
                for: activeThreadKey.serverId,
                selectedModel: pendingModelOverride,
                requiresImageInput: true
            )
        return AppComposerPayload(
            text: text,
            additionalInputs: additionalInputs,
            approvalPolicy: appState.launchApprovalPolicy(for: activeThreadKey),
            sandboxPolicy: appState.turnSandboxPolicy(for: activeThreadKey),
            model: modelOverride,
            effort: ReasoningEffort(wireValue: pendingReasoningOverride),
            serviceTier: ServiceTier(wireValue: fastMode ? "fast" : nil)
        )
    }

    private func launchConfig() -> AppThreadLaunchConfig {
        AppThreadLaunchConfig(
            model: pendingModelOverride,
            approvalPolicy: appState.launchApprovalPolicy(for: activeThreadKey),
            sandbox: appState.launchSandboxMode(for: activeThreadKey),
            developerInstructions: AgentRuntimeInstructions.developerInstructions(for: activeThreadKey),
            persistExtendedHistory: true
        )
    }
}

struct DraftConversationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(DrawerController.self) private var drawerController
    let draftID: UUID
    let serverId: String
    var bottomInset: CGFloat = 0
    let onSend: (String, [UIImage], [SkillMentionSelection]) async throws -> Void
    let onOpenConversation: ((ThreadKey) -> Void)?
    let onResumeSessions: ((String) -> Void)?
    @State private var sendError: String?
    @State private var isSending = false
    @AppStorage("workDir") private var workDir =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    private var draftThreadKey: ThreadKey {
        ThreadKey(serverId: serverId, threadId: "new_thread")
    }

    private var composer: ConversationComposerSnapshot {
        ConversationComposerSnapshot(
            threadKey: draftThreadKey,
            collaborationMode: .default,
            activePlanProgress: nil,
            pendingPlanImplementationPrompt: nil,
            pendingUserInputRequest: nil,
            activeTaskSummary: nil,
            queuedFollowUps: [],
            composerPrefillRequest: nil,
            activeTurnId: nil,
            isTurnActive: isSending,
            threadPreview: "",
            threadModel: appModel.preferredDefaultModelID(for: serverId) ?? "",
            threadReasoningEffort: nil,
            modelContextWindow: nil,
            contextTokensUsed: nil,
            rateLimits: nil,
            availableModels: appModel.availableModels(for: serverId),
            isConnected: true
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
        }
        .scrollDisabled(drawerController.progress > 0.001)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConversationBottomChrome(
                pinnedContextItems: [],
                composer: composer,
                onSend: sendDraftMessage,
                onFileSearch: searchComposerFiles,
                bottomInset: bottomInset,
                dismissComposerToken: 0,
                autoFocusComposer: true,
                onAutoFocusComposerConsumed: nil,
                onOpenConversation: onOpenConversation,
                onResumeSessions: onResumeSessions
            )
        }
        .alert("Conversation Action Error", isPresented: Binding(
            get: { sendError != nil },
            set: { if !$0 { sendError = nil } }
        )) {
            Button("OK", role: .cancel) { sendError = nil }
        } message: {
            Text(sendError ?? "Unknown error")
        }
        .task(id: serverId) {
            await appModel.loadConversationMetadataIfNeeded(serverId: serverId)
        }
    }

    private func sendDraftMessage(_ text: String, attachmentImages: [UIImage], skillMentions: [SkillMentionSelection]) {
        guard !isSending else { return }
        isSending = true
        Task {
            do {
                try await onSend(text, attachmentImages, skillMentions)
            } catch {
                sendError = error.localizedDescription
            }
            isSending = false
        }
    }

    private func searchComposerFiles(_ query: String) async throws -> [FileSearchResult] {
        let searchRoot = workDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = searchRoot.isEmpty ? "/" : searchRoot
        return try await appModel.client.searchFiles(
            serverId: serverId,
            params: AppSearchFilesRequest(
                query: query,
                roots: [root],
                cancellationToken: "ios-draft-composer-file-search"
            )
        )
    }
}

private enum ConversationComposerDraftStore {
    private static let storageKey = "conversationComposerDrafts.v1"

    static func text(for threadKey: ThreadKey) -> String {
        drafts()[key(for: threadKey)] ?? ""
    }

    static func save(_ text: String, for threadKey: ThreadKey) {
        var allDrafts = drafts()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            allDrafts.removeValue(forKey: key(for: threadKey))
        } else {
            allDrafts[key(for: threadKey)] = text
        }
        persist(allDrafts)
    }

    static func clear(for threadKey: ThreadKey) {
        var allDrafts = drafts()
        allDrafts.removeValue(forKey: key(for: threadKey))
        persist(allDrafts)
    }

    private static func key(for threadKey: ThreadKey) -> String {
        "\(threadKey.serverId)::\(threadKey.threadId)"
    }

    private static func drafts() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return value
    }

    private static func persist(_ drafts: [String: String]) {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

private extension AppThreadSnapshot {
    var serverId: String { key.serverId }
    var isSubagent: Bool {
        info.parentThreadId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && ((info.agentNickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                || (info.agentRole?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false))
    }

    var agentDisplayLabel: String? {
        let nickname = info.agentNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = info.agentRole?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nickname, !nickname.isEmpty { return nickname }
        if let role, !role.isEmpty { return role }
        return nil
    }
}

private struct ConversationBottomChrome: View {
    let pinnedContextItems: [ConversationItem]
    let composer: ConversationComposerSnapshot
    let onSend: (String, [UIImage], [SkillMentionSelection]) -> Void
    let onFileSearch: (String) async throws -> [FileSearchResult]
    var bottomInset: CGFloat = 0
    let dismissComposerToken: Int
    let autoFocusComposer: Bool
    let onAutoFocusComposerConsumed: (() -> Void)?
    let onOpenConversation: ((ThreadKey) -> Void)?
    let onResumeSessions: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ConversationPinnedContextStrip(
                items: pinnedContextItems
            )
            ConversationInputBar(
                snapshot: composer,
                onSend: onSend,
                onFileSearch: onFileSearch,
                bottomInset: bottomInset,
                dismissComposerToken: dismissComposerToken,
                autoFocusComposer: autoFocusComposer,
                onAutoFocusComposerConsumed: onAutoFocusComposerConsumed,
                showModeChip: false,
                onOpenModePicker: {},
                onOpenConversation: onOpenConversation,
                onResumeSessions: onResumeSessions
            )
            .background(.clear, ignoresSafeAreaEdges: .bottom)
        }
        .padding(.bottom, 32)
    }
}

struct RateLimitBadgeView: View, Equatable {
    let label: String
    let percent: Int

    private var tint: Color {
        if percent <= 10 { return MacrodexTheme.danger }
        if percent <= 30 { return MacrodexTheme.warning }
        return MacrodexTheme.textMuted
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(MacrodexFont.monospaced(size: 9.5, weight: .semibold))
                .foregroundColor(MacrodexTheme.textSecondary)
            ContextBadgeView(percent: percent, tint: tint)
        }
    }
}


private struct ConversationMessageList: View {
    @Environment(DrawerController.self) private var drawerController
    let items: [ConversationItem]
    let threadStatus: ConversationStatus
    let threadHasServerData: Bool
    let transcriptRenderDigest: Int
    let followScrollToken: Int
    let sendScrollToken: Int
    let activeThreadKey: ThreadKey
    let agentDirectoryVersion: UInt64
    var topInset: CGFloat = 0
    @Binding var textSizeStep: Int
    let resolveTargetLabel: (String) -> String?
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil
    let onDismissComposer: () -> Void
    @State private var isNearBottom = true
    @State private var autoFollowStreaming = true
    @State private var userIsDraggingScroll = false
    @State private var waitingForDataExpired = false
    @State private var pinchBaseStep: Int?
    @State private var pinchAppliedDelta = 0
    @State private var transcriptTurns: [TranscriptTurn] = []
    @State private var transcriptBuildKey: Int?
    @State private var renderedTurns: [TranscriptTurn] = []
    @State private var renderedTurnsBuildKey: Int?
    @State private var expandedTurnIDs: Set<String> = []
    @State private var pendingAnimatedTurns: [TranscriptTurn]?
    @State private var turnInsertionAnimationInFlight = false
    @AppStorage("collapseTurns") private var collapseTurns = false
    private var expandedRecentTurnCount: Int {
        return collapseTurns ? 1 : .max
    }

    private var sourceTurns: [TranscriptTurn] {
        if transcriptTurns.isEmpty {
            return TranscriptTurn.build(
                from: items,
                threadStatus: threadStatus,
                expandedRecentTurnCount: expandedRecentTurnCount
            )
        }
        return transcriptTurns
    }

    private var lastTurnIsUserOnly: Bool {
        guard let lastTurn = sourceTurns.last else { return false }
        return lastTurn.items.allSatisfy { $0.isUserItem }
    }

    private var isStreamingLastTurn: Bool {
        if case .thinking = threadStatus { return true }
        return sourceTurns.last?.isLive == true
    }

    private var messageActionsDisabled: Bool {
        if case .thinking = threadStatus { return true }
        return false
    }

    private var isWaitingForData: Bool {
        items.isEmpty && threadHasServerData && !waitingForDataExpired
    }

    private var shouldShowScrollToBottom: Bool {
        !items.isEmpty && !isNearBottom
    }

    private var isStreaming: Bool {
        if case .thinking = threadStatus { return true }
        return false
    }

    private static let nearBottomEnterDistance: CGFloat = 220
    private static let nearBottomExitDistance: CGFloat = 420
    private static let initialTurnWindow = 10
    private static let turnPageSize = 20
    @State private var turnWindowSize: Int = ConversationMessageList.initialTurnWindow

    private var displayedTurns: [TranscriptTurn] {
        let all = sourceTurns
        if all.count <= turnWindowSize { return all }
        return Array(all.suffix(turnWindowSize))
    }

    private var hasMoreTurnsAbove: Bool {
        sourceTurns.count > turnWindowSize
    }

    private func loadMoreTurns() {
        turnWindowSize = min(turnWindowSize + Self.turnPageSize, sourceTurns.count)
    }

    private func resetTurnWindow() {
        turnWindowSize = Self.initialTurnWindow
    }

    private var mergedRenderableTurns: [TranscriptTurn] {
        let turns = displayedTurns
        let buildKey = makeRenderedTurnsBuildKey(for: turns)
        if renderedTurnsBuildKey == buildKey { return renderedTurns }
        return TranscriptTurn.mergeConsecutiveExplorationTurnsForRendering(turns)
    }

    var body: some View {
        let turns = mergedRenderableTurns
        let lastTurnID = turns.last?.id
        ScrollViewReader { proxy in
            GeometryReader { viewport in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if hasMoreTurnsAbove {
                                Button {
                                    loadMoreTurns()
                                } label: {
                                    Text("Load earlier messages")
                                        .macrodexFont(.caption, weight: .semibold)
                                        .foregroundColor(MacrodexTheme.accent)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(turns) { turn in
                                let isLastTurn = turn.id == lastTurnID
                                ConversationTurnRow(
                                    turn: turn,
                                    isExpanded: isTurnExpanded(turn),
                                    canCollapse: turn.isCollapsedByDefault,
                                    isLastTurn: isLastTurn,
                                    viewportHeight: viewport.size.height,
                                    showTypingIndicator: isLastTurn && {
                                        if case .thinking = threadStatus { return true }
                                        return false
                                    }(),
                                    serverId: activeThreadKey.serverId,
                                    agentDirectoryVersion: agentDirectoryVersion,
                                    messageActionsDisabled: messageActionsDisabled,
                                    onToggleExpansion: {
                                        toggleTurnExpansion(turn)
                                    },
                                    onStreamingSnapshotRendered: nil,
                                    resolveTargetLabel: resolveTargetLabel,
                                    onEditUserItem: onEditUserItem,
                                    onForkFromUserItem: onForkFromUserItem,
                                    onOpenConversation: onOpenConversation
                                )
                                .equatable()
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, topInset + 56)
                        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: textSizeStep)

                        if isWaitingForData {
                            ConversationLoadingIndicator(label: "Loading conversation...")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                }
                .scrollDisabled(drawerController.progress > 0.001)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        onDismissComposer()
                    }
                )
                .defaultScrollAnchor(.bottom)
                .simultaneousGesture(
                    MagnificationGesture(minimumScaleDelta: 0.03)
                        .onChanged { scale in handlePinchChanged(scale: scale) }
                        .onEnded { scale in finishPinch(scale: scale) }
                )
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                } action: { _, distance in
                    // During streaming auto-follow, don't let intermediate layout values flip isNearBottom.
                    if isStreaming && autoFollowStreaming && !userIsDraggingScroll { return }
                    let next: Bool
                    if isNearBottom {
                        next = distance <= Self.nearBottomExitDistance
                    } else {
                        next = distance <= Self.nearBottomEnterDistance
                    }
                    if next != isNearBottom { isNearBottom = next }
                    if next {
                        autoFollowStreaming = true
                    } else if isStreaming && userIsDraggingScroll {
                        autoFollowStreaming = false
                    }
                }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting:
                        userIsDraggingScroll = true
                        if isStreaming { autoFollowStreaming = false }
                    case .decelerating:
                        userIsDraggingScroll = true
                    default:
                        userIsDraggingScroll = false
                        if isNearBottom { autoFollowStreaming = true }
                    }
                }
                .onAppear {
                    autoFollowStreaming = true
                    syncTranscriptTurns()
                }
                .onChange(of: activeThreadKey) {
                    autoFollowStreaming = true
                    isNearBottom = true
                    waitingForDataExpired = false
                    resetTurnWindow()
                    syncTranscriptTurns(resetExpansion: true)
                    StreamingRendererCoordinator.shared.reset()
                }
                .task(id: activeThreadKey) {
                    try? await Task.sleep(for: .seconds(1))
                    waitingForDataExpired = true
                }
                .onChange(of: items) { _, _ in
                    syncTranscriptTurns()
                }
                .onChange(of: collapseTurns) {
                    syncTranscriptTurns(resetExpansion: true)
                }
                .onChange(of: followScrollToken) {
                    guard isStreaming, autoFollowStreaming, !userIsDraggingScroll else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: sendScrollToken) {
                    autoFollowStreaming = true
                    isNearBottom = true
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                    guard isNearBottom || autoFollowStreaming else { return }
                    autoFollowStreaming = true
                    isNearBottom = true
                    let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + min(max(duration, 0.12), 0.35)) {
                        guard isNearBottom || autoFollowStreaming else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: threadStatus) { oldStatus, _ in
                    syncTranscriptTurns()
                    // When streaming ends, finish active renderers so they
                    // switch to static rendering (no re-animation on view rebuild).
                    let wasStreaming = { if case .thinking = oldStatus { return true }; return false }()
                    if wasStreaming && !isStreaming {
                        StreamingRendererCoordinator.shared.finishActive()
                    }
                    if wasStreaming && !isStreaming && autoFollowStreaming {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }

                if shouldShowScrollToBottom {
                    ScrollToBottomIndicator {
                        autoFollowStreaming = true
                        isNearBottom = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            }
        }
    }

    private func isTurnExpanded(_ turn: TranscriptTurn) -> Bool {
        !turn.isCollapsedByDefault || expandedTurnIDs.contains(turn.id)
    }

    private func toggleTurnExpansion(_ turn: TranscriptTurn) {
        guard turn.isCollapsedByDefault else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            if expandedTurnIDs.contains(turn.id) {
                expandedTurnIDs.remove(turn.id)
            } else {
                expandedTurnIDs.insert(turn.id)
            }
        }
    }

    private func syncTranscriptTurns(resetExpansion: Bool = false) {
        let nextBuildKey = makeTranscriptBuildKey()
        if transcriptBuildKey == nextBuildKey, !transcriptTurns.isEmpty {
            if resetExpansion { expandedTurnIDs.removeAll() }
            return
        }

        let nextTurns = TranscriptTurn.build(
            from: items,
            threadStatus: threadStatus,
            expandedRecentTurnCount: expandedRecentTurnCount
        )
        transcriptBuildKey = nextBuildKey
        if shouldAnimateNewTurnInsertion(from: transcriptTurns, to: nextTurns, resetExpansion: resetExpansion) {
            pendingAnimatedTurns = nextTurns
            guard !turnInsertionAnimationInFlight else { return }
            startNewTurnInsertionAnimation(from: transcriptTurns)
            return
        }

        if turnInsertionAnimationInFlight {
            pendingAnimatedTurns = nextTurns
            return
        }

        let lastTurnItemCountGrew = {
            guard let currentLast = transcriptTurns.last,
                  let nextLast = nextTurns.last,
                  currentLast.id == nextLast.id,
                  nextLast.items.count > currentLast.items.count else {
                return false
            }
            return true
        }()

        if lastTurnItemCountGrew {
            withAnimation(.spring(duration: 0.4, bounce: 0.08)) {
                applyTranscriptTurns(nextTurns, resetExpansion: resetExpansion)
            }
        } else {
            applyTranscriptTurns(nextTurns, resetExpansion: resetExpansion)
        }
    }

    private func makeTranscriptBuildKey() -> Int {
        var hasher = Hasher()
        hasher.combine(expandedRecentTurnCount)
        hasher.combine(transcriptRenderDigest)
        return hasher.finalize()
    }

    private func makeRenderedTurnsBuildKey(for turns: [TranscriptTurn]) -> Int {
        var hasher = Hasher()
        hasher.combine(turns.count)
        for turn in turns {
            hasher.combine(turn.id)
            hasher.combine(turn.renderDigest)
            hasher.combine(turn.isLive)
            hasher.combine(turn.isCollapsedByDefault)
        }
        return hasher.finalize()
    }

    private func layoutSignature(for turn: TranscriptTurn) -> Int {
        var hasher = Hasher()
        hasher.combine(turn.id)
        hasher.combine(turn.renderDigest)
        hasher.combine(turn.isLive)
        hasher.combine(turn.isCollapsedByDefault)
        return hasher.finalize()
    }

    private func handlePinchChanged(scale: CGFloat) {
        if pinchBaseStep == nil {
            pinchBaseStep = textSizeStep
            pinchAppliedDelta = 0
        }

        let candidateDelta: Int
        if scale >= 1.18 { candidateDelta = 2 }
        else if scale >= 1.03 { candidateDelta = 1 }
        else if scale <= 0.86 { candidateDelta = -2 }
        else if scale <= 0.97 { candidateDelta = -1 }
        else { candidateDelta = 0 }
        guard candidateDelta != 0 else { return }

        if pinchAppliedDelta == 0 {
            pinchAppliedDelta = candidateDelta
            return
        }

        let sameDirection = (pinchAppliedDelta > 0 && candidateDelta > 0) || (pinchAppliedDelta < 0 && candidateDelta < 0)
        if sameDirection {
            if abs(candidateDelta) > abs(pinchAppliedDelta) {
                pinchAppliedDelta = candidateDelta
            }
        } else {
            pinchAppliedDelta = candidateDelta
        }
    }

    private func finishPinch(scale: CGFloat) {
        handlePinchChanged(scale: scale)
        let baseline = pinchBaseStep ?? textSizeStep
        let next = ConversationTextSize.clamped(rawValue: baseline + pinchAppliedDelta).rawValue
        if next != textSizeStep {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                textSizeStep = next
            }
        }
        pinchBaseStep = nil
        pinchAppliedDelta = 0
    }

    private func shouldAnimateNewTurnInsertion(
        from currentTurns: [TranscriptTurn],
        to nextTurns: [TranscriptTurn],
        resetExpansion: Bool
    ) -> Bool {
        guard collapseTurns,
              !resetExpansion,
              !currentTurns.isEmpty,
              nextTurns.count == currentTurns.count + 1,
              currentTurns.last?.id != nextTurns.last?.id,
              let lastTurn = nextTurns.last,
              lastTurn.items.first?.isUserItem == true,
              lastTurn.items.first?.isFromUserTurnBoundary == true else {
            return false
        }

        for (currentTurn, nextTurn) in zip(currentTurns, nextTurns) {
            guard currentTurn.id == nextTurn.id else { return false }
        }

        return true
    }

    private func startNewTurnInsertionAnimation(from currentTurns: [TranscriptTurn]) {
        guard let previousLastTurnID = currentTurns.last?.id else {
            if let pendingAnimatedTurns {
                applyTranscriptTurns(pendingAnimatedTurns)
                self.pendingAnimatedTurns = nil
            }
            return
        }

        turnInsertionAnimationInFlight = true
        let collapsedTurns = currentTurns.map { turn in
            turn.id == previousLastTurnID ? turn.withCollapsedByDefault(true) : turn
        }

        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            applyTranscriptTurns(
                collapsedTurns,
                removeExpandedTurnID: previousLastTurnID
            )
        } completion: {
            let turnsToInsert = pendingAnimatedTurns ?? collapsedTurns
            withAnimation(.smooth(duration: 0.2)) {
                applyTranscriptTurns(turnsToInsert)
            } completion: {
                turnInsertionAnimationInFlight = false
                let latestTurns = pendingAnimatedTurns ?? turnsToInsert
                pendingAnimatedTurns = nil
                if latestTurns.map(layoutSignature(for:)) != transcriptTurns.map(layoutSignature(for:)) {
                    applyTranscriptTurns(latestTurns)
                }
            }
        }
    }

    private func applyTranscriptTurns(
        _ nextTurns: [TranscriptTurn],
        resetExpansion: Bool = false,
        removeExpandedTurnID: String? = nil
    ) {
        let nextTurnIDs = Set(nextTurns.map(\.id))
        let nextRenderedTurns = TranscriptTurn.mergeConsecutiveExplorationTurnsForRendering(nextTurns)
        transcriptTurns = nextTurns
        renderedTurns = nextRenderedTurns
        renderedTurnsBuildKey = makeRenderedTurnsBuildKey(for: nextTurns)
        if resetExpansion {
            expandedTurnIDs.removeAll()
        } else {
            expandedTurnIDs.formIntersection(nextTurnIDs)
        }
        if let removeExpandedTurnID {
            expandedTurnIDs.remove(removeExpandedTurnID)
        }
    }

}

private struct ConversationTurnRow: View, Equatable {
    let turn: TranscriptTurn
    let isExpanded: Bool
    let canCollapse: Bool
    let isLastTurn: Bool
    let viewportHeight: CGFloat
    let showTypingIndicator: Bool
    let serverId: String
    let agentDirectoryVersion: UInt64
    @Environment(\.textScale) private var textScale
    let messageActionsDisabled: Bool
    let onToggleExpansion: () -> Void
    let onStreamingSnapshotRendered: (() -> Void)?
    let resolveTargetLabel: (String) -> String?
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil

    static func == (lhs: ConversationTurnRow, rhs: ConversationTurnRow) -> Bool {
        lhs.turn.id == rhs.turn.id &&
            lhs.turn.renderDigest == rhs.turn.renderDigest &&
            lhs.turn.isLive == rhs.turn.isLive &&
            lhs.isExpanded == rhs.isExpanded &&
            lhs.canCollapse == rhs.canCollapse &&
            lhs.isLastTurn == rhs.isLastTurn &&
            lhs.viewportHeight == rhs.viewportHeight &&
            lhs.showTypingIndicator == rhs.showTypingIndicator &&
            lhs.serverId == rhs.serverId &&
            lhs.agentDirectoryVersion == rhs.agentDirectoryVersion &&
            lhs.messageActionsDisabled == rhs.messageActionsDisabled
    }

    var body: some View {
        if isExpanded {
            expandedContent
        } else {
            collapsedCard
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConversationTurnTimeline(
                items: turn.items,
                isLive: turn.isLive,
                serverId: serverId,
                agentDirectoryVersion: agentDirectoryVersion,
                messageActionsDisabled: messageActionsDisabled,
                onStreamingSnapshotRendered: onStreamingSnapshotRendered,
                resolveTargetLabel: resolveTargetLabel,
                onEditUserItem: onEditUserItem,
                onForkFromUserItem: onForkFromUserItem,
                onOpenConversation: onOpenConversation
            )

            TypingIndicator()
                .opacity(showTypingIndicator ? 1 : 0)
                .animation(nil)

            if canCollapse {
                Button("Show Less", systemImage: "chevron.up", action: onToggleExpansion)
                    .macrodexFont(.caption, weight: .semibold)
                    .foregroundColor(MacrodexTheme.textSecondary)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
            }
        }
    }

    private var collapsedCard: some View {
        Button(action: onToggleExpansion) {
            previewTextBlock
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, collapsedFooterReservedInset)
                .modifier(GlassRectModifier(cornerRadius: 16, tint: MacrodexTheme.surface.opacity(0.34)))
                .overlay(alignment: .bottomLeading) {
                    footerRow
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var previewTextBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: turn.preview.primaryText)
                .macrodexFont(.body, weight: .semibold)
                .foregroundColor(MacrodexTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: responsePreviewText)
                .macrodexFont(.body)
                .foregroundColor(MacrodexTheme.textSecondary.opacity(0.82))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(
                    maxWidth: .infinity,
                    minHeight: collapsedResponseHeight,
                    maxHeight: collapsedResponseHeight,
                    alignment: .topLeading
                )
                .mask(responsePreviewMask)
        }
        .frame(maxWidth: .infinity, minHeight: collapsedPreviewHeight, maxHeight: collapsedPreviewHeight, alignment: .topLeading)
    }

    private var footerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if !footerMetadataItems.isEmpty {
                HStack(spacing: 10) {
                    ForEach(footerMetadataItems, id: \.id) { item in
                        CollapsedTurnMetaItem(systemImage: item.systemImage, text: item.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .macrodexFont(size: 11, weight: .semibold)
                .foregroundColor(MacrodexTheme.textMuted)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var collapsedPreviewHeight: CGFloat { collapsedPrimaryLineHeight + collapsedResponseHeight + 4 }
    private var collapsedFooterReservedInset: CGFloat { collapsedFooterHeight + 10 }
    private var collapsedFooterHeight: CGFloat { max(UIFont.preferredFont(forTextStyle: .caption1).lineHeight * textScale, 14) }

    private var responsePreviewMask: some View {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.55),
                .init(color: .white.opacity(0.58), location: 0.82),
                .init(color: .white.opacity(0.24), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var collapsedPrimaryLineHeight: CGFloat { collapsedPreviewLineHeight }
    private var collapsedResponseHeight: CGFloat { (collapsedPreviewLineHeight * 2) + 2 }
    private var collapsedPreviewLineHeight: CGFloat { UIFont.preferredFont(forTextStyle: .body).lineHeight * textScale }

    private var footerMetadataItems: [CollapsedTurnMeta] {
        var items: [CollapsedTurnMeta] = []
        if turn.preview.toolCallCount > 0 {
            items.append(CollapsedTurnMeta(id: "tools", systemImage: nil, text: "Tools \(turn.preview.toolCallCount)"))
        }
        if turn.preview.eventCount > 0 {
            items.append(CollapsedTurnMeta(id: "events", systemImage: "sparkles", text: "\(turn.preview.eventCount)"))
        }
        if turn.preview.imageCount > 0 {
            items.append(CollapsedTurnMeta(id: "images", systemImage: "photo", text: "\(turn.preview.imageCount)"))
        }
        return items
    }

    private var secondaryPreviewText: String? {
        guard let secondaryText = turn.preview.secondaryText, secondaryText != turn.preview.primaryText else { return nil }
        return secondaryText
    }

    private var responsePreviewText: String { secondaryPreviewText ?? turn.preview.primaryText }

    private var accessibilitySummary: String {
        var parts = [turn.preview.primaryText]
        if let secondaryPreviewText { parts.append(secondaryPreviewText) }
        if turn.preview.toolCallCount > 0 { parts.append("\(turn.preview.toolCallCount) tool \(turn.preview.toolCallCount == 1 ? "call" : "calls")") }
        if turn.preview.eventCount > 0 { parts.append("\(turn.preview.eventCount) \(turn.preview.eventCount == 1 ? "event" : "events")") }
        if turn.preview.imageCount > 0 { parts.append("\(turn.preview.imageCount) \(turn.preview.imageCount == 1 ? "image" : "images")") }
        return parts.joined(separator: ". ")
    }
}

private struct CollapsedTurnMeta: Identifiable {
    let id: String
    let systemImage: String?
    let text: String
}

private struct CollapsedTurnMetaItem: View {
    let systemImage: String?
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .macrodexFont(size: 9, weight: .medium)
                    .foregroundColor(MacrodexTheme.textMuted)
            }
            Text(verbatim: text)
                .macrodexMonoFont(size: 10)
                .foregroundColor(MacrodexTheme.textSecondary)
                .lineLimit(1)
        }
    }
}

private struct ScrollToBottomIndicator: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down")
                    .macrodexFont(.caption, weight: .bold)
                Text("Latest")
                    .macrodexFont(.caption, weight: .semibold)
            }
            .foregroundColor(MacrodexTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(GlassCapsuleModifier())
        }
        .contentShape(Capsule())
    }
}

private struct ConversationInputBar: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let snapshot: ConversationComposerSnapshot
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @AppStorage("fastMode") private var fastMode = false

    let onSend: (String, [UIImage], [SkillMentionSelection]) -> Void
    let onFileSearch: (String) async throws -> [FileSearchResult]
    var bottomInset: CGFloat = 0
    let dismissComposerToken: Int
    let autoFocusComposer: Bool
    let onAutoFocusComposerConsumed: (() -> Void)?
    let showModeChip: Bool
    let onOpenModePicker: () -> Void
    let onOpenConversation: ((ThreadKey) -> Void)?
    let onResumeSessions: ((String) -> Void)?

    @State private var inputText = ""
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var attachedImages: [UIImage] = []
    @State private var cameraImage: UIImage?
    @State private var showSlashPopup = false
    @State private var activeSlashToken: ComposerSlashQueryContext?
    @State private var slashSuggestions: [ComposerSlashCommand] = []
    @State private var showFilePopup = false
    @State private var activeAtToken: ComposerTokenContext?
    @State private var showSkillPopup = false
    @State private var activeDollarToken: ComposerTokenContext?
    @State private var isFoodSearchMode = false
    @State private var foodSearchLoading = false
    @State private var foodSearchResults: [ComposerFoodSearchResult] = []
    @State private var foodSearchTask: Task<Void, Never>?
    @State private var foodSearchCache: [String: [ComposerFoodSearchResult]] = [:]
    @State private var fileSearchLoading = false
    @State private var fileSearchError: String?
    @State private var fileSuggestions: [FileSearchResult] = []
    @State private var fileSearchGeneration = 0
    @State private var fileSearchTask: Task<Void, Never>?
    @State private var popupRefreshTask: Task<Void, Never>?
    @State private var showModelSelector = false
    @State private var showPermissionsSheet = false
    @State private var showSkillsSheet = false
    @State private var showRenamePrompt = false
    @State private var renameCurrentThreadTitle = ""
    @State private var renameDraft = ""
    @State private var slashErrorMessage: String?
    @State private var skills: [SkillMetadata] = []
    @State private var skillsLoading = false
    @State private var mentionSkillPathsByName: [String: String] = [:]
    @State private var hasAttemptedSkillMentionLoad = false
    @State private var voiceManager = VoiceTranscriptionManager()
    @State private var showMicPermissionAlert = false
    @State private var hasLoggedFirstFocus = false
    @State private var hasLoggedKeyboardShown = false
    @State private var isComposerFocused = false
    @State private var autoFocusTask: Task<Void, Never>?
    @State private var composerContentHeight: CGFloat = 56
    @State private var keyboardVisible = false

    private var pendingUserInputRequest: PendingUserInputRequest? {
        snapshot.pendingUserInputRequest
    }

    private var pendingModelOverride: String? {
        let trimmed = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var isTurnActive: Bool {
        snapshot.isTurnActive
    }

    private var activeTurnId: String? {
        guard let value = snapshot.activeTurnId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private var popupState: ConversationComposerPopupState {
        if showSlashPopup {
            return .slash(slashSuggestions)
        }
        if showFilePopup {
            return .file(
                loading: fileSearchLoading,
                error: fileSearchError,
                suggestions: fileSuggestions
            )
        }
        if showSkillPopup {
            return .skill(loading: skillsLoading, suggestions: skillSuggestions)
        }
        if isFoodSearchMode {
            return .foodSearch(loading: foodSearchLoading, suggestions: foodSearchResults)
        }
        return .none
    }

    var body: some View {
        ConversationComposerModalCoordinator(
            snapshot: snapshot,
            skills: skills,
            skillsLoading: skillsLoading,
            showAttachMenu: $showAttachMenu,
            showPhotoPicker: $showPhotoPicker,
            showCamera: $showCamera,
            selectedPhotos: $selectedPhotos,
            cameraImage: $cameraImage,
            showModelSelector: $showModelSelector,
            showPermissionsSheet: $showPermissionsSheet,
            showSkillsSheet: $showSkillsSheet,
            showRenamePrompt: $showRenamePrompt,
            renameCurrentThreadTitle: $renameCurrentThreadTitle,
            renameDraft: $renameDraft,
            slashErrorMessage: $slashErrorMessage,
            showMicPermissionAlert: $showMicPermissionAlert,
            onOpenSettings: openAppSettings,
            onLoadSelectedPhotos: loadSelectedPhotos,
            onLoadSkills: { forceReload, showErrors in
                await loadSkills(forceReload: forceReload, showErrors: showErrors)
            },
            onRenameThread: renameThread
        ) {
            composerSurface
        }
        .onChange(of: inputText) { _, next in
            ConversationComposerDraftStore.save(next, for: snapshot.threadKey)
            scheduleComposerPopupRefresh(for: next)
            scheduleFoodSearch(for: next)
        }
        .onChange(of: snapshot.composerPrefillRequest?.id) { _, _ in
            guard let prefill = snapshot.composerPrefillRequest else { return }
            inputText = prefill.text
            attachedImages = []
            hideComposerPopups()
            appModel.clearComposerPrefill(id: prefill.id)
        }
        .onChange(of: snapshot.threadKey.threadId) { _, _ in
            restoreDraftIfNeeded()
        }
        .onChange(of: cameraImage) { _, image in
            guard let image else { return }
            appendAttachment(image)
            cameraImage = nil
        }
        .onChange(of: dismissComposerToken) { _, _ in
            guard isComposerFocused || showSlashPopup || showFilePopup || showSkillPopup else { return }
            dismissComposerInput()
        }
        .onChange(of: isComposerFocused) { _, focused in
            if focused {
                guard !hasLoggedFirstFocus else { return }
                hasLoggedFirstFocus = true
                os_signpost(.event, log: conversationViewSignpostLog, name: "ComposerFirstFocus")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            guard !hasLoggedKeyboardShown else { return }
            hasLoggedKeyboardShown = true
            os_signpost(.event, log: conversationViewSignpostLog, name: "KeyboardShown")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .macrodexShouldDismissKeyboard)) { _ in
            dismissComposerInput()
        }
        .onAppear {
            restoreDraftIfNeeded()
            guard autoFocusComposer, !snapshot.isTurnActive else { return }
            onAutoFocusComposerConsumed?()
            autoFocusTask?.cancel()
            autoFocusTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                isComposerFocused = true
            }
        }
        .onDisappear {
            autoFocusTask?.cancel()
            autoFocusTask = nil
            if voiceManager.isRecording { voiceManager.cancelRecording() }
            popupRefreshTask?.cancel()
            popupRefreshTask = nil
            fileSearchTask?.cancel()
            fileSearchTask = nil
            foodSearchTask?.cancel()
            foodSearchTask = nil
        }
    }

    private func restoreDraftIfNeeded() {
        guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshot.composerPrefillRequest == nil
        else { return }
        let draft = ConversationComposerDraftStore.text(for: snapshot.threadKey)
        guard !draft.isEmpty else { return }
        inputText = draft
    }

    private func dismissComposerInput() {
        autoFocusTask?.cancel()
        autoFocusTask = nil
        hideComposerPopups()
        isComposerFocused = false
    }

    private var composerSurface: some View {
        VStack(spacing: 0) {
            ConversationComposerContentView(
                attachedImages: attachedImages,
                collaborationMode: snapshot.collaborationMode,
                activePlanProgress: snapshot.activePlanProgress,
                pendingUserInputRequest: pendingUserInputRequest,
                hasPendingPlanImplementation: snapshot.pendingPlanImplementationPrompt != nil,
                activeTaskSummary: snapshot.activeTaskSummary,
                queuedFollowUps: snapshot.queuedFollowUps,
                rateLimits: snapshot.rateLimits,
                contextPercent: contextPercent(),
                isTurnActive: isTurnActive,
                showModeChip: showModeChip,
                voiceManager: voiceManager,
                isFoodSearchMode: isFoodSearchMode,
                keepsAttachmentButtonVisible: true,
                showAttachMenu: $showAttachMenu,
                onRemoveAttachment: { removeAttachment(at: $0) },
                onRespondToPendingUserInput: respondToPendingUserInput,
                onImplementPlan: { Task { await implementPlan() } },
                onDismissPlanImplementation: dismissPlanImplementationPrompt,
                onSteerQueuedFollowUp: steerQueuedFollowUp,
                onDeleteQueuedFollowUp: deleteQueuedFollowUp,
                onPasteImage: appendAttachment,
                onToggleFoodSearchMode: toggleFoodSearchMode,
                onOpenModePicker: onOpenModePicker,
                onSendText: handleSend,
                onStopRecording: stopVoiceRecording,
                onStartRecording: startVoiceRecording,
                onInterrupt: interruptActiveTurn,
                inputText: $inputText,
                isComposerFocused: $isComposerFocused
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ConversationComposerContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
        }
        .overlay(alignment: .bottom) {
            ConversationComposerPopupOverlayView(
                state: popupState,
                onApplySlashSuggestion: applySlashSuggestion,
                onApplyFileSuggestion: applyFileSuggestion,
                onApplySkillSuggestion: applySkillSuggestion,
                bottomInset: composerContentHeight + 8,
                onApplyFoodSuggestion: applyFoodSuggestion
            )
        }
        .offset(y: keyboardVisible ? 12 : 0)
        .onPreferenceChange(ConversationComposerContentHeightPreferenceKey.self) { height in
            composerContentHeight = max(56, height)
        }
    }

    private func contextPercent() -> Int64? {
        guard let contextWindow = snapshot.modelContextWindow else { return nil }
        let baseline: Int64 = 12_000
        guard contextWindow > baseline else { return 0 }
        let totalTokens = snapshot.contextTokensUsed ?? baseline
        let effectiveWindow = contextWindow - baseline
        let usedTokens = max(0, totalTokens - baseline)
        let remainingTokens = max(0, effectiveWindow - usedTokens)
        let percent = Int64((Double(remainingTokens) / Double(effectiveWindow) * 100).rounded())
        return min(max(percent, 0), 100)
    }

    private func appendAttachment(_ image: UIImage) {
        guard attachedImages.count < 6 else { return }
        attachedImages.append(image)
    }

    private func removeAttachment(at index: Int) {
        guard attachedImages.indices.contains(index) else { return }
        attachedImages.remove(at: index)
    }

    private func respondToPendingUserInput(_ answers: [String: [String]]) {
        guard let pendingUserInputRequest else { return }
        let payload: [PendingUserInputAnswer] = pendingUserInputRequest.questions.compactMap { question in
            guard let selectedAnswers = answers[question.id], !selectedAnswers.isEmpty else { return nil }
            return PendingUserInputAnswer(questionId: question.id, answers: selectedAnswers)
        }
        Task {
            do {
                try await appModel.store.respondToUserInput(
                    requestId: pendingUserInputRequest.id,
                    answers: payload
                )
            } catch {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func steerQueuedFollowUp(_ preview: AppQueuedFollowUpPreview) {
        Task {
            do {
                try await appModel.store.steerQueuedFollowUp(
                    key: snapshot.threadKey,
                    previewId: preview.id
                )
            } catch {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func deleteQueuedFollowUp(_ preview: AppQueuedFollowUpPreview) {
        Task {
            do {
                try await appModel.store.deleteQueuedFollowUp(
                    key: snapshot.threadKey,
                    previewId: preview.id
                )
            } catch {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func handleSend() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachedImages
        guard !text.isEmpty || !images.isEmpty else { return }
        if images.isEmpty,
           let invocation = parseSlashCommandInvocation(text) {
            inputText = ""
            ConversationComposerDraftStore.clear(for: snapshot.threadKey)
            attachedImages = []
            hideComposerPopups()
            isComposerFocused = false
            executeSlashCommand(invocation.command, args: invocation.args)
            return
        }
        inputText = ""
        ConversationComposerDraftStore.clear(for: snapshot.threadKey)
        attachedImages = []
        isFoodSearchMode = false
        hideComposerPopups()
        isComposerFocused = false
        let skillMentions = collectSkillMentionsForSubmission(text)
        onSend(text, images, skillMentions)
    }

    private func startVoiceRecording() {
        Task {
            let granted = await voiceManager.requestMicPermission()
            guard granted else {
                showMicPermissionAlert = true
                return
            }
            voiceManager.startRecording()
        }
    }

    private func stopVoiceRecording() {
        Task {
            let auth = try? await appModel.client.authStatus(
                serverId: snapshot.threadKey.serverId,
                params: AuthStatusRequest(includeToken: true, refreshToken: false)
            )
            if let text = await voiceManager.stopAndTranscribe(
                authMethod: auth?.authMethod,
                authToken: auth?.authToken
            ), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = text
                DispatchQueue.main.async {
                    isComposerFocused = true
                }
            }
        }
    }

    private func interruptActiveTurn() {
        guard let activeTurnId else { return }
        Task {
            do {
                _ = try await appModel.client.interruptTurn(
                    serverId: snapshot.threadKey.serverId,
                    params: AppInterruptTurnRequest(
                        threadId: snapshot.threadKey.threadId,
                        turnId: activeTurnId
                    )
                )
            } catch {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard attachedImages.count < 6 else { break }
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                appendAttachment(image)
            }
        }
        selectedPhotos = []
    }

    private func dismissPlanImplementationPrompt() {
        appModel.store.dismissPlanImplementationPrompt(key: snapshot.threadKey)
    }

    private func implementPlan() async {
        do {
            try await appModel.store.implementPlan(key: snapshot.threadKey)
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }


    private func clearFileSearchState(incrementGeneration: Bool = true) {
        let hadTask = fileSearchTask != nil
        fileSearchTask?.cancel()
        fileSearchTask = nil
        if incrementGeneration && (hadTask || fileSearchLoading || fileSearchError != nil || !fileSuggestions.isEmpty) {
            fileSearchGeneration += 1
        }
        if fileSearchLoading {
            fileSearchLoading = false
        }
        if fileSearchError != nil {
            fileSearchError = nil
        }
        if !fileSuggestions.isEmpty {
            fileSuggestions = []
        }
        clearFoodSearchState(cancelTask: true)
    }

    private func toggleFoodSearchMode() {
        isFoodSearchMode.toggle()
        if isFoodSearchMode {
            showSlashPopup = false
            showFilePopup = false
            showSkillPopup = false
            isComposerFocused = true
            scheduleFoodSearch(for: inputText)
        } else {
            clearFoodSearchState(cancelTask: true)
        }
    }

    private func clearFoodSearchState(cancelTask: Bool) {
        if cancelTask {
            foodSearchTask?.cancel()
            foodSearchTask = nil
        }
        foodSearchLoading = false
        foodSearchResults = []
    }

    private func scheduleFoodSearch(for query: String) {
        guard isFoodSearchMode else {
            clearFoodSearchState(cancelTask: true)
            return
        }
        foodSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearFoodSearchState(cancelTask: false)
            return
        }
        if let cached = foodSearchCache[trimmed] {
            foodSearchResults = cached
            foodSearchLoading = false
            return
        }
        foodSearchLoading = true
        foodSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await CalorieTrackerStore.shared.refresh()
            guard !Task.isCancelled else { return }
            let localResults = foodSearchMatches(for: trimmed)
            foodSearchResults = localResults
            if trimmed.count >= 2 {
                let candidates = localResults
                let rankedResults = await FoodSearchAIResolver.results(
                    query: trimmed,
                    candidates: candidates,
                    timeoutSeconds: 10
                )
                guard !Task.isCancelled else { return }
                foodSearchResults = rankedResults
                foodSearchCache[trimmed] = rankedResults
            } else {
                foodSearchCache[trimmed] = localResults
            }
            foodSearchLoading = false
        }
    }

    private func foodSearchMatches(for query: String) -> [ComposerFoodSearchResult] {
        let libraryMatches = CalorieTrackerStore.shared.libraryItems.compactMap { item -> (ComposerFoodSearchResult, Int)? in
            let candidates = [item.name, item.brand, item.kind, item.sourceTitle] + item.aliases.map(Optional.some)
            let score = candidates.compactMap { $0 }.compactMap { fuzzyScore(candidate: $0, query: query) }.max()
            guard let score else { return nil }
            let title = item.brand.map { "\($0) \(item.name)" } ?? item.name
            return (
                ComposerFoodSearchResult(
                    id: "library-\(item.id)",
                    title: title,
                    detail: item.detail,
                    insertText: title,
                    servingQuantity: item.defaultServingQty,
                    servingUnit: item.defaultServingUnit,
                    servingWeight: item.defaultServingWeight,
                    calories: item.calories,
                    protein: item.protein,
                    carbs: item.carbs,
                    fat: item.fat,
                    source: item.sourceTitle,
                    sourceURL: item.sourceURL,
                    notes: item.notes,
                    confidence: confidence(from: score + (item.isFavorite ? 12 : 0))
                ),
                score + (item.isFavorite ? 12 : 0)
            )
        }
        let recentMatches = CalorieTrackerStore.shared.recentFoodMemories.compactMap { item -> (ComposerFoodSearchResult, Int)? in
            let candidates = [item.title, item.displayName, item.brand, item.canonicalName]
            let score = candidates.compactMap { $0 }.compactMap { fuzzyScore(candidate: $0, query: query) }.max()
            guard let score else { return nil }
            return (
                ComposerFoodSearchResult(
                    id: "recent-\(item.id)",
                    title: item.title,
                    detail: item.detail,
                    insertText: item.title,
                    servingQuantity: item.defaultServingQty,
                    servingUnit: item.defaultServingUnit,
                    servingWeight: item.defaultServingWeight,
                    calories: item.calories,
                    protein: item.protein,
                    carbs: item.carbs,
                    fat: item.fat,
                    source: "Recent food",
                    notes: "Logged before",
                    confidence: confidence(from: score + 6)
                ),
                score + 6
            )
        }
        let standardMatches = StandardFoodDatabase.matches(query: query).map { food, score in
            (
                ComposerFoodSearchResult(
                    id: "standard-\(food.id)",
                    title: food.name,
                    detail: food.detail,
                    insertText: food.name,
                    servingQuantity: food.servingQuantity,
                    servingUnit: food.servingUnit,
                    servingWeight: food.servingWeight,
                    calories: food.calories,
                    protein: food.protein,
                    carbs: food.carbs,
                    fat: food.fat,
                    source: "Foundation food",
                    notes: "Built-in common food estimate",
                    confidence: confidence(from: score + 3)
                ),
                score + 3
            )
        }
        return (libraryMatches + recentMatches + standardMatches)
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    private func confidence(from score: Int) -> Double {
        if score >= 9_500 { return 0.98 }
        if score >= 7_500 { return 0.94 }
        if score >= 5_500 { return 0.88 }
        return min(max(0.54 + Double(score) / 10_000, 0.56), 0.84)
    }

    private func hideComposerPopups() {
        popupRefreshTask?.cancel()
        popupRefreshTask = nil
        if showSlashPopup {
            showSlashPopup = false
        }
        if activeSlashToken != nil {
            activeSlashToken = nil
        }
        if !slashSuggestions.isEmpty {
            slashSuggestions = []
        }
        if showFilePopup {
            showFilePopup = false
        }
        if activeAtToken != nil {
            activeAtToken = nil
        }
        if showSkillPopup {
            showSkillPopup = false
        }
        if activeDollarToken != nil {
            activeDollarToken = nil
        }
        clearFileSearchState()
    }

    private func startFileSearch(_ query: String) {
        fileSearchTask?.cancel()
        fileSearchTask = nil
        let requestId = fileSearchGeneration + 1
        fileSearchGeneration = requestId
        if !fileSearchLoading {
            fileSearchLoading = true
        }
        if fileSearchError != nil {
            fileSearchError = nil
        }
        if !fileSuggestions.isEmpty {
            fileSuggestions = []
        }

        fileSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            guard activeAtToken?.value == query else { return }

            do {
                let matches = try await onFileSearch(query)
                guard !Task.isCancelled else { return }
                guard requestId == fileSearchGeneration, activeAtToken?.value == query else { return }
                fileSuggestions = matches
                fileSearchLoading = false
                fileSearchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                guard requestId == fileSearchGeneration, activeAtToken?.value == query else { return }
                fileSuggestions = []
                fileSearchLoading = false
                fileSearchError = error.localizedDescription
            }
        }
    }

    private func scheduleComposerPopupRefresh(for nextText: String) {
        guard !isFoodSearchMode else {
            if showSlashPopup || showFilePopup || showSkillPopup {
                showSlashPopup = false
                showFilePopup = false
                showSkillPopup = false
            }
            return
        }
        popupRefreshTask?.cancel()
        let needsPopupEvaluation =
            showSlashPopup ||
            showFilePopup ||
            showSkillPopup ||
            activeSlashToken != nil ||
            activeAtToken != nil ||
            activeDollarToken != nil ||
            nextText.contains("/") ||
            nextText.contains("@") ||
            nextText.contains("$")

        guard needsPopupEvaluation else {
            hideComposerPopups()
            return
        }

        popupRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            refreshComposerPopups(for: nextText)
        }
    }

    private func refreshComposerPopups(for nextText: String) {
        let cursor = nextText.count
        if let atToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "@",
            allowEmpty: true
        ) {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            if showSkillPopup {
                showSkillPopup = false
            }
            if activeDollarToken != nil {
                activeDollarToken = nil
            }
            if !showFilePopup {
                showFilePopup = true
            }
            if activeAtToken != atToken {
                activeAtToken = atToken
                startFileSearch(atToken.value)
            }
            return
        }

        if activeAtToken != nil || showFilePopup || fileSearchTask != nil || fileSearchLoading || fileSearchError != nil || !fileSuggestions.isEmpty {
            activeAtToken = nil
            if showFilePopup {
                showFilePopup = false
            }
            clearFileSearchState()
        }

        if let dollarToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "$",
            allowEmpty: true
        ), isMentionQueryValid(dollarToken.value) {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            if !showSkillPopup {
                showSkillPopup = true
            }
            if activeDollarToken != dollarToken {
                activeDollarToken = dollarToken
            }
            if !hasAttemptedSkillMentionLoad && !skillsLoading {
                hasAttemptedSkillMentionLoad = true
                Task { await loadSkills(showErrors: false) }
            }
            return
        }

        if activeDollarToken != nil || showSkillPopup {
            activeDollarToken = nil
            if showSkillPopup {
                showSkillPopup = false
            }
        }

        guard let slashToken = currentSlashQueryContext(text: nextText, cursor: cursor) else {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            return
        }

        if activeSlashToken != slashToken {
            activeSlashToken = slashToken
        }
        let suggestions = filterSlashCommands(slashToken.query)
        if slashSuggestions != suggestions {
            slashSuggestions = suggestions
        }
        let shouldShow = !suggestions.isEmpty
        if showSlashPopup != shouldShow {
            showSlashPopup = shouldShow
        }
    }

    private func applySlashSuggestion(_ command: ComposerSlashCommand) {
        showSlashPopup = false
        activeSlashToken = nil
        slashSuggestions = []
        inputText = ""
        attachedImages = []
        isComposerFocused = false
        executeSlashCommand(command, args: nil)
    }

    private func executeSlashCommand(_ command: ComposerSlashCommand, args: String?) {
        switch command {
        case .skills:
            showSkillsSheet = true
            Task { await loadSkills() }
        case .review:
            Task { await startReview() }
        case .rename:
            let initialName = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if initialName.isEmpty {
                let currentTitle = snapshot.threadPreview.trimmingCharacters(in: .whitespacesAndNewlines)
                renameCurrentThreadTitle = currentTitle.isEmpty ? "New Chat" : currentTitle
                renameDraft = ""
                showRenamePrompt = true
            } else {
                Task { await renameThread(initialName) }
            }
        case .fork:
            Task { await forkConversation() }
        case .resume:
            onResumeSessions?(snapshot.threadKey.serverId)
        }
    }

    private func parseSlashCommandInvocation(_ text: String) -> (command: ComposerSlashCommand, args: String?)? {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let commandAndArgs = trimmed.dropFirst()
        let commandName = commandAndArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard let command = ComposerSlashCommand(rawCommand: commandName) else { return nil }
        let args = commandAndArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).dropFirst().first.map(String.init)
        return (command, args)
    }

    private func startReview() async {
        do {
            _ = try await appModel.client.startReview(
                serverId: snapshot.threadKey.serverId,
                params: AppStartReviewRequest(
                    threadId: snapshot.threadKey.threadId,
                    target: .uncommittedChanges,
                    delivery: "inline"
                )
            )
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func renameThread(_ newName: String) async {
        do {
            _ = try await appModel.client.renameThread(
                serverId: snapshot.threadKey.serverId,
                params: AppRenameThreadRequest(threadId: snapshot.threadKey.threadId, name: newName)
            )
            ManualThreadTitleStore.markManuallyRenamed(snapshot.threadKey)
            await appModel.refreshSnapshot()
            showRenamePrompt = false
            renameCurrentThreadTitle = ""
            renameDraft = ""
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func forkConversation() async {
        do {
            let nextKey = try await appModel.client.forkThread(
                serverId: snapshot.threadKey.serverId,
                params: AppThreadLaunchConfig(
                    model: pendingModelOverride,
                    approvalPolicy: appState.launchApprovalPolicy(for: snapshot.threadKey),
                    sandbox: appState.launchSandboxMode(for: snapshot.threadKey),
                    developerInstructions: AgentRuntimeInstructions.developerInstructions(for: snapshot.threadKey),
                    persistExtendedHistory: true
                ).threadForkRequest(threadId: snapshot.threadKey.threadId, cwdOverride: workDir)
            )
            appModel.store.setActiveThread(key: nextKey)
            await appModel.refreshSnapshot()
            let nextCwd = workDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nextCwd.isEmpty {
                workDir = nextCwd
                appState.currentCwd = nextCwd
            }
            onOpenConversation?(nextKey)
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func loadSkills(forceReload: Bool = false) async {
        await loadSkills(forceReload: forceReload, showErrors: true)
    }

    private func loadSkills(forceReload: Bool = false, showErrors: Bool) async {
        guard appModel.snapshot?.servers.first(where: { $0.serverId == snapshot.threadKey.serverId })?.canUseTransportActions == true else {
            skills = []
            mentionSkillPathsByName = [:]
            if showErrors {
                slashErrorMessage = "Not connected to a server"
            }
            return
        }
        skillsLoading = true
        defer { skillsLoading = false }
        do {
            let fetchedSkills = try await appModel.client.listSkills(
                serverId: snapshot.threadKey.serverId,
                params: AppListSkillsRequest(
                    cwds: [workDir],
                    forceReload: forceReload
                )
            )
            let loadedSkills = fetchedSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            skills = loadedSkills
            let validPaths = Set(loadedSkills.map { $0.path.value })
            mentionSkillPathsByName = mentionSkillPathsByName.filter { _, path in validPaths.contains(path) }
        } catch {
            if showErrors {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyFileSuggestion(_ match: FileSearchResult) {
        guard let token = activeAtToken else { return }
        let quotedPath = (match.path.contains(" ") && !match.path.contains("\"")) ? "\"\(match.path)\"" : match.path
        let replacement = "\(quotedPath) "
        guard let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) else { return }
        inputText = updated
        showFilePopup = false
        activeAtToken = nil
        clearFileSearchState()
    }

    private var skillSuggestions: [SkillMetadata] {
        guard let token = activeDollarToken else { return [] }
        return filterSkillSuggestions(token.value)
    }

    private func filterSkillSuggestions(_ query: String) -> [SkillMetadata] {
        guard !skills.isEmpty else { return [] }
        guard !query.isEmpty else { return skills.sorted { lhs, rhs in lhs.name.lowercased() < rhs.name.lowercased() } }
        return skills
            .compactMap { skill -> (SkillMetadata, Int)? in
                let scoreFromName = fuzzyScore(candidate: skill.name, query: query)
                let scoreFromDescription = fuzzyScore(candidate: skill.description, query: query)
                let best = max(scoreFromName ?? Int.min, scoreFromDescription ?? Int.min)
                guard best != Int.min else { return nil }
                return (skill, best)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.name.lowercased() < rhs.0.name.lowercased()
            }
            .map(\.0)
    }

    private func applySkillSuggestion(_ skill: SkillMetadata) {
        guard let token = activeDollarToken else { return }
        let replacement = "$\(skill.name) "
        guard let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) else { return }
        inputText = updated
        mentionSkillPathsByName[skill.name.lowercased()] = skill.path.value
        showSkillPopup = false
        activeDollarToken = nil
    }

    private func applyFoodSuggestion(_ suggestion: ComposerFoodSearchResult) {
        inputText = suggestion.insertText
        isComposerFocused = true
        clearFoodSearchState(cancelTask: true)
        isFoodSearchMode = false
    }

    private func collectSkillMentionsForSubmission(_ text: String) -> [SkillMentionSelection] {
        guard !skills.isEmpty else { return [] }
        let mentionNames = extractMentionNames(text)
        guard !mentionNames.isEmpty else { return [] }

        let skillsByName = Dictionary(grouping: skills, by: { $0.name.lowercased() })
        let skillsByPath = Dictionary(grouping: skills, by: \.path.value)
        var seenPaths = Set<String>()
        var resolved: [SkillMentionSelection] = []

        for mentionName in mentionNames {
            let normalizedName = mentionName.lowercased()
            if let selectedPath = mentionSkillPathsByName[normalizedName], !selectedPath.isEmpty {
                if let selectedSkill = skillsByPath[selectedPath]?.first {
                    guard seenPaths.insert(selectedPath).inserted else { continue }
                    resolved.append(SkillMentionSelection(name: selectedSkill.name, path: selectedPath))
                    continue
                }
                mentionSkillPathsByName.removeValue(forKey: normalizedName)
            }

            guard let candidates = skillsByName[normalizedName], candidates.count == 1 else {
                continue
            }
            let match = candidates[0]
            guard seenPaths.insert(match.path.value).inserted else { continue }
            resolved.append(SkillMentionSelection(name: match.name, path: match.path.value))
        }
        return resolved
    }
}

private struct CollaborationModeSelectorSheet: View {
    let presets: [AppCollaborationModePreset]
    let selectedMode: AppModeKind
    let isLoading: Bool
    let onSelect: (AppModeKind) -> Void

    var body: some View {
        NavigationStack {
            List {
                if isLoading && presets.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading modes…")
                            .macrodexFont(.body)
                            .foregroundStyle(MacrodexTheme.textSecondary)
                    }
                    .listRowBackground(MacrodexTheme.surface)
                }

                ForEach(presets, id: \.kind) { preset in
                    Button(action: { onSelect(preset.kind) }) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                    .macrodexFont(.body, weight: .semibold)
                                    .foregroundStyle(MacrodexTheme.textPrimary)
                                if let reasoningEffort = preset.reasoningEffort {
                                    Text(collaborationModeEffortLabel(reasoningEffort))
                                        .macrodexFont(.caption)
                                        .foregroundStyle(MacrodexTheme.textSecondary)
                                }
                            }
                            Spacer()
                            if preset.kind == selectedMode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(MacrodexTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(MacrodexTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(MacrodexTheme.surface)
            .navigationTitle("Collaboration Mode")
        }
    }
}

private func collaborationModeEffortLabel(_ effort: ReasoningEffort) -> String {
    switch effort {
    case .none:
        return "None"
    case .minimal:
        return "Minimal"
    case .low:
        return "Low"
    case .medium:
        return "Medium"
    case .high:
        return "High"
    case .xHigh:
        return "XHigh"
    }
}

enum ComposerSlashCommand: CaseIterable {
    case skills
    case review
    case rename
    case fork
    case resume

    var rawValue: String {
        switch self {
        case .skills: return "skills"
        case .review: return "review"
        case .rename: return "rename"
        case .fork: return "fork"
        case .resume: return "resume"
        }
    }

    var description: String {
        switch self {
        case .skills: return "use skills to improve how the agent performs specific tasks"
        case .review: return "review my current changes and find issues"
        case .rename: return "rename the current chat"
        case .fork: return "fork the current conversation into a new chat"
        case .resume: return "resume a saved chat"
        }
    }

    init?(rawCommand: String) {
        switch rawCommand.lowercased() {
        case "skills": self = .skills
        case "review": self = .review
        case "rename": self = .rename
        case "fork": self = .fork
        case "resume": self = .resume
        default: return nil
        }
    }
}

enum ComposerApprovalOption: CaseIterable, Identifiable {
    case `default`
    case untrusted
    case onFailure
    case onRequest
    case never

    var id: String { wireValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .untrusted: return "Untrusted"
        case .onFailure: return "On failure"
        case .onRequest: return "On request"
        case .never: return "Never"
        }
    }

    var description: String {
        switch self {
        case .default: return "Use the chat or server default"
        case .untrusted: return "Always ask before taking action"
        case .onFailure: return "Ask only when a command fails"
        case .onRequest: return "Ask when escalation is requested"
        case .never: return "Run without asking for approval"
        }
    }

    var wireValue: String {
        switch self {
        case .default: return "inherit"
        case .untrusted: return "untrusted"
        case .onFailure: return "on-failure"
        case .onRequest: return "on-request"
        case .never: return "never"
        }
    }
}

enum ComposerSandboxOption: CaseIterable, Identifiable {
    case `default`
    case readOnly
    case workspaceWrite
    case fullAccess

    var id: String { wireValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .readOnly: return "Read only"
        case .workspaceWrite: return "Workspace write"
        case .fullAccess: return "Full access"
        }
    }

    var description: String {
        switch self {
        case .default: return "Use the chat or server default"
        case .readOnly: return "Can read files, but cannot edit them"
        case .workspaceWrite: return "Can edit files, but only in this workspace"
        case .fullAccess: return "Can edit files outside this workspace"
        }
    }

    var wireValue: String {
        switch self {
        case .default: return "inherit"
        case .readOnly: return "read-only"
        case .workspaceWrite: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }
}

private struct ComposerTokenRange: Equatable {
    let start: Int
    let end: Int
}

private struct ComposerTokenContext: Equatable {
    let value: String
    let range: ComposerTokenRange
}

private struct ComposerSlashQueryContext: Equatable {
    let query: String
    let range: ComposerTokenRange
}

private func filterSlashCommands(_ query: String) -> [ComposerSlashCommand] {
    guard !query.isEmpty else { return Array(ComposerSlashCommand.allCases) }
    return ComposerSlashCommand.allCases
        .compactMap { command -> (ComposerSlashCommand, Int)? in
            guard let score = fuzzyScore(candidate: command.rawValue, query: query) else { return nil }
            return (command, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return lhs.0.rawValue < rhs.0.rawValue
        }
        .map(\.0)
}

private func fuzzyScore(candidate: String, query: String) -> Int? {
    let normalizedCandidate = candidate.lowercased()
    let normalizedQuery = query.lowercased()

    if normalizedCandidate == normalizedQuery {
        return 1000
    }
    if normalizedCandidate.hasPrefix(normalizedQuery) {
        return 900 - (normalizedCandidate.count - normalizedQuery.count)
    }
    if normalizedCandidate.contains(normalizedQuery) {
        return 700 - (normalizedCandidate.count - normalizedQuery.count)
    }

    var score = 0
    var queryIndex = normalizedQuery.startIndex
    var candidateIndex = normalizedCandidate.startIndex

    while queryIndex < normalizedQuery.endIndex && candidateIndex < normalizedCandidate.endIndex {
        if normalizedQuery[queryIndex] == normalizedCandidate[candidateIndex] {
            score += 10
            queryIndex = normalizedQuery.index(after: queryIndex)
        }
        candidateIndex = normalizedCandidate.index(after: candidateIndex)
    }

    return queryIndex == normalizedQuery.endIndex ? score : nil
}

private let kDollarSign: UInt8 = 0x24
private let kUnderscore: UInt8 = 0x5F
private let kHyphen: UInt8 = 0x2D

private func isMentionNameByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x61...0x7A, // a-z
        0x41...0x5A,  // A-Z
        0x30...0x39,  // 0-9
        kUnderscore,
        kHyphen:
        return true
    default:
        return false
    }
}

private func isMentionQueryValid(_ query: String) -> Bool {
    guard !query.isEmpty else { return true }
    return query.utf8.allSatisfy(isMentionNameByte)
}

private func extractMentionNames(_ text: String) -> [String] {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty else { return [] }

    var mentions: [String] = []
    var index = 0
    while index < bytes.count {
        guard bytes[index] == kDollarSign else {
            index += 1
            continue
        }

        if index > 0, isMentionNameByte(bytes[index - 1]) {
            index += 1
            continue
        }

        let nameStart = index + 1
        guard nameStart < bytes.count, isMentionNameByte(bytes[nameStart]) else {
            index += 1
            continue
        }

        var nameEnd = nameStart + 1
        while nameEnd < bytes.count, isMentionNameByte(bytes[nameEnd]) {
            nameEnd += 1
        }

        if let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) {
            mentions.append(name)
        }
        index = nameEnd
    }

    return mentions
}

private func currentPrefixedToken(
    text: String,
    cursor: Int,
    prefix: Character,
    allowEmpty: Bool
) -> ComposerTokenContext? {
    guard let tokenRange = tokenRangeAroundCursor(text: text, cursor: cursor) else { return nil }
    guard let tokenText = substring(text, within: tokenRange), tokenText.first == prefix else { return nil }
    let value = String(tokenText.dropFirst())
    if value.isEmpty && !allowEmpty {
        return nil
    }
    return ComposerTokenContext(value: value, range: tokenRange)
}

private func currentSlashQueryContext(
    text: String,
    cursor: Int
) -> ComposerSlashQueryContext? {
    let safeCursor = max(0, min(cursor, text.count))
    let firstLineEnd = text.firstIndex(of: "\n").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
    if safeCursor > firstLineEnd || firstLineEnd <= 0 {
        return nil
    }

    let firstLine = String(text.prefix(firstLineEnd))
    guard firstLine.hasPrefix("/") else { return nil }

    var commandEnd = 1
    let chars = Array(firstLine)
    while commandEnd < chars.count && !chars[commandEnd].isWhitespace {
        commandEnd += 1
    }
    if safeCursor > commandEnd {
        return nil
    }

    let query = commandEnd > 1 ? String(chars[1..<commandEnd]) : ""
    let rest = commandEnd < chars.count ? String(chars[commandEnd...]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

    if query.isEmpty {
        if !rest.isEmpty {
            return nil
        }
    } else if query.contains("/") {
        return nil
    }

    return ComposerSlashQueryContext(query: query, range: ComposerTokenRange(start: 0, end: commandEnd))
}

private func tokenRangeAroundCursor(
    text: String,
    cursor: Int
) -> ComposerTokenRange? {
    guard !text.isEmpty else { return nil }

    let safeCursor = max(0, min(cursor, text.count))
    let chars = Array(text)

    if safeCursor < chars.count, chars[safeCursor].isWhitespace {
        var index = safeCursor
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        if index < chars.count {
            var end = index
            while end < chars.count && !chars[end].isWhitespace {
                end += 1
            }
            return ComposerTokenRange(start: index, end: end)
        }
    }

    var start = safeCursor
    while start > 0 && !chars[start - 1].isWhitespace {
        start -= 1
    }

    var end = safeCursor
    while end < chars.count && !chars[end].isWhitespace {
        end += 1
    }

    if end <= start {
        return nil
    }
    return ComposerTokenRange(start: start, end: end)
}

private func replacingRange(
    in text: String,
    with range: ComposerTokenRange,
    replacement: String
) -> String? {
    guard range.start >= 0, range.end <= text.count, range.start <= range.end else { return nil }
    guard let lower = index(in: text, offset: range.start),
          let upper = index(in: text, offset: range.end) else { return nil }
    var copy = text
    copy.replaceSubrange(lower..<upper, with: replacement)
    return copy
}

private func substring(_ text: String, within range: ComposerTokenRange) -> String? {
    guard range.start >= 0, range.end <= text.count, range.start <= range.end else { return nil }
    guard let lower = index(in: text, offset: range.start),
          let upper = index(in: text, offset: range.end) else { return nil }
    return String(text[lower..<upper])
}

private func index(in text: String, offset: Int) -> String.Index? {
    guard offset >= 0, offset <= text.count else { return nil }
    return text.index(text.startIndex, offsetBy: offset)
}

struct PendingUserInputPromptView: View {
    let request: PendingUserInputRequest
    let onSubmit: ([String: [String]]) -> Void

    @State private var selectedAnswers: [String: String] = [:]
    @State private var otherAnswers: [String: String] = [:]

    private var promptTitle: String {
        let firstQuestion = request.questions.first?.question.lowercased() ?? ""
        if firstQuestion.contains("implement") && firstQuestion.contains("plan") {
            return "Implement Plan"
        }
        return "Input Required"
    }

    private var requesterLabel: String? {
        AgentLabelFormatter.format(
            nickname: request.requesterAgentNickname,
            role: request.requesterAgentRole
        )
    }

    private var unsupportedQuestions: [PendingUserInputQuestion] {
        request.questions.filter { question in
            question.isSecret || (!question.isOtherAllowed && question.options.isEmpty)
        }
    }

    private var canSubmit: Bool {
        unsupportedQuestions.isEmpty &&
        request.questions.allSatisfy { !resolvedAnswer(for: $0).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundColor(MacrodexTheme.warning)
                Text(promptTitle)
                    .macrodexFont(.caption, weight: .semibold)
                    .foregroundColor(MacrodexTheme.textPrimary)
                Spacer()
            }

            if let requesterLabel {
                Text(requesterLabel)
                    .macrodexFont(.caption2)
                    .foregroundColor(MacrodexTheme.textMuted)
            }

            ForEach(request.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        Text(header.uppercased())
                            .macrodexFont(.caption2, weight: .bold)
                            .foregroundColor(MacrodexTheme.textMuted)
                    }

                    Text(question.question)
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textPrimary)

                    if question.isSecret || (!question.isOtherAllowed && question.options.isEmpty) {
                        Text("This prompt type is not fully supported in the current iOS client.")
                            .macrodexFont(.caption2)
                            .foregroundColor(MacrodexTheme.textSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if !question.options.isEmpty {
                                // ViewThatFits + VStack fallback so long
                                // option labels wrap to a new row instead
                                // of squeezing a short option into a narrow
                                // column with character-by-character wrapping.
                                let optionButtons = ForEach(question.options, id: \.label) { option in
                                    let isSelected =
                                        selectedAnswers[question.id] == option.label &&
                                        trimmedOtherAnswer(for: question).isEmpty
                                    Button {
                                        selectedAnswers[question.id] = option.label
                                        otherAnswers[question.id] = ""
                                    } label: {
                                        Text(option.label)
                                            .macrodexFont(.caption2, weight: .semibold)
                                            .foregroundColor(isSelected ? MacrodexTheme.textOnAccent : MacrodexTheme.textPrimary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(isSelected ? MacrodexTheme.accent : MacrodexTheme.surface.opacity(0.8))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) { optionButtons }
                                    VStack(alignment: .leading, spacing: 8) { optionButtons }
                                }
                            }

                            if question.isOtherAllowed {
                                TextField(
                                    question.options.isEmpty ? "Enter response" : "Other response",
                                    text: otherAnswerBinding(for: question)
                                )
                                .macrodexFont(.caption2)
                                .foregroundColor(MacrodexTheme.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(MacrodexTheme.surface.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }

            if canSubmit {
                Button("Submit") {
                    let answers = request.questions.reduce(into: [String: [String]]()) { result, question in
                        let answer = resolvedAnswer(for: question)
                        guard !answer.isEmpty else { return }
                        result[question.id] = [answer]
                    }
                    onSubmit(answers)
                }
                .macrodexFont(.caption, weight: .semibold)
                .foregroundColor(MacrodexTheme.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(MacrodexTheme.accent)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(GlassRectModifier(cornerRadius: 14))
    }

    private func otherAnswerBinding(for question: PendingUserInputQuestion) -> Binding<String> {
        Binding(
            get: { otherAnswers[question.id, default: ""] },
            set: { newValue in
                otherAnswers[question.id] = newValue
            }
        )
    }

    private func trimmedOtherAnswer(for question: PendingUserInputQuestion) -> String {
        otherAnswers[question.id, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedAnswer(for question: PendingUserInputQuestion) -> String {
        let other = trimmedOtherAnswer(for: question)
        if !other.isEmpty {
            return other
        }
        return selectedAnswers[question.id, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PlanImplementationPromptView: View {
    let onImplement: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard.fill")
                    .foregroundColor(MacrodexTheme.accent)
                Text("Implement Plan")
                    .macrodexFont(.caption, weight: .semibold)
                    .foregroundColor(MacrodexTheme.textPrimary)
                Spacer()
            }

            Text("Switch to Default mode and implement the plan?")
                .macrodexFont(.caption)
                .foregroundColor(MacrodexTheme.textSecondary)

            HStack(spacing: 8) {
                Button {
                    onImplement()
                } label: {
                    Text("Implement")
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(MacrodexTheme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    onDismiss()
                } label: {
                    Text("Stay in Plan")
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(MacrodexTheme.surface.opacity(0.8))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(GlassRectModifier(cornerRadius: 14))
    }
}

struct QueuedFollowUpsPreviewView: View {
    let previews: [AppQueuedFollowUpPreview]
    let onSteer: (AppQueuedFollowUpPreview) -> Void
    let onDelete: (AppQueuedFollowUpPreview) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(MacrodexTheme.accent)
                Text("Queued Next")
                    .macrodexFont(.caption, weight: .semibold)
                    .foregroundColor(MacrodexTheme.textPrimary)
                Spacer()
                Text("\(previews.count)")
                    .macrodexFont(.caption2, weight: .semibold)
                    .foregroundColor(MacrodexTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MacrodexTheme.surface.opacity(0.9))
                    .clipShape(Capsule())
            }

            ForEach(previews, id: \.id) { preview in
                let style = QueuedFollowUpPreviewStyle.forKind(preview.kind)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: style.symbol)
                                .font(.system(size: 11, weight: .semibold))
                            Text(style.title)
                                .macrodexFont(.caption2, weight: .semibold)
                        }
                        .foregroundColor(style.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(style.tint.opacity(0.14))
                        .clipShape(Capsule())

                        Text(preview.text)
                            .macrodexFont(.caption)
                            .foregroundColor(MacrodexTheme.textSecondary)
                            .lineLimit(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if preview.kind == .message || preview.kind == .pendingSteer {
                        Button(action: { onSteer(preview) }) {
                            HStack(spacing: 6) {
                                if preview.kind == .pendingSteer {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Steering")
                                        .macrodexFont(.caption, weight: .semibold)
                                } else {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Steer")
                                        .macrodexFont(.caption, weight: .semibold)
                                }
                            }
                            .foregroundColor(preview.kind == .pendingSteer ? MacrodexTheme.accent : MacrodexTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(MacrodexTheme.surface.opacity(0.96))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(preview.kind == .pendingSteer)
                    }

                    Button(action: { onDelete(preview) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(MacrodexTheme.textSecondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(style.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(style.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(12)
        .background(MacrodexTheme.codeBackground.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct QueuedFollowUpPreviewStyle {
    let title: String
    let symbol: String
    let tint: Color
    let background: Color
    let border: Color

    static func forKind(_ kind: AppQueuedFollowUpKind) -> Self {
        switch kind {
        case .message:
            let tint = MacrodexTheme.accent
            return Self(
                title: "Queued message",
                symbol: "text.bubble.fill",
                tint: tint,
                background: tint.opacity(0.08),
                border: tint.opacity(0.24)
            )
        case .pendingSteer:
            let tint = MacrodexTheme.accentStrong
            return Self(
                title: "Steer queued",
                symbol: "arrowshape.turn.up.right.fill",
                tint: tint,
                background: tint.opacity(0.10),
                border: tint.opacity(0.28)
            )
        case .retryingSteer:
            let tint = MacrodexTheme.warning
            return Self(
                title: "Retrying steer",
                symbol: "arrow.clockwise",
                tint: tint,
                background: tint.opacity(0.10),
                border: tint.opacity(0.28)
            )
        }
    }
}

private struct ConversationLoadingIndicator: View {
    let label: String
    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        Text(label)
            .macrodexFont(.body, weight: .medium)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        MacrodexTheme.textSecondary.opacity(0.4),
                        MacrodexTheme.textSecondary.opacity(0.7),
                        MacrodexTheme.textSecondary.opacity(0.4),
                    ],
                    startPoint: UnitPoint(x: shimmerOffset - 0.3, y: 0.5),
                    endPoint: UnitPoint(x: shimmerOffset + 0.3, y: 0.5)
                )
            )
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: shimmerOffset)
            .onAppear {
                shimmerOffset = 2
            }
    }
}

struct TypingIndicator: View {
    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        Text("Thinking")
            .macrodexFont(.body, weight: .medium)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        MacrodexTheme.textSecondary.opacity(0.4),
                        MacrodexTheme.accent,
                        MacrodexTheme.textSecondary.opacity(0.4),
                    ],
                    startPoint: UnitPoint(x: shimmerOffset - 0.3, y: 0.5),
                    endPoint: UnitPoint(x: shimmerOffset + 0.3, y: 0.5)
                )
            )
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: shimmerOffset)
            .onAppear {
                shimmerOffset = 2
            }
    }
}

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct SubagentBreadcrumbBar: View {
    let thread: AppThreadSnapshot
    let topInset: CGFloat
    let onNavigateToParent: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onNavigateToParent) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .macrodexFont(size: 10, weight: .semibold)
                    Text("Parent")
                        .macrodexFont(.caption, weight: .medium)
                }
                .foregroundColor(MacrodexTheme.accent)
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 14)
                .background(MacrodexTheme.border)

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .macrodexFont(size: 10, weight: .semibold)
                    .foregroundColor(MacrodexTheme.success)
                Text(thread.agentDisplayLabel ?? "Agent")
                    .macrodexFont(.caption, weight: .medium)
                    .foregroundColor(MacrodexTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .padding(.top, topInset + 8)
        .background(
            MacrodexTheme.surface.opacity(0.85)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
        )
    }
}

// MARK: - Debug Overlay

#if DEBUG
#Preview("Conversation") {
    MacrodexPreviewScene(appModel: MacrodexPreviewData.makeConversationAppModel(messages: MacrodexPreviewData.longConversation)) {
        ContentView()
    }
}
#endif
