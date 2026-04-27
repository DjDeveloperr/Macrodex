import SwiftUI
import UIKit

enum DrawerPrimaryItem: String, Hashable {
    case dashboard
    case library
    case settings
}

enum DrawerContentSelection: Hashable {
    case primary(DrawerPrimaryItem)
    case thread(ThreadKey)
}

private enum DrawerTone {
    static let accent = Color(red: 0.302, green: 0.639, blue: 1.0)
    static let background = Color(uiColor: .systemBackground)
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    static let rowFill = adaptive(light: "#F2F2F7", dark: "#121214")
    static let selectedFill = accent.opacity(0.14)
    static let iconFill = accent.opacity(0.14)
    static let iconNeutralFill = adaptive(light: "#E8E8ED", dark: "#1C1C1E")

    private static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

struct NavigationDrawerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(ConversationWarmupCoordinator.self) private var conversationWarmup
    @Environment(DrawerController.self) private var drawerController

    @AppStorage("workDir") private var workDir =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @AppStorage("autoArchiveChatsAfter14Days") private var legacyAutoArchiveChatsAfter14Days = true
    @AppStorage("autoArchiveChatsAfterDays") private var storedAutoArchiveChatsAfterDays = 14

    @State private var sessionsModel = SessionsModel()
    @State private var isLoading = true
    @State private var visibleRecentSessionCount = 10
    @State private var isAutoArchivingExpiredSessions = false
    @State private var resumingKey: ThreadKey?
    @State private var archivingKey: ThreadKey?
    @State private var renamingKey: ThreadKey?
    @State private var renameTarget: AppSessionSummary?
    @State private var renameText = ""
    @State private var renamedTitlesByKey: [ThreadKey: String] = [:]
    @State private var pinnedKeys: [SavedThreadsStore.PinnedKey] = SavedThreadsStore.pinnedKeys()
    @State private var isStartingNewSession = false
    @State private var actionErrorMessage: String?

    var bottomSafeAreaInset: CGFloat = 0
    let selection: DrawerContentSelection
    let onShowDashboard: () -> Void
    let onShowLibrary: () -> Void
    let onShowSettings: () -> Void
    let onOpenNewChatDraft: () -> Void
    let onOpenConversation: (ThreadKey) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    drawerHeader
                    sessionsSection
                }
                .padding(.bottom, 112 + bottomSafeAreaInset)
            }
            .scrollIndicators(.hidden)

            drawerFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DrawerTone.background)
        .task {
            sessionsModel.bind(appModel: appModel, appState: appState)
            await loadSessionsIfNeeded()
        }
        .onChange(of: connectedServerIds) { _, ids in
            guard !ids.isEmpty else { return }
            Task { await loadSessions(force: true) }
        }
        .onChange(of: recentSessions.map(\.key)) { _, _ in
            visibleRecentSessionCount = 10
        }
        .alert("Drawer Action Failed", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                actionErrorMessage = nil
            }
        } message: {
            Text(actionErrorMessage ?? "Unknown error")
        }
        .alert("Rename Chat", isPresented: renamePromptBinding) {
            TextField("Chat name", text: $renameText)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
                renameText = ""
            }
            Button("Rename") {
                guard let target = renameTarget else { return }
                let draftName = renameText
                Task { await renameSession(target, name: draftName) }
            }
        } message: {
            Text("Enter a new name for this chat.")
        }
    }

    private var drawerHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            drawerNavButton(
                title: "Dashboard",
                subtitle: "Calories, meals, progress",
                systemImage: "house.fill",
                isSelected: selection == .primary(.dashboard),
                action: onShowDashboard
            )
            drawerNavButton(
                title: "Library",
                subtitle: "Foods, recipes, templates",
                systemImage: "books.vertical.fill",
                isSelected: selection == .primary(.library),
                action: onShowLibrary
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    private func drawerNavButton(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let performAction = {
            AppHaptics.light()
            action()
            drawerController.close()
        }

        return HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? DrawerTone.accent : DrawerTone.textPrimary)
                .frame(width: 34, height: 34)
                .background(isSelected ? DrawerTone.iconFill : DrawerTone.iconNeutralFill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(isSelected ? DrawerTone.accent : DrawerTone.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(DrawerTone.textSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? DrawerTone.selectedFill : DrawerTone.rowFill)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: performAction)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Opens \(title)")
        .accessibilityAddTraits(.isButton)
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chats")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(DrawerTone.textPrimary)
                Spacer()
                Button(action: handleNewSessionTap) {
                    if isStartingNewSession {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(DrawerTone.textPrimary)
                .frame(width: 28, height: 28)
                .accessibilityLabel("New chat")
            }
            .padding(.horizontal, 16)

            if isLoading && sessions.isEmpty {
                ProgressView("Loading chats…")
                    .font(.subheadline)
                    .tint(DrawerTone.accent)
                    .foregroundStyle(DrawerTone.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            } else if sessions.isEmpty {
                Text("No chats yet")
                    .font(.subheadline)
                    .foregroundStyle(DrawerTone.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !pinnedSessions.isEmpty {
                        drawerSubheader("Pinned")
                        ForEach(pinnedSessions) { thread in
                            sessionRow(thread)
                        }
                        if !recentSessions.isEmpty {
                            drawerSubheader("Recent")
                                .padding(.top, 8)
                        }
                    }
                    ForEach(visibleRecentSessions) { thread in
                        sessionRow(thread)
                    }
                    if visibleRecentSessions.count < recentSessions.count {
                        loadMoreChatsTrigger
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var drawerFooter: some View {
        let isSettingsSelected = selection == .primary(.settings)
        let foreground = isSettingsSelected ? DrawerTone.accent : DrawerTone.textPrimary
        let iconFill = isSettingsSelected ? DrawerTone.iconFill : DrawerTone.iconNeutralFill
        let rowFill = DrawerTone.rowFill

        Button {
            AppHaptics.light()
            onShowSettings()
            drawerController.close()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 34, height: 34)
                    .background(iconFill, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(foreground)
                    Text("Account, limits, logout")
                        .font(.caption)
                        .foregroundStyle(DrawerTone.textSecondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(rowFill)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings, Account, limits, logout")
        .accessibilityValue(isSettingsSelected ? "Selected" : "")
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12 + bottomSafeAreaInset)
        .background(alignment: .top) {
            DrawerFooterProgressiveBackdrop()
                .frame(height: 116 + bottomSafeAreaInset)
                .offset(y: -28)
                .allowsHitTesting(false)
        }
    }

    private struct DrawerFooterProgressiveBackdrop: View {
        var body: some View {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.78)
                    .mask(progressiveMask)

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.10), location: 0.30),
                        .init(color: .black.opacity(0.22), location: 0.68),
                        .init(color: .black.opacity(0.30), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }

        private var progressiveMask: some View {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.24), location: 0.18),
                    .init(color: .black.opacity(0.78), location: 0.58),
                    .init(color: .black, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var sessions: [AppSessionSummary] {
        sessionsModel.derivedData.allThreads
    }

    private var pinnedSessions: [AppSessionSummary] {
        let byPin = Dictionary(uniqueKeysWithValues: sessions.map { (SavedThreadsStore.PinnedKey(threadKey: $0.key), $0) })
        return pinnedKeys.compactMap { byPin[$0] }
    }

    private var recentSessions: [AppSessionSummary] {
        let pinned = Set(pinnedKeys)
        return sessions.filter { !pinned.contains(SavedThreadsStore.PinnedKey(threadKey: $0.key)) }
    }

    private var visibleRecentSessions: ArraySlice<AppSessionSummary> {
        recentSessions.prefix(visibleRecentSessionCount)
    }

    private var loadMoreChatsTrigger: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(DrawerTone.accent)
            Text("Loading more chats")
                .font(.caption)
                .foregroundStyle(DrawerTone.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 10)
        .onAppear {
            loadMoreRecentSessions()
        }
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

    private var renamePromptBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { isPresented in
                if !isPresented {
                    renameTarget = nil
                    renameText = ""
                }
            }
        )
    }

    private var ephemeralStateByThreadKey: [ThreadKey: SessionsModel.ThreadEphemeralState] {
        sessionsModel.ephemeralStateByThreadKey
    }

    private func sessionRow(_ thread: AppSessionSummary) -> some View {
        let ephemeralState = ephemeralStateByThreadKey[thread.key]
        let updatedAt = ephemeralState?.updatedAt ?? thread.updatedAtDate
        let isActive = selection == .thread(thread.key)
        let title = sessionTitle(for: thread)
        let isPinned = pinnedKeys.contains(SavedThreadsStore.PinnedKey(threadKey: thread.key))

        return Button {
            AppHaptics.light()
            Task { await resumeSession(thread) }
            drawerController.close()
        } label: {
            HStack(spacing: 10) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DrawerTone.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isActive ? DrawerTone.accent : DrawerTone.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(relativeDate(updatedAt))
                        .font(.caption)
                        .foregroundStyle(DrawerTone.textSecondary)
                }

                Spacer(minLength: 12)
                if resumingKey == thread.key || archivingKey == thread.key || renamingKey == thread.key {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DrawerTone.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? DrawerTone.selectedFill : DrawerTone.rowFill)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sessionAccessibilityLabel(title: title, updatedAt: updatedAt, isPinned: isPinned))
        .accessibilityValue(isActive ? "Selected" : "")
        .accessibilityHint("Opens chat")
        .contextMenu {
            Button {
                Task { await resumeSession(thread) }
            } label: {
                Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
            }

            Button {
                togglePinned(thread)
            } label: {
                Label(isPinned ? "Unpin Chat" : "Pin Chat", systemImage: isPinned ? "pin.slash" : "pin")
            }

            Button {
                renameTarget = thread
                renameText = title
            } label: {
                Label("Rename Chat", systemImage: "pencil")
            }

            Button(role: .destructive) {
                Task { await archiveSession(thread) }
            } label: {
                Label("Archive Chat", systemImage: "archivebox")
            }
        }
    }

    private func drawerSubheader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(DrawerTone.textTertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
    }

    private func sessionAccessibilityLabel(title: String, updatedAt: Date, isPinned: Bool) -> String {
        let pinPrefix = isPinned ? "Pinned chat, " : "Chat, "
        return "\(pinPrefix)\(title), updated \(relativeDate(updatedAt))"
    }

    private func togglePinned(_ thread: AppSessionSummary) {
        AppHaptics.light()
        let pin = SavedThreadsStore.PinnedKey(threadKey: thread.key)
        if pinnedKeys.contains(pin) {
            SavedThreadsStore.remove(pin)
        } else {
            SavedThreadsStore.add(pin)
        }
        pinnedKeys = SavedThreadsStore.pinnedKeys()
    }

    private func renameSession(_ thread: AppSessionSummary, name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard renamingKey == nil else { return }

        renamingKey = thread.key
        defer { renamingKey = nil }

        do {
            try await appModel.client.renameThread(
                serverId: thread.key.serverId,
                params: AppRenameThreadRequest(threadId: thread.key.threadId, name: trimmedName)
            )
            ManualThreadTitleStore.markManuallyRenamed(thread.key)
            renamedTitlesByKey[thread.key] = trimmedName
            renameTarget = nil
            renameText = ""
            await appModel.refreshSnapshot()
            await loadSessions(force: true)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func sessionTitle(for thread: AppSessionSummary) -> String {
        renamedTitlesByKey[thread.key] ?? thread.sessionTitle
    }

    private func loadSessionsIfNeeded() async {
        await loadSessions(force: false)
    }

    private func loadSessions(force: Bool) async {
        guard force || sessions.isEmpty else {
            isLoading = false
            return
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
        await autoArchiveExpiredSessionsIfNeeded()
        isLoading = false
    }

    private func autoArchiveExpiredSessionsIfNeeded() async {
        guard !isAutoArchivingExpiredSessions else { return }
        let archiveAfterDays = effectiveAutoArchiveChatsAfterDays
        guard archiveAfterDays > 0 else { return }
        guard let snapshot = appModel.snapshot else { return }

        let connectedIds = Set(connectedServerIds)
        let cutoff = Date().addingTimeInterval(-TimeInterval(archiveAfterDays) * 24 * 60 * 60)
        let pins = Set(SavedThreadsStore.pinnedKeys())
        let expiredThreads = snapshot.sessionSummaries.filter { thread in
            guard let updatedAt = thread.updatedAt else { return false }
            return connectedIds.contains(thread.key.serverId)
                && Date(timeIntervalSince1970: TimeInterval(updatedAt)) < cutoff
                && !pins.contains(SavedThreadsStore.PinnedKey(threadKey: thread.key))
        }

        guard !expiredThreads.isEmpty else { return }

        isAutoArchivingExpiredSessions = true
        defer { isAutoArchivingExpiredSessions = false }

        do {
            for thread in expiredThreads {
                try await appModel.client.archiveThread(
                    serverId: thread.key.serverId,
                    params: AppArchiveThreadRequest(threadId: thread.key.threadId)
                )
            }
            await appModel.refreshSnapshot()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private var effectiveAutoArchiveChatsAfterDays: Int {
        if storedAutoArchiveChatsAfterDays <= 0 {
            return legacyAutoArchiveChatsAfter14Days ? 14 : 0
        }
        return storedAutoArchiveChatsAfterDays
    }

    private func loadMoreRecentSessions() {
        guard visibleRecentSessionCount < recentSessions.count else { return }
        visibleRecentSessionCount = min(visibleRecentSessionCount + 10, recentSessions.count)
    }

    private func resumeSession(_ thread: AppSessionSummary) async {
        guard resumingKey == nil else { return }
        resumingKey = thread.key
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
            actionErrorMessage = error.localizedDescription
        }
    }

    private func archiveSession(_ thread: AppSessionSummary) async {
        guard archivingKey == nil else { return }
        archivingKey = thread.key
        defer { archivingKey = nil }

        do {
            try await appModel.client.archiveThread(
                serverId: thread.key.serverId,
                params: AppArchiveThreadRequest(threadId: thread.key.threadId)
            )
            if activeThreadKey == thread.key {
                appModel.activateThread(nil)
                onShowDashboard()
                drawerController.close()
            }
            await appModel.refreshSnapshot()
            await loadSessions(force: true)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func handleNewSessionTap() {
        guard let serverId = localServerId else {
            Task {
                await appModel.ensureLocalServerConnected()
                guard localServerId != nil else {
                    actionErrorMessage = "Local chat server is not available yet."
                    return
                }
                openNewChatDraft()
            }
            return
        }
        _ = serverId
        openNewChatDraft()
    }

    private func openNewChatDraft() {
        AppHaptics.light()
        onOpenNewChatDraft()
        drawerController.close()
    }

    private func startNewSession(serverId: String, cwd: String) async {
        guard !isStartingNewSession else { return }
        isStartingNewSession = true
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
            drawerController.close()
        } catch {
            actionErrorMessage = error.localizedDescription
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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
