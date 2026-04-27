import SwiftUI
import os

private let sessionsScreenSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.dj.Macrodex",
    category: "SessionsScreen"
)

struct SessionsScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(ConversationWarmupCoordinator.self) private var conversationWarmup

    @AppStorage("workDir") private var workDir =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    @State private var sessionsModel = SessionsModel()
    @State private var isLoading: Bool
    @State private var resumingKey: ThreadKey?
    @State private var isStartingNewSession = false
    @State private var sessionActionErrorMessage: String?
    @State private var hasLoadedInitialSessions = false

    private let autoLoadSessions: Bool
    private let onOpenConversation: (ThreadKey) -> Void
    private let onNewChatDraft: (() -> Void)?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    init(
        autoLoadSessions: Bool = true,
        onOpenConversation: @escaping (ThreadKey) -> Void,
        onNewChatDraft: (() -> Void)? = nil
    ) {
        self.autoLoadSessions = autoLoadSessions
        self.onOpenConversation = onOpenConversation
        self.onNewChatDraft = onNewChatDraft
        _isLoading = State(initialValue: autoLoadSessions)
    }

    var body: some View {
        content
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: handleNewSessionTap) {
                        if isStartingNewSession {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .disabled(isStartingNewSession)
                    .accessibilityIdentifier("sessions.newSessionButton")
                }
            }
            .task {
                sessionsModel.bind(appModel: appModel, appState: appState)
                await loadSessionsIfNeeded()
            }
            .onChange(of: connectedServerIds) { _, ids in
                guard autoLoadSessions, !ids.isEmpty else { return }
                Task { await loadSessions(force: true) }
            }
            .alert("Chat Action Failed", isPresented: Binding(
                get: { sessionActionErrorMessage != nil },
                set: { if !$0 { sessionActionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {
                    sessionActionErrorMessage = nil
                }
            } message: {
                Text(sessionActionErrorMessage ?? "Unknown error")
            }
    }

    @ViewBuilder
    private var content: some View {
        if sessions.isEmpty {
            Group {
                if isLoading {
                    ProgressView("Loading Chats…")
                } else {
                    ContentUnavailableView(
                        "No Chats",
                        systemImage: "text.bubble",
                        description: Text("Tap + to start a new chat on this iPhone.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        } else {
            List {
                ForEach(sessions) { thread in
                    sessionRow(thread)
                }
            }
            .listStyle(.plain)
            .overlay(alignment: .top) {
                if isLoading && hasLoadedInitialSessions {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var sessions: [AppSessionSummary] {
        sessionsModel.derivedData.allThreads
    }

    private var connectedServers: [HomeDashboardServer] {
        sessionsModel.connectedServers
    }

    private var connectedServerIds: [String] {
        connectedServers.map(\.id)
    }

    private var localServerId: String? {
        connectedServers.first(where: \.isLocal)?.id ?? connectedServers.first?.id
    }

    private var activeThreadKey: ThreadKey? {
        sessionsModel.activeThreadKey
    }

    private var ephemeralStateByThreadKey: [ThreadKey: SessionsModel.ThreadEphemeralState] {
        sessionsModel.ephemeralStateByThreadKey
    }

    private func sessionRow(_ thread: AppSessionSummary) -> some View {
        let ephemeralState = ephemeralStateByThreadKey[thread.key]
        let updatedAt = ephemeralState?.updatedAt ?? thread.updatedAtDate
        let isRunning = ephemeralState?.hasTurnActive ?? thread.hasActiveTurn
        let isActive = activeThreadKey == thread.key

        return Button {
            Task { await resumeSession(thread) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                sessionStatusIcon(isRunning: isRunning, isActive: isActive)

                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.sessionTitle)
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(relativeDate(updatedAt))
                        if thread.isFork {
                            Text("Fork")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if resumingKey == thread.key {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sessions.sessionRow")
    }

    @ViewBuilder
    private func sessionStatusIcon(isRunning: Bool, isActive: Bool) -> some View {
        if isRunning {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 20, height: 20)
        } else if isActive {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
    }

    private func handleNewSessionTap() {
        if let onNewChatDraft {
            onNewChatDraft()
            return
        }
        guard let serverId = localServerId else {
            Task {
                await appModel.ensureLocalServerConnected()
                guard let serverId = localServerId else {
                    sessionActionErrorMessage = "Local chat server is not available yet."
                    return
                }
                let cwd = await AgentRuntimeBootstrap.defaultCwd()
                await startNewSession(serverId: serverId, cwd: cwd)
            }
            return
        }
        Task {
            let cwd = await AgentRuntimeBootstrap.defaultCwd()
            await startNewSession(serverId: serverId, cwd: cwd)
        }
    }

    private func loadSessionsIfNeeded() async {
        guard autoLoadSessions, !hasLoadedInitialSessions else { return }
        await loadSessions(force: false)
    }

    private func loadSessions(force: Bool) async {
        guard force || !hasLoadedInitialSessions else { return }

        let signpostID = OSSignpostID(log: sessionsScreenSignpostLog)
        os_signpost(.begin, log: sessionsScreenSignpostLog, name: "LoadSessions", signpostID: signpostID)
        defer {
            os_signpost(.end, log: sessionsScreenSignpostLog, name: "LoadSessions", signpostID: signpostID)
        }

        guard !connectedServerIds.isEmpty else {
            isLoading = false
            return
        }

        isLoading = true
        for serverId in connectedServerIds {
            _ = try? await appModel.client.listThreads(
                serverId: serverId,
                params: AppListThreadsRequest(
                    cursor: nil,
                    limit: nil,
                    archived: nil,
                    cwd: nil,
                    searchTerm: nil
                )
            )
            await appModel.loadConversationMetadataIfNeeded(serverId: serverId)
        }
        await appModel.refreshSnapshot()

        hasLoadedInitialSessions = true
        isLoading = false
    }

    private func resumeSession(_ thread: AppSessionSummary) async {
        guard resumingKey == nil else { return }
        resumingKey = thread.key
        sessionActionErrorMessage = nil
        defer { resumingKey = nil }

        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        onOpenConversation(thread.key)

        do {
            await conversationWarmup.prewarmIfNeeded()
            await appModel.loadConversationMetadataIfNeeded(serverId: thread.key.serverId)
            let resumeKey = await appModel.hydrateThreadPermissions(for: thread.key, appState: appState) ?? thread.key
            let nextKey = try await appModel.resumeThread(
                key: resumeKey,
                launchConfig: launchConfig(for: resumeKey),
                cwdOverride: thread.cwd
            )
            if !thread.cwd.isEmpty {
                RecentDirectoryStore.shared.record(path: thread.cwd, for: thread.key.serverId)
            }
            appModel.activateThread(nextKey)
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
    }

    private func startNewSession(serverId: String, cwd: String) async {
        guard !isStartingNewSession else { return }
        isStartingNewSession = true
        sessionActionErrorMessage = nil
        defer { isStartingNewSession = false }

        await conversationWarmup.prewarmIfNeeded()
        await appModel.loadConversationMetadataIfNeeded(serverId: serverId)

        workDir = cwd
        appState.currentCwd = cwd

        do {
            let startedKey = try await appModel.client.startThread(
                serverId: serverId,
                params: launchConfig(forServerID: serverId).threadStartRequest(
                    cwd: cwd,
                    dynamicTools: AgentDynamicToolSpecs.defaultThreadTools(
                        includeGenerativeUI: false
                    )
                )
            )
            RecentDirectoryStore.shared.record(path: cwd, for: serverId)
            appState.requestComposerAutofocus(for: startedKey)
            appModel.store.setActiveThread(key: startedKey)
            await appModel.refreshSnapshot()
            let resolvedKey = appModel.snapshot?.threadSnapshot(for: startedKey)?.key ?? startedKey
            appState.requestComposerAutofocus(for: resolvedKey)
            onOpenConversation(resolvedKey)
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
    }

    private func launchConfig(for threadKey: ThreadKey? = nil) -> AppThreadLaunchConfig {
        AppThreadLaunchConfig(
            model: selectedModelOverride(for: threadKey?.serverId),
            approvalPolicy: appState.launchApprovalPolicy(for: nil),
            sandbox: appState.launchSandboxMode(for: nil),
            developerInstructions: AgentRuntimeInstructions.developerInstructions(for: threadKey),
            persistExtendedHistory: true
        )
    }

    private func launchConfig(forServerID serverId: String?) -> AppThreadLaunchConfig {
        AppThreadLaunchConfig(
            model: selectedModelOverride(for: serverId),
            approvalPolicy: appState.launchApprovalPolicy(for: nil),
            sandbox: appState.launchSandboxMode(for: nil),
            developerInstructions: AgentRuntimeInstructions.developerInstructions(),
            persistExtendedHistory: true
        )
    }

    private func selectedModelOverride(for serverId: String?) -> String? {
        let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty { return pending }
        return serverId.flatMap { appModel.preferredDefaultModelID(for: $0) }
    }

    private func relativeDate(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

#if DEBUG
#Preview("Chats Screen") {
    MacrodexPreviewScene(
        appModel: MacrodexPreviewData.makeSidebarAppModel(),
        appState: MacrodexPreviewData.makeAppState()
    ) {
        NavigationStack {
            SessionsScreen(autoLoadSessions: false, onOpenConversation: { _ in })
        }
    }
}
#endif
