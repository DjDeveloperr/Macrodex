import SwiftUI
import UIKit

enum DrawerPrimaryItem: String, Hashable {
    case dashboard
    case insights
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
    static let selectedFill = adaptive(light: "#EDEDEF", dark: "#202123")

    private static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private enum DrawerLayout {
    static let chromeHorizontalPadding: CGFloat = 16
    static let contentLeadingAnchor: CGFloat = 24
    static let rowInnerHorizontalPadding: CGFloat = contentLeadingAnchor - chromeHorizontalPadding
    static let chatListHorizontalPadding: CGFloat = 12
    static let chatRowInnerHorizontalPadding: CGFloat = contentLeadingAnchor - chatListHorizontalPadding
    static let selectedRowHorizontalBleed: CGFloat = 8
}

private struct DrawerTopChromeHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#if DEBUG
private enum NavigationDrawerDebugSamples {
    static let serverId = "debug-drawer"
    static let serverName = "Macrodex Preview"
    static let cwd = "/Users/dj/Developer/Macrodex"

    static var sessions: [AppSessionSummary] {
        [
            makeSession(title: "Breakfast protein plan", threadId: "breakfast-protein", minutesAgo: 8),
            makeSession(title: "Honeydew melon nutrition", threadId: "honeydew-melon", minutesAgo: 24),
            makeSession(title: "Chicken rice macros", threadId: "chicken-rice", minutesAgo: 48),
            makeSession(title: "Greek yogurt snack ideas", threadId: "greek-yogurt", minutesAgo: 93),
            makeSession(title: "Weekly meal prep totals", threadId: "meal-prep-totals", minutesAgo: 180),
            makeSession(title: "Post workout dinner", threadId: "post-workout-dinner", minutesAgo: 360),
            makeSession(title: "Morning coffee calories", threadId: "morning-coffee", minutesAgo: 480),
            makeSession(title: "Late snack cleanup", threadId: "late-snack", minutesAgo: 620),
            makeSession(title: "Protein target adjustment", threadId: "protein-target", minutesAgo: 760),
            makeSession(title: "Sushi dinner estimate", threadId: "sushi-dinner", minutesAgo: 920),
            makeSession(title: "Apple Health reconcile", threadId: "health-reconcile", minutesAgo: 1_120),
            makeSession(title: "Library duplicate foods", threadId: "library-duplicates", minutesAgo: 1_360)
        ]
    }

    private static func makeSession(title: String, threadId: String, minutesAgo: TimeInterval) -> AppSessionSummary {
        AppSessionSummary(
            key: ThreadKey(serverId: serverId, threadId: threadId),
            serverDisplayName: serverName,
            serverHost: "127.0.0.1",
            title: title,
            preview: title,
            cwd: cwd,
            model: "gpt-5.4",
            modelProvider: "OpenAI",
            parentThreadId: nil,
            agentNickname: nil,
            agentRole: nil,
            agentDisplayLabel: nil,
            agentStatus: .unknown,
            updatedAt: Int64(Date().addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970),
            hasActiveTurn: false,
            isSubagent: false,
            isFork: false,
            lastResponsePreview: nil,
            lastResponseTurnId: nil,
            lastUserMessage: nil,
            lastToolLabel: nil,
            recentToolLog: [],
            lastTurnStartMs: nil,
            lastTurnEndMs: nil,
            stats: nil,
            tokenUsage: nil
        )
    }
}
#endif

struct NavigationDrawerView: View {
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var drawerTopChromeHeight: CGFloat = 0
    @State private var isSearchActive = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchDismissPending = false
    @State private var drawerKeyboardOverlap: CGFloat = 0
    @State private var drawerScrollDistance: CGFloat = 0
    @FocusState private var isSearchFieldFocused: Bool

    var topSafeAreaInset: CGFloat = 0
    var bottomSafeAreaInset: CGFloat = 0
    let selection: DrawerContentSelection
    let onShowDashboard: () -> Void
    let onShowInsights: () -> Void
    let onShowLibrary: () -> Void
    let onShowSettings: () -> Void
    let onOpenNewChatDraft: () -> Void
    let onOpenConversation: (ThreadKey) -> Void

    var body: some View {
        ScrollView {
            Group {
                if isSearchActive {
                    drawerSearchResultsContent
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    drawerScrollableContent
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, max(drawerTopChromeHeight + 4, topSafeAreaInset + 76))
            .padding(.bottom, drawerScrollBottomPadding)
        }
        .id(isSearchActive ? "drawer-search" : "drawer-normal")
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
        } action: { _, distance in
            updateDrawerScrollDistance(distance)
        }
        .mask(alignment: .top) {
            drawerScrollContentMask
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            drawerBottomChrome
        }
        .overlay(alignment: .top) {
            drawerTopChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DrawerTone.background)
        .onPreferenceChange(DrawerTopChromeHeightPreferenceKey.self) { height in
            drawerTopChromeHeight = height
        }
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
        .onChange(of: searchText) { _, query in
            scheduleSearchDebounce(for: query)
        }
        .onChange(of: drawerController.isOpen) { _, isOpen in
            if !isOpen {
                resetSearch(immediate: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            updateDrawerKeyboardOverlap(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateDrawerKeyboardOverlap(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            handleDrawerKeyboardWillHide(notification)
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

    private var drawerScrollBottomPadding: CGFloat {
        isSearchActive ? 14 : 18
    }

    private var drawerScrollContentMask: some View {
        let progress = drawerHeaderBackdropProgress
        return GeometryReader { proxy in
            let headerHeight = min(max(topSafeAreaInset + 72, 86), proxy.size.height)
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(1 - progress), location: 0),
                        .init(color: .black.opacity(1 - progress * 0.92), location: 0.58),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: headerHeight)

                Color.black
                    .frame(height: max(proxy.size.height - headerHeight, 0))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private var drawerScrollableContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            drawerHeaderButtons
                .padding(.horizontal, DrawerLayout.chromeHorizontalPadding)
            sessionsSection
        }
    }

    private var drawerTopChrome: some View {
        ZStack(alignment: .topLeading) {
            DrawerTopSoftBlurBackdrop(
                progress: drawerHeaderBackdropProgress,
                colorScheme: colorScheme
            )
            .frame(height: max(topSafeAreaInset + 72, 86))
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                drawerBrandHeader
            }
            .padding(.horizontal, DrawerLayout.chromeHorizontalPadding)
            .padding(.top, topSafeAreaInset + 10)
            .padding(.bottom, 12)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DrawerTopChromeHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var drawerBrandHeader: some View {
        HStack(spacing: 14) {
            Text("Macrodex")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(DrawerTone.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 12)
            drawerSearchButton
        }
        .padding(.horizontal, DrawerLayout.rowInnerHorizontalPadding)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var drawerSearchButton: some View {
        Button {
            if isSearchActive {
                resetSearch(immediate: false)
            } else {
                activateSearch()
            }
        } label: {
            Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(DrawerTone.textPrimary)
                .frame(width: 48, height: 48)
                .modifier(GlassCircleModifier(interactive: true))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityIdentifier("drawer.search")
        .accessibilityLabel(isSearchActive ? "Close search" : "Search chats")
    }

    private var drawerHeaderButtons: some View {
        drawerHeaderButtonStack
    }

    private var drawerHeaderButtonStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            drawerNavButton(
                title: "Dashboard",
                systemImage: "house",
                isSelected: selection == .primary(.dashboard),
                action: onShowDashboard
            )
            drawerNavButton(
                title: "Insights",
                systemImage: "chart.xyaxis.line",
                isSelected: selection == .primary(.insights),
                action: onShowInsights
            )
            drawerNavButton(
                title: "Library",
                systemImage: "books.vertical",
                isSelected: selection == .primary(.library),
                action: onShowLibrary
            )
        }
    }

    private func drawerNavButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let performAction = {
            AppHaptics.light()
            action()
            drawerController.close()
        }

        return Button(action: performAction) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(DrawerTone.textPrimary)
                    .frame(width: 30, height: 34, alignment: .leading)
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(DrawerTone.textPrimary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DrawerLayout.rowInnerHorizontalPadding)
            .frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? DrawerTone.selectedFill : Color.clear)
                    .padding(.horizontal, -DrawerLayout.selectedRowHorizontalBleed)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Opens \(title)")
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chats")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DrawerTone.textSecondary)
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
            .padding(.horizontal, DrawerLayout.contentLeadingAnchor)

            if isLoading && sessions.isEmpty {
                ProgressView("Loading chats…")
                    .font(.subheadline)
                    .tint(DrawerTone.accent)
                    .foregroundStyle(DrawerTone.textSecondary)
                    .padding(.horizontal, DrawerLayout.contentLeadingAnchor)
                    .padding(.top, 8)
            } else if sessions.isEmpty {
                Text("No chats yet")
                    .font(.subheadline)
                    .foregroundStyle(DrawerTone.textSecondary)
                    .padding(.horizontal, DrawerLayout.contentLeadingAnchor)
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
                .padding(.horizontal, DrawerLayout.chatListHorizontalPadding)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var drawerSearchResultsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading && sessions.isEmpty {
                ProgressView("Loading chats...")
                    .font(.subheadline)
                    .tint(DrawerTone.accent)
                    .foregroundStyle(DrawerTone.textSecondary)
                    .padding(.horizontal, DrawerLayout.contentLeadingAnchor)
                    .padding(.top, 8)
            } else if visibleSearchSessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No chats yet" : "No results")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(DrawerTone.textPrimary)
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Try another chat title or keyword.")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(DrawerTone.textSecondary)
                    }
                }
                .padding(.horizontal, DrawerLayout.contentLeadingAnchor)
                .padding(.top, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleSearchSessions) { thread in
                        sessionRow(thread)
                    }
                }
                .padding(.horizontal, DrawerLayout.chatListHorizontalPadding)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var drawerBottomChrome: some View {
        if isSearchActive {
            drawerSearchInputBar
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            drawerFooter
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var drawerSearchInputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(DrawerTone.textSecondary)

            TextField("Search chats", text: $searchText)
                .focused($isSearchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(DrawerTone.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    debouncedSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(DrawerTone.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 16)
        .modifier(GlassCapsuleModifier(interactive: true))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, searchInputBottomPadding)
        .background(alignment: .top) {
            DrawerFooterProgressiveBackdrop()
                .frame(height: 104 + searchInputBottomPadding)
                .offset(y: -28)
                .allowsHitTesting(false)
        }
    }

    private var searchInputBottomPadding: CGFloat {
        if isSearchFieldFocused || drawerKeyboardOverlap > 0 {
            return drawerKeyboardOverlap + 8
        }
        return 12 + bottomSafeAreaInset
    }

    @ViewBuilder
    private var drawerFooter: some View {
        let isSettingsSelected = selection == .primary(.settings)
        let foreground = isSettingsSelected ? DrawerTone.accent : DrawerTone.textPrimary

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
                    .modifier(GlassCircleModifier())
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
            .modifier(GlassRoundedRectModifier(cornerRadius: 24, interactive: true))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.18), location: 0.22),
                    .init(color: .black.opacity(0.66), location: 0.68),
                    .init(color: .black.opacity(0.94), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private struct DrawerTopSoftBlurBackdrop: View {
        let progress: CGFloat
        let colorScheme: ColorScheme

        var body: some View {
            let progress = min(max(progress, 0), 1)
            DrawerTransparentBlur(style: colorScheme == .dark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight)
                .opacity(Double(progress) * 0.34)
                .mask(progressiveMask)
        }

        private var progressiveMask: some View {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.58),
                    .init(color: .black.opacity(0.22), location: 0.86),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private struct DrawerTransparentBlur: UIViewRepresentable {
        let style: UIBlurEffect.Style

        func makeUIView(context: Context) -> UIVisualEffectView {
            let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            return view
        }

        func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
            uiView.effect = UIBlurEffect(style: style)
        }
    }

    private var sessions: [AppSessionSummary] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MACRODEX_DEBUG_DRAWER_SAMPLE_CHATS"] == "1" {
            return NavigationDrawerDebugSamples.sessions
        }
        #endif

        return sessionsModel.derivedData.allThreads
    }

    private var visibleSearchSessions: [AppSessionSummary] {
        let trimmedQuery = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [AppSessionSummary]
        if trimmedQuery.isEmpty {
            filtered = sessions
        } else {
            filtered = sessions.filter { sessionMatchesSearch($0, query: trimmedQuery) }
        }
        return Array(filtered.prefix(80))
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
            openSessionImmediately(thread)
            drawerController.close()
            Task { await resumeSession(thread, openedImmediately: true) }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(DrawerTone.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 10)
                if resumingKey == thread.key || archivingKey == thread.key || renamingKey == thread.key {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DrawerTone.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DrawerLayout.chatRowInnerHorizontalPadding)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? DrawerTone.selectedFill : Color.clear)
                    .padding(.horizontal, -DrawerLayout.selectedRowHorizontalBleed)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.horizontal, DrawerLayout.chatRowInnerHorizontalPadding)
            .padding(.bottom, 2)
    }

    private func sessionAccessibilityLabel(title: String, updatedAt: Date, isPinned: Bool) -> String {
        let pinPrefix = isPinned ? "Pinned chat, " : "Chat, "
        return "\(pinPrefix)\(title), updated \(relativeDate(updatedAt))"
    }

    private func activateSearch() {
        AppHaptics.light()
        searchDismissPending = false
        withAnimation(.easeOut(duration: 0.16)) {
            isSearchActive = true
        }
        debouncedSearchText = searchText
        Task { @MainActor in
            await Task.yield()
            guard isSearchActive else { return }
            isSearchFieldFocused = true
        }
    }

    private func resetSearch(immediate: Bool) {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        isSearchFieldFocused = false
        searchText = ""
        debouncedSearchText = ""

        let update = {
            isSearchActive = false
            searchDismissPending = false
            setDrawerKeyboardOverlap(0, notification: nil)
        }

        if immediate {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        } else if drawerKeyboardOverlap > 0.5 {
            AppHaptics.light()
            searchDismissPending = true
        } else {
            AppHaptics.light()
            withAnimation(.easeOut(duration: 0.18), update)
        }
    }

    private func scheduleSearchDebounce(for query: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            debouncedSearchText = query
        }
    }

    private func updateDrawerKeyboardOverlap(from notification: Notification) {
        guard isSearchActive else {
            setDrawerKeyboardOverlap(0, notification: notification)
            return
        }
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .flatMap(\.windows)
                  .first(where: \.isKeyWindow)
        else { return }

        let keyboardFrame = window.convert(endFrame, from: nil)
        let overlap = max(0, window.bounds.maxY - keyboardFrame.minY)
        setDrawerKeyboardOverlap(overlap, notification: notification)
    }

    private func handleDrawerKeyboardWillHide(_ notification: Notification) {
        if searchDismissPending {
            let update = {
                isSearchActive = false
                searchDismissPending = false
                drawerKeyboardOverlap = 0
            }
            if let animation = drawerKeyboardAnimation(from: notification) {
                withAnimation(animation, update)
            } else {
                withAnimation(.easeOut(duration: 0.18), update)
            }
        } else {
            setDrawerKeyboardOverlap(0, notification: notification)
        }
    }

    private func setDrawerKeyboardOverlap(_ overlap: CGFloat, notification: Notification?) {
        let clamped = max(0, overlap)
        guard abs(drawerKeyboardOverlap - clamped) > 0.5 else { return }

        let update = {
            drawerKeyboardOverlap = clamped
        }

        guard let animation = notification.flatMap(drawerKeyboardAnimation(from:)) else {
            withAnimation(.easeOut(duration: 0.18), update)
            return
        }

        withAnimation(animation, update)
    }

    private func drawerKeyboardAnimation(from notification: Notification) -> Animation? {
        guard let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              duration > 0
        else { return nil }

        let clampedDuration = min(max(duration, 0.16), 0.42)
        let rawCurve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
            ?? UIView.AnimationCurve.easeOut.rawValue
        switch UIView.AnimationCurve(rawValue: rawCurve) ?? .easeOut {
        case .easeInOut:
            return .easeInOut(duration: clampedDuration)
        case .easeIn:
            return .easeIn(duration: clampedDuration)
        case .easeOut:
            return .easeOut(duration: clampedDuration)
        case .linear:
            return .linear(duration: clampedDuration)
        @unknown default:
            return .easeOut(duration: clampedDuration)
        }
    }

    private var drawerHeaderBackdropProgress: CGFloat {
        min(max(drawerScrollDistance / 34, 0), 1)
    }

    private func updateDrawerScrollDistance(_ distance: CGFloat) {
        guard abs(drawerScrollDistance - distance) > 0.5 else { return }
        drawerScrollDistance = distance
    }

    private func sessionMatchesSearch(_ thread: AppSessionSummary, query: String) -> Bool {
        let parentTitle = sessionsModel.derivedData.parentByKey[thread.key]?.sessionTitle ?? ""
        let fields = [
            sessionTitle(for: thread),
            thread.preview,
            thread.cwd,
            thread.serverDisplayName,
            thread.modelProvider,
            thread.agentDisplayLabel ?? "",
            parentTitle,
            thread.lastUserMessage ?? "",
            thread.lastResponsePreview ?? ""
        ]

        if fields.contains(where: { $0.localizedStandardContains(query) }) {
            return true
        }

        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            fields.contains { $0.localizedStandardContains(token) }
        }
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

    private func openSessionImmediately(_ thread: AppSessionSummary) {
        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        appModel.activateThread(thread.key)
        onOpenConversation(thread.key)
    }

    private func resumeSession(_ thread: AppSessionSummary, openedImmediately: Bool = false) async {
        guard resumingKey == nil else { return }
        resumingKey = thread.key
        defer { resumingKey = nil }

        if !openedImmediately {
            openSessionImmediately(thread)
        }

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
            if nextKey != thread.key {
                onOpenConversation(nextKey)
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
