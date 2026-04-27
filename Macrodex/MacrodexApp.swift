import Observation
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications
import os

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var pendingPushToken: Data?
    private var pendingNotificationThreadKey: ThreadKey?

    weak var appRuntime: AppRuntimeController? {
        didSet {
            if let token = pendingPushToken {
                LLog.info("push", "delivering pending device token to runtime")
                appRuntime?.setDevicePushToken(token)
                pendingPushToken = nil
            }
            if let key = pendingNotificationThreadKey {
                LLog.info(
                    "push",
                    "delivering pending notification thread open to runtime",
                    fields: ["serverId": key.serverId, "threadId": key.threadId]
                )
                pendingNotificationThreadKey = nil
                openThreadFromNotification(key)
            }
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LLog.bootstrap()
        LLog.info("lifecycle", "application did finish launching")
        AgentRuntimeBootstrap.startAsync()
        OpenAIApiKeyStore.shared.applyToEnvironment()
        GoogleAIApiKeyStore.shared.applyToEnvironment()
        // Pre-initialize Pi before SwiftUI accesses AppModel.shared.
        DispatchQueue.global(qos: .userInitiated).async {
            AppModel.prewarmPiRuntime()
        }
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        LLog.info("push", "device token received", fields: ["bytes": deviceToken.count, "hex": hex])
        if let appRuntime {
            appRuntime.setDevicePushToken(deviceToken)
        } else {
            pendingPushToken = deviceToken
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        LLog.error("push", "registration failed", error: error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        LLog.info(
            "push",
            "background push received",
            fields: [
                "applicationState": application.applicationState.debugName
            ],
            payloadJson: notificationPayloadJson(userInfo)
        )
        if application.applicationState == .active {
            LLog.info("push", "skipping background push handler because app is already active")
            completionHandler(.noData)
            return
        }
        guard let appRuntime else {
            LLog.warn("push", "background push received before runtime was ready")
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await appRuntime.handleBackgroundPush()
            LLog.info("push", "background push handling completed", fields: ["result": "newData"])
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        LLog.info(
            "push",
            "user opened notification",
            payloadJson: notificationPayloadJson(response.notification.request.content.userInfo)
        )
        if let key = AppLifecycleController.notificationThreadKey(
            from: response.notification.request.content.userInfo
        ) {
            openThreadFromNotification(key)
        }
        completionHandler()
    }

    private func openThreadFromNotification(_ key: ThreadKey) {
        LLog.info(
            "push",
            "open thread from notification",
            fields: ["serverId": key.serverId, "threadId": key.threadId]
        )
        if appRuntime == nil {
            pendingNotificationThreadKey = key
            return
        }

        Task { @MainActor [weak self] in
            guard let self, let appRuntime = self.appRuntime else { return }
            await appRuntime.openThreadFromNotification(key: key)
        }
    }

    private func notificationPayloadJson(_ userInfo: [AnyHashable: Any]) -> String? {
        guard !userInfo.isEmpty else { return nil }
        let payload = Dictionary(uniqueKeysWithValues: userInfo.map { key, value in
            (String(describing: key), String(describing: value))
        })
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }
}

@main
struct MacrodexApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel.shared
    @State private var voiceRuntime = VoiceRuntimeController.shared
    @State private var appRuntime = AppRuntimeController.shared
    @State private var themeManager = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(KeyboardDismissTapInstaller().frame(width: 0, height: 0))
                .environment(appModel)
                .environment(appRuntime)
                .environment(voiceRuntime)
                .environment(themeManager)
                .task {
                    await Task.yield()
                    appModel.start()
                    codex_healthkit_request_authorization_if_needed()
                    await DatabaseBackupManager.shared.configureIfNeeded()
                    voiceRuntime.bind(appModel: appModel)
                    appRuntime.bind(appModel: appModel, voiceRuntime: voiceRuntime)
                    appDelegate.appRuntime = appRuntime
                    Task { @MainActor in
                        await Task.yield()
                        await appModel.ensureLocalServerConnected()
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            LLog.info("lifecycle", "scenePhase changed", fields: ["phase": newPhase.debugName])
            switch newPhase {
            case .background:
                appRuntime.appDidEnterBackground()
                Task {
                    await DatabaseBackupManager.shared.handleBackground()
                }
            case .inactive:
                appRuntime.appDidBecomeInactive()
            case .active:
                appRuntime.appDidBecomeActive()
            default:
                break
            }
        }
    }
}

private extension UIApplication.State {
    var debugName: String {
        switch self {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}

private extension ScenePhase {
    var debugName: String {
        switch self {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppRuntimeController.self) private var appRuntime
    @State private var appState = AppState()
    @State private var stableSafeAreaInsets = StableSafeAreaInsets()
    @State private var conversationWarmup = ConversationWarmupCoordinator()
    @State private var composerBottomInset: CGFloat = StableSafeAreaInsets.currentBottomInset()

    private var textScale: CGFloat {
        1.0
    }

    var body: some View {
        GeometryReader { geometry in
            let resolvedBottomInset = max(
                composerBottomInset,
                stableSafeAreaInsets.bottomInset,
                geometry.safeAreaInsets.bottom,
                StableSafeAreaInsets.currentBottomInset()
            )

            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()

                HomeNavigationView(
                    topInset: geometry.safeAreaInsets.top,
                    bottomInset: resolvedBottomInset
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: [.top, .bottom])

                if let approval = appModel.snapshot?.pendingApprovals.first(where: {
                    $0.kind != .mcpElicitation
                }) {
                    ApprovalPromptView(approval: approval) { decision in
                        Task {
                            try? await appModel.store.respondToApproval(
                                requestId: approval.id,
                                decision: decision
                            )
                        }
                    } onViewThread: { threadKey in
                        appState.pendingThreadNavigation = threadKey
                    }
                }

                if let warmupID = conversationWarmup.activeWarmupID {
                    ConversationWarmupView(warmupID: warmupID) {
                        conversationWarmup.finishWarmup()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

            }
            .ignoresSafeArea(.container)
            .task {
                if composerBottomInset <= 0, resolvedBottomInset > 0 {
                    composerBottomInset = resolvedBottomInset
                }
                stableSafeAreaInsets.start(
                    fallback: resolvedBottomInset
                )
            }
            .onChange(of: stableSafeAreaInsets.bottomInset) { (_: CGFloat, nextInset: CGFloat) in
                guard nextInset > 0 else { return }
                composerBottomInset = nextInset
            }
        }
        .environment(appState)
        .environment(conversationWarmup)
        .environment(\.textScale, textScale)
        .onChange(of: appModel.snapshot?.activeThread) { _, _ in
            appState.showModelSelector = false
        }
        .onChange(of: appModel.snapshot) { _, nextSnapshot in
            appRuntime.handleSnapshot(nextSnapshot)
        }
    }
}

private let homeNavigationSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.dj.Macrodex",
    category: "HomeNavigation"
)

private let conversationRouteSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.dj.Macrodex",
    category: "ConversationRoute"
)

private enum HomeNavigationRoute: Hashable {
    case conversation(ThreadKey)
    case realtimeVoice(ThreadKey)
    case conversationInfo(ThreadKey)
}

@MainActor
@Observable
private final class HomeNavigationCoordinator {
    var path: [HomeNavigationRoute] = []
    var activeConversationKey: ThreadKey?
    var isDraftConversationActive = false
    var draftConversationID = UUID()
}

private struct HomeNavigationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(VoiceRuntimeController.self) private var voiceRuntime
    @Environment(AppState.self) private var appState
    @Environment(ConversationWarmupCoordinator.self) private var conversationWarmup
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @AppStorage("fastMode") private var fastMode = false
    @State private var homeDashboardModel = HomeDashboardModel()
    @State private var drawerController = DrawerController()
    @State private var navigationCoordinator = HomeNavigationCoordinator()
    @State private var openingRecentSessionKey: ThreadKey?
    @State private var isStartingNewSession = false
    @State private var isStartingVoice = false
    @State private var actionErrorMessage: String?
    @State private var hasSeededInitialConversationRoute = false
    @State private var hasValidatedRequiredChatGPTLogin = false
    @State private var activeQuickComposer: QuickThreadComposerMode?
    let topInset: CGFloat
    let bottomInset: CGFloat

    private var isHomeRouteActive: Bool {
        navigationPath.isEmpty
            && navigationCoordinator.activeConversationKey == nil
            && !navigationCoordinator.isDraftConversationActive
    }

    private var navigationPath: [HomeNavigationRoute] {
        get {
            navigationCoordinator.path
        }
        nonmutating set {
            navigationCoordinator.path = newValue
        }
    }

    private var selectedPrimaryItem: DrawerPrimaryItem {
        get {
            drawerController.selectedPrimaryItem
        }
        nonmutating set {
            drawerController.selectedPrimaryItem = newValue
        }
    }

    private var localServer: AppServerSnapshot? {
        appModel.snapshot?.servers.first(where: \.isLocal)
    }

    private var hasRequiredChatGPTLogin: Bool {
        localServer?.account != nil
    }

    private var localServerAuthValidationID: String {
        let revision = appModel.snapshotRevision
        let serverId = localServer?.serverId ?? "missing"
        let isConnected = localServer?.isConnected == true ? "connected" : "not-connected"
        return "\(revision)-\(serverId)-\(isConnected)-\(hasRequiredChatGPTLogin)"
    }

    var body: some View {
        Group {
            if hasRequiredChatGPTLogin {
                authenticatedNavigation
            } else if hasValidatedRequiredChatGPTLogin {
                ChatGPTLoginWallView()
            } else {
                authenticatedNavigation
            }
        }
        .task {
            homeDashboardModel.bind(appModel: appModel)
            updateHomeDashboardActivity()
        }
        .task(id: localServerAuthValidationID) {
            await validateRequiredChatGPTLoginIfNeeded()
        }
        .onChange(of: navigationCoordinator.path.count) { _, _ in
            updateHomeDashboardActivity()
        }
        .onChange(of: appState.pendingThreadNavigation) { _, newKey in
            if let newKey {
                appState.pendingThreadNavigation = nil
                replaceTopConversation(with: newKey)
            }
        }
        .alert("Home Action Failed", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "Unknown error")
        }
    }

    private func validateRequiredChatGPTLoginIfNeeded() async {
        if hasRequiredChatGPTLogin {
            hasValidatedRequiredChatGPTLogin = false
            return
        }

        guard let localServer, localServer.isConnected else {
            hasValidatedRequiredChatGPTLogin = false
            return
        }

        guard !hasValidatedRequiredChatGPTLogin else {
            return
        }

        do {
            _ = try await appModel.client.refreshAccount(
                serverId: localServer.serverId,
                params: AppRefreshAccountRequest(refreshToken: false)
            )
            await appModel.refreshSnapshot()
        } catch {
            // If refresh cannot restore an account, the explicit login wall is
            // the recovery path. Delay showing it until this check completes.
        }

        do {
            try await Task.sleep(for: .seconds(1.5))
        } catch {
            return
        }

        await appModel.refreshSnapshot()
        if !Task.isCancelled, !hasRequiredChatGPTLogin {
            hasValidatedRequiredChatGPTLogin = true
        }
    }

    private var authenticatedNavigation: some View {
        @Bindable var coordinator = navigationCoordinator

        return AppDrawerContainer(
            controller: drawerController,
            openingActivationWidth: 160,
            topSafeAreaInset: topInset,
            bottomSafeAreaInset: bottomInset,
            drawer: {
                NavigationDrawerView(
                    bottomSafeAreaInset: bottomInset,
                    selection: drawerSelection,
                    onShowDashboard: showDashboard,
                    onShowLibrary: showLibrary,
                    onShowSettings: showSettings,
                    onOpenNewChatDraft: openNewChatDraft,
                    onOpenConversation: { key in
                        openConversation(key)
                    }
                )
            },
            content: {
                NavigationStack(path: $coordinator.path) {
                    authenticatedRoot
                        .navigationDestination(for: HomeNavigationRoute.self) { route in
                            destinationView(for: route)
                        }
                }
            }
        )
        .environment(drawerController)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .sheet(item: $activeQuickComposer) { mode in
            QuickThreadPromptSheet(mode: mode) { prompt, image in
                try await startQuickThread(prompt: prompt, image: image)
            }
            .presentationDetents(mode == .camera ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var authenticatedRoot: some View {
        if navigationCoordinator.isDraftConversationActive {
            DraftConversationDestinationScreen(
                draftID: navigationCoordinator.draftConversationID,
                serverId: defaultNewSessionServerId(preferredServerId: appState.sessionsSelectedServerFilterId)
                    ?? VoiceRuntimeController.localServerID,
                bottomInset: bottomInset,
                onSend: { text, images, skillMentions in
                    try await startDraftThread(prompt: text, images: images, skillMentions: skillMentions)
                },
                onResumeSessions: { showSessions(for: $0) },
                onOpenConversation: { replaceTopConversation(with: $0) },
                onCancel: showDashboard
            )
            .id(navigationCoordinator.draftConversationID)
            .transition(.opacity)
        } else if let activeConversationKey = navigationCoordinator.activeConversationKey {
            ConversationDestinationScreen(
                threadKey: activeConversationKey,
                bottomInset: bottomInset,
                onResumeSessions: { showSessions(for: $0) },
                onOpenConversation: { replaceTopConversation(with: $0) }
            )
            .id(activeConversationKey)
            .transition(.opacity)
        } else {
            switch selectedPrimaryItem {
            case .dashboard:
                homeDashboard
            case .library:
                CalorieLibraryScreen()
            case .settings:
                DrawerSettingsView()
            }
        }
    }

    @ViewBuilder
    private func destinationView(for route: HomeNavigationRoute) -> some View {
        switch route {
        case let .conversation(threadKey):
            ConversationDestinationScreen(
                threadKey: threadKey,
                bottomInset: bottomInset,
                onResumeSessions: { showSessions(for: $0) },
                onOpenConversation: { replaceTopConversation(with: $0) }
            )
            .id(threadKey)
        case let .realtimeVoice(threadKey):
            RealtimeVoiceScreen(
                threadKey: threadKey,
                onEnd: {
                    popCurrentRoute()
                    Task { await voiceRuntime.stopActiveVoiceSession() }
                },
                onToggleSpeaker: {
                    Task { try? await voiceRuntime.toggleActiveVoiceSessionSpeaker() }
                }
            )
            .toolbar(.hidden, for: .navigationBar)
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
        case let .conversationInfo(threadKey):
            ConversationInfoView(
                threadKey: threadKey,
                serverId: nil,
                onOpenConversation: { replaceTopConversation(with: $0) }
            )
        }
    }

    private func defaultNewSessionServerId(preferredServerId: String? = nil) -> String? {
        if let preferredServerId,
           appModel.snapshot?.servers.contains(where: { $0.serverId == preferredServerId && $0.isLocal }) == true {
            return preferredServerId
        }
        if let activeServerId = appModel.snapshot?.activeThread?.serverId,
           appModel.snapshot?.servers.contains(where: { $0.serverId == activeServerId && $0.isLocal }) == true {
            return activeServerId
        }
        return appModel.snapshot?.servers.first(where: \.isLocal)?.serverId
    }

    private func handleNewSessionTap() {
        if defaultNewSessionServerId(preferredServerId: appState.sessionsSelectedServerFilterId) == nil {
            Task {
                await appModel.ensureLocalServerConnected()
                if defaultNewSessionServerId() == nil {
                    actionErrorMessage = "Local chat server is not available yet."
                    return
                }
                openNewChatDraft()
            }
            return
        }
        openNewChatDraft()
    }

    private func openNewChatDraft() {
        selectedPrimaryItem = .dashboard
        hasSeededInitialConversationRoute = true
        navigationCoordinator.activeConversationKey = nil
        navigationPath.removeAll()
        navigationCoordinator.draftConversationID = UUID()
        withAnimation(.easeInOut(duration: 0.18)) {
            navigationCoordinator.isDraftConversationActive = true
        }
    }

    private var homeVoiceLauncher: some View {
        HStack {
            Spacer()
            HomeVoiceOrbButton(
                session: voiceRuntime.activeVoiceSession,
                isAvailable: true,
                isStarting: isStartingVoice,
                action: startHomeVoiceSession
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, max(bottomInset - 12, 6))
    }

    private func startHomeVoiceSession() {
        guard !isStartingVoice else { return }
        isStartingVoice = true
        actionErrorMessage = nil

        Task {
            do {
                let selectedModel = normalizedSelectedModel()
                let selectedEffort = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                voiceRuntime.handoffModel = selectedModel
                voiceRuntime.handoffEffort = selectedEffort.isEmpty ? nil : selectedEffort
                voiceRuntime.handoffFastMode = fastMode
                let voicePermissions = await voicePermissionConfig()
                try await voiceRuntime.startPinnedLocalVoiceCall(
                    cwd: preferredVoiceWorkingDirectory(),
                    model: selectedModel,
                    approvalPolicy: voicePermissions.approvalPolicy,
                    sandboxMode: voicePermissions.sandboxMode
                )
                if let voiceKey = await MainActor.run(body: { voiceRuntime.activeVoiceSession?.threadKey }) {
                    await MainActor.run {
                        openRealtimeVoice(voiceKey)
                    }
                }
            } catch {
                await MainActor.run {
                    actionErrorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                isStartingVoice = false
            }
        }
    }

    private func normalizedSelectedModel() -> String? {
        let serverId = localServer?.serverId ?? VoiceRuntimeController.localServerID
        return selectedModelOverride(for: serverId)
    }

    private func selectedModelOverride(for serverId: String, requiresImageInput: Bool = false) -> String? {
        let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresImageInput {
            return appModel.selectedModelID(
                for: serverId,
                selectedModel: pending.isEmpty ? nil : pending,
                requiresImageInput: true
            )
        }
        if !pending.isEmpty {
            return pending
        }
        return appModel.preferredDefaultModelID(for: serverId)
    }

    private func selectedReasoningOverride() -> ReasoningEffort? {
        let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReasoningEffort(wireValue: pending.isEmpty ? nil : pending)
    }

    private func preferredVoiceWorkingDirectory() -> String {
        let current = appState.currentCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            return current
        }

        let stored = UserDefaults.standard.string(forKey: "workDir")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            return stored
        }

        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    }

    private func openRecentSession(_ thread: HomeDashboardRecentSession) async {
        guard openingRecentSessionKey == nil else { return }
        openingRecentSessionKey = thread.key
        actionErrorMessage = nil
        defer { openingRecentSessionKey = nil }

        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        openConversation(thread.key)
        let openedKey: ThreadKey?
        do {
            await conversationWarmup.prewarmIfNeeded()
            await appModel.loadConversationMetadataIfNeeded(serverId: thread.key.serverId)
            let resumeKey = await appModel.hydrateThreadPermissions(for: thread.key, appState: appState)
                ?? thread.key
            let nextKey = try await appModel.resumeThread(
                key: resumeKey,
                launchConfig: launchConfig(for: resumeKey),
                cwdOverride: thread.cwd
            )
            appModel.activateThread(nextKey)
            openedKey = nextKey
        } catch {
            actionErrorMessage = error.localizedDescription
            openedKey = nil
        }
        guard let openedKey else {
            actionErrorMessage = actionErrorMessage ?? "Failed to open conversation."
            return
        }
        appModel.activateThread(openedKey)
    }

    private func startNewSession(serverId: String, cwd: String) async {
        guard !isStartingNewSession else { return }
        let signpostID = OSSignpostID(log: homeNavigationSignpostLog)
        os_signpost(
            .begin,
            log: homeNavigationSignpostLog,
            name: "StartNewSession",
            signpostID: signpostID,
            "server=%{public}@ cwd=%{public}@",
            serverId,
            cwd
        )
        isStartingNewSession = true
        defer {
            isStartingNewSession = false
            os_signpost(.end, log: homeNavigationSignpostLog, name: "StartNewSession", signpostID: signpostID)
        }
        actionErrorMessage = nil
        await conversationWarmup.prewarmIfNeeded()
        workDir = cwd
        appState.currentCwd = cwd
        let startedKey: ThreadKey
        do {
            await appModel.loadConversationMetadataIfNeeded(serverId: serverId)
            let selectedModel = selectedModelOverride(for: serverId)
            let key = try await appModel.client.startThread(
                serverId: serverId,
                params: launchConfig(serverId: serverId, model: selectedModel).threadStartRequest(
                    cwd: cwd,
                    dynamicTools: AgentDynamicToolSpecs.defaultThreadTools(
                        includeGenerativeUI: false
                    )
                )
            )
            startedKey = key
            RecentDirectoryStore.shared.record(path: cwd, for: serverId)
            appState.requestComposerAutofocus(for: startedKey)
            appModel.store.setActiveThread(key: startedKey)
            await appModel.refreshSnapshot()
        } catch {
            actionErrorMessage = error.localizedDescription
            return
        }

        guard let resolvedKey = await appModel.ensureThreadLoaded(key: startedKey)
            ?? appModel.snapshot?.threadSnapshot(for: startedKey)?.key else {
            actionErrorMessage = appModel.lastError ?? "Failed to load the new chat."
            return
        }

        appState.requestComposerAutofocus(for: resolvedKey)
        openConversation(resolvedKey)
    }

    @MainActor
    private func startQuickThread(prompt: String, images: [UIImage]) async throws {
        try await startDraftThread(prompt: prompt, images: images, skillMentions: [])
    }

    @MainActor
    private func startQuickThread(prompt: String, image: UIImage?) async throws {
        try await startQuickThread(prompt: prompt, images: image.map { [$0] } ?? [])
    }

    @MainActor
    private func startDraftThread(
        prompt: String,
        images: [UIImage],
        skillMentions: [SkillMentionSelection]
    ) async throws {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty || !images.isEmpty else { return }

        let serverId: String
        if let resolved = defaultNewSessionServerId(preferredServerId: appState.sessionsSelectedServerFilterId) {
            serverId = resolved
        } else {
            throw NSError(
                domain: "Macrodex",
                code: 1201,
                userInfo: [NSLocalizedDescriptionKey: "Local chat server is not available yet."]
            )
        }

        let cwd = await AgentRuntimeBootstrap.defaultCwd()

        await conversationWarmup.prewarmIfNeeded()
        await appModel.loadConversationMetadataIfNeeded(serverId: serverId)
        let selectedModel = selectedModelOverride(for: serverId, requiresImageInput: !images.isEmpty)
        let selectedEffort = selectedReasoningOverride()
        workDir = cwd
        appState.currentCwd = cwd

        let startedKey = try await appModel.client.startThread(
            serverId: serverId,
            params: launchConfig(serverId: serverId, model: selectedModel).threadStartRequest(
                cwd: cwd,
                dynamicTools: AgentDynamicToolSpecs.defaultThreadTools(
                    includeGenerativeUI: false
                )
            )
        )
        RecentDirectoryStore.shared.record(path: cwd, for: serverId)
        appModel.activateThread(startedKey)
        withAnimation(.easeInOut(duration: 0.18)) {
            openConversation(startedKey)
        }
        await Task.yield()
        await appModel.refreshSnapshot()

        let resolvedKey = await appModel.ensureThreadLoaded(key: startedKey)
            ?? appModel.snapshot?.threadSnapshot(for: startedKey)?.key
            ?? startedKey
        if resolvedKey != startedKey {
            replaceTopConversation(with: resolvedKey)
        }

        var additionalInputs = skillMentions.map { mention in
            AppUserInput.skill(name: mention.name, path: AbsolutePath(value: mention.path))
        }
        additionalInputs.append(contentsOf: images.compactMap(ConversationAttachmentSupport.prepareImage).map(\.userInput))
        let payload = AppComposerPayload(
            text: trimmedPrompt,
            additionalInputs: additionalInputs,
            approvalPolicy: appState.launchApprovalPolicy(for: resolvedKey),
            sandboxPolicy: appState.turnSandboxPolicy(for: resolvedKey),
            model: selectedModel,
            effort: selectedEffort,
            serviceTier: ServiceTier(wireValue: fastMode ? "fast" : nil)
        )
        try await appModel.startTurn(key: resolvedKey, payload: payload)
        await appModel.refreshSnapshot()
    }

    private func launchConfig(for threadKey: ThreadKey? = nil) -> AppThreadLaunchConfig {
        launchConfig(
            serverId: threadKey?.serverId ?? VoiceRuntimeController.localServerID,
            model: selectedModelOverride(for: threadKey?.serverId ?? VoiceRuntimeController.localServerID),
            threadKey: threadKey
        )
    }

    private func launchConfig(
        serverId: String,
        model: String?,
        threadKey: ThreadKey? = nil
    ) -> AppThreadLaunchConfig {
        return AppThreadLaunchConfig(
            model: model ?? selectedModelOverride(for: serverId),
            approvalPolicy: appState.launchApprovalPolicy(for: nil),
            sandbox: appState.launchSandboxMode(for: nil),
            developerInstructions: AgentRuntimeInstructions.developerInstructions(for: threadKey),
            persistExtendedHistory: true
        )
    }

    private func voicePermissionConfig() async -> (
        approvalPolicy: AppAskForApproval?,
        sandboxMode: AppSandboxMode?
    ) {
        let storedThreadId = UserDefaults.standard.string(forKey: VoiceRuntimeController.persistedLocalVoiceThreadIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let threadKey = storedThreadId.flatMap { threadId -> ThreadKey? in
            guard !threadId.isEmpty else { return nil }
            return ThreadKey(serverId: VoiceRuntimeController.localServerID, threadId: threadId)
        }
        let resolvedThreadKey: ThreadKey?
        if let threadKey {
            resolvedThreadKey = await appModel.hydrateThreadPermissions(for: threadKey, appState: appState)
                ?? threadKey
        } else {
            resolvedThreadKey = nil
        }
        return (
            approvalPolicy: appState.launchApprovalPolicy(for: resolvedThreadKey),
            sandboxMode: appState.launchSandboxMode(for: resolvedThreadKey)
        )
    }

    private func openConversation(_ key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        appState.showModelSelector = false
        selectedPrimaryItem = .dashboard
        navigationCoordinator.isDraftConversationActive = false
        navigationPath.removeAll()
        guard navigationCoordinator.activeConversationKey != key else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            navigationCoordinator.activeConversationKey = key
        }
    }

    private func openRealtimeVoice(_ key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        appState.showModelSelector = false
        guard navigationPath.last != .realtimeVoice(key) else { return }
        navigationPath.append(.realtimeVoice(key))
    }

    private func replaceTopConversation(with key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        openConversation(key)
    }

    private func popCurrentRoute() {
        guard !navigationPath.isEmpty else { return }
        appState.showModelSelector = false
        navigationPath.removeLast()
    }

    private var homeDashboard: some View {
        DashboardScreen(
            bottomInset: bottomInset,
            onQuickComposerSend: { prompt, images in
                try await startQuickThread(prompt: prompt, images: images)
            },
            composerFocusRequestID: appState.homeComposerFocusRequestID
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var drawerSelection: DrawerContentSelection {
        if let key = navigationCoordinator.activeConversationKey {
            return .thread(key)
        }
        return .primary(selectedPrimaryItem)
    }

    private func pinThread(_ key: ThreadKey) {
        homeDashboardModel.pinThread(key)
    }

    private func unpinThread(_ key: ThreadKey) {
        homeDashboardModel.unpinThread(key)
    }

    private func hideThread(_ key: ThreadKey) {
        homeDashboardModel.hideThread(key)
    }

    private func hydrateThread(_ key: ThreadKey) async {
        // Resume rather than just read: `external_resume_thread` loads the
        // thread's items AND attaches a server-side conversation listener
        // for this connection, so we get live `TurnStarted` / `ItemStarted`
        // / `MessageDelta` / `TurnCompleted` events. Without it the server
        // would only push `ThreadStatusChanged` — the active-turn dot would
        // flip but the streaming bubble, tool log, and session-summary
        // updates would stay frozen until the user opened the thread.
        //
        // For a 10-row home list the listener cost is trivial, and
        // resuming preemptively avoids the "first half-second of a stream
        // is missed while we set up a subscription" latency window that an
        // active-only subscription strategy would have. `externalResume`
        // short-circuits to a no-op when IPC is live and the thread's
        // items are already populated, so warm/IPC paths are cheap.
        try? await appModel.store.externalResumeThread(key: key, hostId: nil)
        await appModel.refreshSnapshot()
    }

    private func deleteThread(_ key: ThreadKey) async {
        _ = try? await appModel.client.archiveThread(
            serverId: key.serverId,
            params: AppArchiveThreadRequest(threadId: key.threadId)
        )
        await appModel.refreshSnapshot()
    }

    @MainActor
    private func cancelThread(_ threadKey: ThreadKey) async {
        // Look up the thread's active turn id — interrupt requires both.
        guard let thread = appModel.snapshot?.threadSnapshot(for: threadKey),
              let turnId = thread.activeTurnId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !turnId.isEmpty else {
            return
        }
        do {
            _ = try await appModel.client.interruptTurn(
                serverId: threadKey.serverId,
                params: AppInterruptTurnRequest(
                    threadId: threadKey.threadId,
                    turnId: turnId
                )
            )
            await appModel.refreshSnapshot()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func sendQuickReply(_ threadKey: ThreadKey, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The server needs the thread resumed before `startTurn` can find
        // it — same path `openRecentSession` takes. On a cold launch the
        // thread is in hydrated snapshot state but not yet registered with
        // the upstream session, so a quick-reply without resume would fail
        // with "thread cannot be found".
        let resumeKey = await appModel.hydrateThreadPermissions(for: threadKey, appState: appState)
            ?? threadKey
        let activeKey: ThreadKey
        do {
            activeKey = try await appModel.resumeThread(
                key: resumeKey,
                launchConfig: launchConfig(for: resumeKey),
                cwdOverride: nil
            )
        } catch {
            actionErrorMessage = error.localizedDescription
            return
        }
        let payload = AppComposerPayload(
            text: trimmed,
            additionalInputs: [],
            approvalPolicy: appState.launchApprovalPolicy(for: activeKey),
            sandboxPolicy: appState.turnSandboxPolicy(for: activeKey),
            model: selectedModelOverride(for: activeKey.serverId),
            effort: selectedReasoningOverride(),
            serviceTier: ServiceTier(wireValue: fastMode ? "fast" : nil)
        )
        do {
            try await appModel.startTurn(key: activeKey, payload: payload)
            await appModel.refreshSnapshot()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    @Sendable
    private func loadAllThreads() async {
        guard let serverId = defaultNewSessionServerId() else { return }
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
        await appModel.refreshSnapshot()
    }

    private func updateHomeDashboardActivity() {
        if isHomeRouteActive {
            homeDashboardModel.activate()
        } else {
            homeDashboardModel.deactivate()
        }
    }

    private func showSessions(for serverId: String) {
        appState.sessionsSelectedServerFilterId = serverId
        appState.sessionsShowOnlyForks = false
        appState.showModelSelector = false
        selectedPrimaryItem = .dashboard
        hasSeededInitialConversationRoute = true
        navigationCoordinator.isDraftConversationActive = false
        navigationCoordinator.activeConversationKey = nil
        navigationPath.removeAll()
    }

    private func showDashboard() {
        appState.showModelSelector = false
        selectedPrimaryItem = .dashboard
        appModel.activateThread(nil)
        navigationCoordinator.isDraftConversationActive = false
        navigationCoordinator.activeConversationKey = nil
        navigationPath.removeAll()
    }

    private func showLibrary() {
        appState.showModelSelector = false
        selectedPrimaryItem = .library
        appModel.activateThread(nil)
        navigationCoordinator.isDraftConversationActive = false
        navigationCoordinator.activeConversationKey = nil
        navigationPath.removeAll()
    }

    private func showSettings() {
        appState.showModelSelector = false
        selectedPrimaryItem = .settings
        appModel.activateThread(nil)
        navigationCoordinator.isDraftConversationActive = false
        navigationCoordinator.activeConversationKey = nil
        navigationPath.removeAll()
    }
}

private struct DraftConversationDestinationScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    let draftID: UUID
    let serverId: String
    let bottomInset: CGFloat
    let onSend: (String, [UIImage], [SkillMentionSelection]) async throws -> Void
    let onResumeSessions: (String) -> Void
    let onOpenConversation: (ThreadKey) -> Void
    let onCancel: () -> Void
    @State private var showModelSelector = false

    private var availableModels: [ModelInfo] {
        appModel.availableModels(for: serverId)
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { appState.selectedModel },
            set: { appState.selectedModel = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: { appState.reasoningEffort },
            set: { appState.reasoningEffort = $0 }
        )
    }

    var body: some View {
        DraftConversationView(
            draftID: draftID,
            serverId: serverId,
            bottomInset: bottomInset,
            onSend: onSend,
            onOpenConversation: onOpenConversation,
            onResumeSessions: onResumeSessions
        )
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DrawerMenuButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showModelSelector = true
                } label: {
                    Image(systemName: "cpu")
                }
                .accessibilityLabel("Model settings")
            }
        }
        .sheet(isPresented: $showModelSelector) {
            ConversationOptionsSheet(
                models: availableModels,
                selectedModel: selectedModelBinding,
                reasoningEffort: reasoningEffortBinding,
                threadKey: nil
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: serverId) {
            await appModel.loadConversationMetadataIfNeeded(serverId: serverId)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

private struct ConversationDestinationScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var screenModel = ConversationScreenModel()
    let threadKey: ThreadKey
    let bottomInset: CGFloat
    let onResumeSessions: (String) -> Void
    let onOpenConversation: (ThreadKey) -> Void

    private var conversationThread: AppThreadSnapshot? {
        appModel.threadSnapshot(for: threadKey)
    }

    private var resolvedThreadKey: ThreadKey {
        conversationThread?.key ?? threadKey
    }

    private var pendingUserInputsForThread: [PendingUserInputRequest] {
        guard let snapshot = appModel.snapshot else { return [] }
        let key = resolvedThreadKey
        return snapshot.pendingUserInputs.filter {
            $0.serverId == key.serverId && $0.threadId == key.threadId
        }
    }

    private var relevantServerSnapshot: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: resolvedThreadKey.serverId)
    }

    private func bindScreenModel(for thread: AppThreadSnapshot) {
        screenModel.bind(
            thread: thread,
            appModel: appModel,
            agentDirectoryVersion: appModel.snapshot?.agentDirectoryVersion ?? 0
        )
    }

    private var navigationTitle: String {
        conversationThread?.displayTitle ?? "Conversation"
    }

    var body: some View {
        Group {
            if let conversationThread {
                ConversationView(
                    thread: conversationThread,
                    activeThreadKey: resolvedThreadKey,
                    transcript: screenModel.transcript,
                    followScrollToken: screenModel.followScrollToken,
                    pinnedContextItems: screenModel.pinnedContextItems,
                    composer: screenModel.composer,
                    topInset: 0,
                    bottomInset: bottomInset,
                    onOpenConversation: onOpenConversation,
                    onResumeSessions: onResumeSessions,
                    autoFocusComposer: appState.pendingComposerAutofocusThread == resolvedThreadKey,
                    onAutoFocusComposerConsumed: {
                        appState.consumeComposerAutofocus(for: resolvedThreadKey)
                    }
                )
                .id(resolvedThreadKey)
                .onAppear {
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: conversationThread) { _, updatedThread in
                    bindScreenModel(for: updatedThread)
                }
                .onChange(of: appModel.snapshotRevision) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: pendingUserInputsForThread) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: relevantServerSnapshot) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: appModel.composerPrefillRequest) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .tint(MacrodexTheme.accent)
                    Text("Loading chat...")
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DrawerMenuButton()
            }
            if let conversationThread {
                ToolbarItem(placement: .topBarTrailing) {
                    ConversationToolbarControls(
                        thread: conversationThread,
                        control: .modelSettings
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: threadKey) { _, _ in
            screenModel = ConversationScreenModel()
        }
        .task(id: threadKey) {
            os_signpost(
                .event,
                log: conversationRouteSignpostLog,
                name: "ThreadOpenStarted",
                "server=%{public}@ thread=%{public}@",
                threadKey.serverId,
                threadKey.threadId
            )
            appModel.activateThread(threadKey)
            if appModel.threadSnapshot(for: threadKey) == nil {
                _ = await appModel.ensureThreadLoaded(key: threadKey)
            }
            await appModel.loadConversationMetadataIfNeeded(serverId: threadKey.serverId)
            if let thread = conversationThread,
               let cwd = thread.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cwd.isEmpty {
                workDir = cwd
                appState.currentCwd = cwd
            }
        }
    }
}

private struct ApprovalPromptView: View {
    let approval: PendingApproval
    let onDecision: (ApprovalDecisionValue) -> Void
    var onViewThread: ((ThreadKey) -> Void)? = nil

    private var title: String {
        switch approval.kind {
        case .command:
            return "Command Approval Required"
        case .fileChange:
            return "File Change Approval Required"
        case .permissions:
            return "Permissions Approval Required"
        case .mcpElicitation:
            return "MCP Input Required"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .macrodexFont(.headline)
                    .foregroundColor(MacrodexTheme.textPrimary)

                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .macrodexFont(.footnote)
                        .foregroundColor(MacrodexTheme.textSecondary)
                }

                if let threadId = approval.threadId, onViewThread != nil {
                    HStack {
                        Button {
                            onViewThread?(ThreadKey(serverId: approval.serverId, threadId: threadId))
                        } label: {
                            HStack(spacing: 3) {
                                Text("View Chat")
                                    .macrodexFont(.caption, weight: .medium)
                                Image(systemName: "arrow.right")
                                    .macrodexFont(size: 9, weight: .semibold)
                            }
                            .foregroundColor(MacrodexTheme.accent)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }

                if let command = approval.command, !command.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command")
                            .macrodexFont(.caption)
                            .foregroundColor(MacrodexTheme.textMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(command)
                                .macrodexFont(.footnote)
                                .foregroundColor(MacrodexTheme.textBody)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(MacrodexTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if let cwd = approval.cwd, !cwd.isEmpty {
                    Text("CWD: \(cwd)")
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textMuted)
                }

                if let grantRoot = approval.grantRoot, !grantRoot.isEmpty {
                    Text("Grant Root: \(grantRoot)")
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textMuted)
                }

                VStack(spacing: 8) {
                    Button("Allow Once") { onDecision(.accept) }
                        .buttonStyle(.borderedProminent)
                        .tint(MacrodexTheme.accent)
                        .frame(maxWidth: .infinity)

                    Button("Allow for Session") { onDecision(.acceptForSession) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 8) {
                        Button("Deny") { onDecision(.decline) }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)

                        Button("Abort") { onDecision(.cancel) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
                .macrodexFont(.callout)
            }
            .padding(16)
            .modifier(GlassRectModifier(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(MacrodexTheme.border, lineWidth: 1)
            )
            .padding(.horizontal, 16)
        }
        .transition(.opacity)
    }
}

extension Notification.Name {
    static let dashboardComposerShouldDismissKeyboard = Notification.Name("com.dj.macrodex.dashboardComposerShouldDismissKeyboard")
}

private struct DashboardComposerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private enum DashboardFoodSearchSelection: Identifiable {
    case library(CalorieLibraryItem)
    case canonical(CanonicalFoodItem)
    case suggested(ComposerFoodSearchResult)

    var id: String {
        switch self {
        case .library(let item): return "library-\(item.id)"
        case .canonical(let item): return "canonical-\(item.id)"
        case .suggested(let item): return "suggested-\(item.id)"
        }
    }
}

private struct DashboardScannedNutritionLabelDraft: Identifiable {
    let id = UUID()
    let result: NutritionLabelScanResult
    let photoData: Data
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        let trimmed = trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    var doubleValue: Double {
        Double(trimmed.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    var optionalDouble: Double? {
        let value = doubleValue
        return trimmed.isEmpty ? nil : value
    }
}

private extension Double {
    var cleanString: String {
        if rounded() == self {
            return String(Int(self))
        }
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.1f", self)
    }
}

struct DashboardQuickComposerBar: View {
    @Environment(AppModel.self) private var appModel
    let bottomInset: CGFloat
    let focusRequestID: Int
    let onSend: (String, [UIImage]) async throws -> Void

    @State private var inputText = ""
    @State private var attachedImages: [UIImage] = []
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var cameraImage: UIImage?
    @State private var showNutritionLabelPicker = false
    @State private var selectedNutritionLabelPhoto: PhotosPickerItem?
    @State private var scannedNutritionLabel: DashboardScannedNutritionLabelDraft?
    @State private var isScanningNutritionLabel = false
    @State private var voiceManager = VoiceTranscriptionManager()
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var isComposerFocused = false
    @State private var keyboardVisible = false
    @State private var keyboardTop: CGFloat?
    @State private var composerFrame: CGRect = .zero
    @State private var composerContentHeight: CGFloat = 56
    @State private var keyboardLift: CGFloat = 0
    @State private var isFoodSearchMode = false
    @State private var foodSearchLoading = false
    @State private var foodSearchResults: [ComposerFoodSearchResult] = []
    @State private var foodSearchTask: Task<Void, Never>?
    @State private var foodSearchCache: [String: [ComposerFoodSearchResult]] = [:]
    @State private var selectedFoodSearchResult: DashboardFoodSearchSelection?

    private var trimmedText: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        (!trimmedText.isEmpty || !attachedImages.isEmpty) && !isSending
    }

    private var popupState: ConversationComposerPopupState {
        if isFoodSearchMode {
            guard !trimmedText.isEmpty else {
                return .foodSearch(loading: false, suggestions: recentFoodSuggestions())
            }
            return .foodSearch(loading: foodSearchLoading, suggestions: foodSearchResults)
        }

        guard shouldAutoSuggestFood(for: inputText),
              foodSearchLoading || !foodSearchResults.isEmpty
        else {
            return .none
        }
        return .foodSearch(loading: foodSearchLoading, suggestions: foodSearchResults)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(MacrodexTheme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 2)
            }

            ConversationComposerContentView(
                attachedImages: attachedImages,
                collaborationMode: .default,
                activePlanProgress: nil,
                pendingUserInputRequest: nil,
                hasPendingPlanImplementation: false,
                activeTaskSummary: nil,
                queuedFollowUps: [],
                rateLimits: nil,
                contextPercent: nil,
                isTurnActive: isSending,
                showModeChip: false,
                voiceManager: voiceManager,
                isFoodSearchMode: isFoodSearchMode,
                showsFoodSearchButton: true,
                showAttachMenu: $showAttachMenu,
                onRemoveAttachment: { index in
                    guard attachedImages.indices.contains(index) else { return }
                    attachedImages.remove(at: index)
                },
                onRespondToPendingUserInput: { _ in },
                onSteerQueuedFollowUp: { _ in },
                onDeleteQueuedFollowUp: { _ in },
                onPasteImage: appendAttachment,
                onToggleFoodSearchMode: toggleFoodSearchMode,
                onOpenModePicker: {},
                onSendText: submit,
                onStopRecording: stopVoiceRecording,
                onStartRecording: startVoiceRecording,
                onInterrupt: {},
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
                onApplySlashSuggestion: { _ in },
                onApplyFileSuggestion: { _ in },
                onApplySkillSuggestion: { _ in },
                bottomInset: composerContentHeight + 8,
                popupLift: 10,
                onApplyFoodSuggestion: applyFoodSuggestion
            )
        }
        .sheet(isPresented: $showAttachMenu) {
            ConversationComposerAttachSheet(
                onPickPhotoLibrary: {
                    showAttachMenu = false
                    showPhotoPicker = true
                },
                onTakePhoto: {
                    showAttachMenu = false
                    showCamera = true
                },
                onScanNutritionLabel: {
                    showAttachMenu = false
                    showNutritionLabelPicker = true
                }
            )
            .presentationDetents([.height(274)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $scannedNutritionLabel) { draft in
            CalorieLogFoodSheet(
                store: CalorieTrackerStore.shared,
                scannedLabel: draft.result,
                photoData: draft.photoData,
                title: "Food Details"
            )
        }
        .sheet(item: $selectedFoodSearchResult) { selection in
            DashboardFoodSearchLogSheet(
                store: CalorieTrackerStore.shared,
                selection: selection
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 6, matching: .images)
        .photosPicker(isPresented: $showNutritionLabelPicker, selection: $selectedNutritionLabelPhoto, matching: .images)
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadSelectedPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(image: $cameraImage)
                .ignoresSafeArea()
        }
        .onChange(of: cameraImage) { _, image in
            guard let image else { return }
            appendAttachment(image)
            cameraImage = nil
        }
        .onChange(of: selectedNutritionLabelPhoto) { _, item in
            guard let item else { return }
            Task { await scanNutritionLabel(item) }
        }
        .onChange(of: inputText) { _, text in
            scheduleFoodSearch(for: text)
        }
        .overlay(alignment: .top) {
            if isScanningNutritionLabel {
                Label("Scanning label...", systemImage: "text.viewfinder")
                    .macrodexFont(.caption, weight: .semibold)
                    .foregroundStyle(MacrodexTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(MacrodexTheme.surface.opacity(0.92), in: Capsule())
                    .offset(y: -42)
            }
        }
        .padding(.bottom, composerBottomPadding)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DashboardComposerFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        )
        .offset(y: keyboardVisible ? -keyboardLift : closedComposerYOffset)
        .onPreferenceChange(DashboardComposerFramePreferenceKey.self) { frame in
            composerFrame = frame
            updateKeyboardLift(notification: nil)
        }
        .onPreferenceChange(ConversationComposerContentHeightPreferenceKey.self) { height in
            composerContentHeight = max(56, height)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            keyboardVisible = true
            updateKeyboardFrame(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardFrame(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
            keyboardTop = nil
            setKeyboardLift(0, notification: nil)
            isFoodSearchMode = false
            clearFoodSearchState(cancelTask: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardComposerShouldDismissKeyboard)) { _ in
            isComposerFocused = false
        }
        .onAppear {
            focusIfRequested()
        }
        .onChange(of: focusRequestID) { _, _ in
            focusIfRequested()
        }
        .onDisappear {
            isComposerFocused = false
            if voiceManager.isRecording { voiceManager.cancelRecording() }
            foodSearchTask?.cancel()
            foodSearchTask = nil
        }
    }

    private func focusIfRequested() {
        guard focusRequestID > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            isComposerFocused = true
        }
    }

    private var composerBottomPadding: CGFloat {
        keyboardVisible ? 8 : 10
    }

    private var closedComposerYOffset: CGFloat {
        min(max(bottomInset - 18, 0), 16)
    }

    private func updateKeyboardFrame(from notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .flatMap(\.windows)
                  .first(where: \.isKeyWindow)
        else {
            keyboardTop = nil
            updateKeyboardLift(notification: notification)
            return
        }

        let keyboardFrame = window.convert(endFrame, from: nil)
        keyboardTop = keyboardFrame.minY
        keyboardVisible = keyboardFrame.minY < window.bounds.maxY
        updateKeyboardLift(notification: notification)
    }

    private func updateKeyboardLift(notification: Notification?) {
        guard keyboardVisible,
              let keyboardTop,
              composerFrame != .zero
        else {
            setKeyboardLift(0, notification: notification)
            return
        }

        let desiredGap: CGFloat = 8
        let lift = max(0, composerFrame.maxY + desiredGap - keyboardTop)
        setKeyboardLift(lift, notification: notification)
    }

    private func setKeyboardLift(_ lift: CGFloat, notification: Notification?) {
        guard abs(keyboardLift - lift) > 0.5 else { return }

        let update = {
            keyboardLift = lift
        }

        guard let notification,
              let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              duration > 0
        else {
            update()
            return
        }

        withAnimation(.easeOut(duration: duration)) {
            update()
        }
    }

    private func submit() {
        guard canSend else { return }
        let prompt = trimmedText
        let images = attachedImages
        AppHaptics.medium()
        inputText = ""
        attachedImages = []
        isFoodSearchMode = false
        clearFoodSearchState(cancelTask: true)
        isComposerFocused = false
        isSending = true
        errorMessage = nil

        Task {
            do {
                try await onSend(prompt, images)
                await MainActor.run {
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    inputText = prompt
                    attachedImages = images
                    errorMessage = error.localizedDescription
                    isSending = false
                }
            }
        }
    }

    private func appendAttachment(_ image: UIImage) {
        guard attachedImages.count < 6 else { return }
        attachedImages.append(image)
    }

    private func toggleFoodSearchMode() {
        isFoodSearchMode.toggle()
        if isFoodSearchMode {
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
        let isAutomaticSearch = shouldAutoSuggestFood(for: query)
        guard isFoodSearchMode || isAutomaticSearch else {
            clearFoodSearchState(cancelTask: true)
            return
        }
        foodSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            foodSearchLoading = false
            foodSearchResults = recentFoodSuggestions()
            foodSearchCache[""] = foodSearchResults
            return
        }
        if let cached = foodSearchCache[trimmed] {
            foodSearchResults = cached
            foodSearchLoading = false
            return
        }
        foodSearchLoading = true
        foodSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: isAutomaticSearch ? 420_000_000 : 220_000_000)
            guard !Task.isCancelled else { return }
            await CalorieTrackerStore.shared.refresh()
            guard !Task.isCancelled else { return }
            let localResults = foodSearchMatches(for: trimmed)
            foodSearchResults = localResults
            if trimmed.count >= 2 {
                let rankedResults = await FoodSearchAIResolver.results(
                    query: trimmed,
                    candidates: localResults,
                    timeoutSeconds: isAutomaticSearch ? 14 : 10
                )
                guard !Task.isCancelled else { return }
                foodSearchResults = rankedResults
                foodSearchCache[trimmed] = rankedResults
            }
            foodSearchLoading = false
        }
    }

    private func shouldAutoSuggestFood(for query: String) -> Bool {
        guard !isFoodSearchMode,
              attachedImages.isEmpty,
              !isSending
        else {
            return false
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3,
              trimmed.count <= 72,
              !trimmed.contains("\n"),
              !trimmed.contains("?")
        else {
            return false
        }

        let tokens = trimmed
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, tokens.count <= 7 else { return false }

        let promptStarters: Set<String> = [
            "add", "analyze", "can", "could", "create", "explain", "find",
            "help", "how", "i", "log", "make", "please", "should", "show",
            "summarize", "tell", "track", "what", "why", "write"
        ]
        if let first = tokens.first, promptStarters.contains(first) {
            return false
        }

        let foodSignals: Set<String> = [
            "bar", "beef", "bowl", "bread", "burger", "cereal", "cheese",
            "chicken", "chips", "coffee", "cookie", "cream", "drink", "egg",
            "fish", "fries", "greek", "milk", "oat", "oatmeal", "pasta",
            "pizza", "protein", "rice", "salad", "salmon", "sandwich",
            "shake", "smoothie", "soup", "steak", "tea", "tuna", "wrap",
            "yogurt"
        ]
        let hasFoodSignal = tokens.contains { token in
            foodSignals.contains(token) || foodSignals.contains { token.hasPrefix($0) }
        }
        let hasProductSignal = trimmed.contains("'")
            || trimmed.contains("’")
            || trimmed.contains("%")
            || tokens.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil }

        return hasFoodSignal || (hasProductSignal && tokens.count >= 2)
    }

    private func recentFoodSuggestions() -> [ComposerFoodSearchResult] {
        CalorieTrackerStore.shared.recentFoodMemories.prefix(5).map { item in
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
                confidence: 0.9
            )
        }
    }

    private func foodSearchMatches(for query: String) -> [ComposerFoodSearchResult] {
        let libraryMatches = CalorieTrackerStore.shared.libraryItems.compactMap { item -> (ComposerFoodSearchResult, Int)? in
            let candidates = [item.name, item.brand, item.kind, item.sourceTitle] + item.aliases.map(Optional.some)
            let score = candidates.compactMap { $0 }.compactMap { quickFuzzyScore(candidate: $0, query: query) }.max()
            guard let score else { return nil }
            let title = item.brand.map { "\($0) \(item.name)" } ?? item.name
            return (ComposerFoodSearchResult(
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
            ), score + (item.isFavorite ? 12 : 0))
        }
        let recentMatches = CalorieTrackerStore.shared.recentFoodMemories.compactMap { item -> (ComposerFoodSearchResult, Int)? in
            let candidates = [item.title, item.displayName, item.brand, item.canonicalName]
            let score = candidates.compactMap { $0 }.compactMap { quickFuzzyScore(candidate: $0, query: query) }.max()
            guard let score else { return nil }
            return (ComposerFoodSearchResult(
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
            ), score + 6)
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

    private func applyFoodSuggestion(_ suggestion: ComposerFoodSearchResult) {
        if let selection = foodSearchSelection(for: suggestion) {
            selectedFoodSearchResult = selection
        } else {
            selectedFoodSearchResult = .suggested(suggestion)
        }
        inputText = ""
        isComposerFocused = true
        isFoodSearchMode = false
        clearFoodSearchState(cancelTask: true)
    }

    private func foodSearchSelection(for suggestion: ComposerFoodSearchResult) -> DashboardFoodSearchSelection? {
        if suggestion.id.hasPrefix("library-") {
            let id = String(suggestion.id.dropFirst("library-".count))
            if let item = CalorieTrackerStore.shared.libraryItems.first(where: { $0.id == id }) {
                return .library(item)
            }
        }
        if suggestion.id.hasPrefix("recent-") {
            let id = String(suggestion.id.dropFirst("recent-".count))
            if let item = CalorieTrackerStore.shared.recentFoodMemories.first(where: { $0.id == id }) {
                return .canonical(item)
            }
        }
        if suggestion.id.hasPrefix("standard-") {
            return .suggested(suggestion)
        }
        return nil
    }

    private func quickFuzzyScore(candidate: String, query: String) -> Int? {
        let candidate = candidate.lowercased()
        let query = query.lowercased()
        guard !query.isEmpty else { return 0 }
        if candidate == query { return 10_000 }
        if candidate.hasPrefix(query) { return 8_000 - candidate.count }
        if candidate.contains(query) { return 6_000 - candidate.count }
        var score = 0
        var searchStart = candidate.startIndex
        for scalar in query {
            guard let found = candidate[searchStart...].firstIndex(of: scalar) else { return nil }
            score += candidate.distance(from: searchStart, to: found) == 0 ? 90 : 25
            searchStart = candidate.index(after: found)
        }
        return score - candidate.count
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

    private func scanNutritionLabel(_ item: PhotosPickerItem) async {
        selectedNutritionLabelPhoto = nil
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        isScanningNutritionLabel = true
        defer { isScanningNutritionLabel = false }
        do {
            let result = try await PiAgentRuntimeBackend.shared.scanNutritionLabel(imageData: data)
            scannedNutritionLabel = DashboardScannedNutritionLabelDraft(result: result, photoData: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startVoiceRecording() {
        Task {
            let granted = await voiceManager.requestMicPermission()
            guard granted else { return }
            voiceManager.startRecording()
        }
    }

    private func stopVoiceRecording() {
        Task {
            let serverId = appModel.snapshot?.servers.first(where: \.isLocal)?.serverId ?? VoiceRuntimeController.localServerID
            let auth = try? await appModel.client.authStatus(
                serverId: serverId,
                params: AuthStatusRequest(includeToken: true, refreshToken: false)
            )
            if let text = await voiceManager.stopAndTranscribe(
                authMethod: auth?.authMethod,
                authToken: auth?.authToken
            ), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = text
                isComposerFocused = true
            }
        }
    }
}

private struct DashboardFoodSearchLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    let selection: DashboardFoodSearchSelection

    @State private var name: String
    @State private var mealType: CalorieMealType = .currentDefault
    @State private var servingQuantity: String
    @State private var servingUnit: String
    @State private var servingWeight: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String
    @State private var notes = ""
    @State private var saveToLibrary = false

    private let baseQuantity: Double
    private let baseUnit: String
    private let baseWeight: Double?
    private let baseCalories: Double
    private let baseProtein: Double
    private let baseCarbs: Double
    private let baseFat: Double

    init(store: CalorieTrackerStore, selection: DashboardFoodSearchSelection) {
        self.store = store
        self.selection = selection
        let seed = Self.seed(for: selection)
        _name = State(initialValue: seed.name)
        _servingQuantity = State(initialValue: seed.quantity.cleanString)
        _servingUnit = State(initialValue: seed.unit)
        _servingWeight = State(initialValue: seed.weight?.cleanString ?? "")
        _calories = State(initialValue: seed.calories > 0 ? seed.calories.cleanString : "")
        _protein = State(initialValue: seed.protein > 0 ? seed.protein.cleanString : "")
        _carbs = State(initialValue: seed.carbs > 0 ? seed.carbs.cleanString : "")
        _fat = State(initialValue: seed.fat > 0 ? seed.fat.cleanString : "")
        if case .suggested(let item) = selection {
            _notes = State(initialValue: item.notes ?? "")
        }
        _saveToLibrary = State(initialValue: {
            if case .suggested = selection { return true }
            return false
        }())
        baseQuantity = seed.quantity
        baseUnit = seed.unit
        baseWeight = seed.weight
        baseCalories = seed.calories
        baseProtein = seed.protein
        baseCarbs = seed.carbs
        baseFat = seed.fat
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    HStack(spacing: 12) {
                        FoodIconView(foodName: name, size: 36)
                        TextField("Name", text: $name)
                    }
                    Picker("Meal", selection: $mealType) {
                        ForEach(CalorieMealType.allCases) { meal in
                            Label(meal.title, systemImage: meal.systemImage).tag(meal)
                        }
                    }
                }

                Section("Serving") {
                    servingEditorRow
                    detailNumberRow("Weight", unit: "g", text: $servingWeight)
                }

                Section("Nutrition") {
                    detailNumberRow("Calories", unit: "kcal", text: $calories)
                    detailNumberRow("Protein", unit: "g", text: $protein)
                    detailNumberRow("Carbs", unit: "g", text: $carbs)
                    detailNumberRow("Fat", unit: "g", text: $fat)
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                    if case .suggested = selection {
                        Toggle("Save to library", isOn: $saveToLibrary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Log Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await save()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(name.trimmed.isEmpty || calories.doubleValue <= 0)
                    .accessibilityLabel("Log food")
                }
            }
        }
    }

    private var servingEditorRow: some View {
        HStack(spacing: 8) {
            Text("Amount")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 68, alignment: .leading)
            Spacer(minLength: 4)
            Button { adjustServing(by: -servingStep) } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(servingQuantity.doubleValue <= servingStep)

            TextField("1", text: $servingQuantity)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 50)
                .onChange(of: servingQuantity) { _, _ in recalculateNutrition() }

            TextField("Unit", text: $servingUnit)
                .textInputAutocapitalization(.never)
                .frame(width: 72)
                .onChange(of: servingUnit) { _, _ in recalculateNutrition() }

            Button { adjustServing(by: servingStep) } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
        }
    }

    private func detailNumberRow(_ label: String, unit: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .lineLimit(1)
            Spacer(minLength: 12)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 90)
            Text(unit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    private var servingStep: Double {
        let unit = servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["g", "gram", "grams", "ml", "milliliter", "milliliters"].contains(unit) {
            return 25
        }
        return 1
    }

    private func adjustServing(by delta: Double) {
        let current = servingQuantity.doubleValue > 0 ? servingQuantity.doubleValue : 0
        let next = max(servingStep == 1 ? 1 : servingStep, current + delta)
        servingQuantity = next.cleanString
        if ["g", "gram", "grams"].contains(servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            servingWeight = next.cleanString
        }
        recalculateNutrition()
    }

    private func recalculateNutrition() {
        guard baseCalories > 0 else { return }
        let scale = nutritionScale()
        calories = (baseCalories * scale).cleanString
        protein = (baseProtein * scale).cleanString
        carbs = (baseCarbs * scale).cleanString
        fat = (baseFat * scale).cleanString
        if let baseWeight {
            servingWeight = (baseWeight * scale).cleanString
        }
    }

    private func nutritionScale() -> Double {
        let quantity = max(servingQuantity.doubleValue, 0)
        let unit = servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = baseUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["g", "gram", "grams", "ml", "milliliter", "milliliters"].contains(unit),
           let baseWeight,
           baseWeight > 0 {
            return quantity / baseWeight
        }
        if unit == base, baseQuantity > 0 {
            return quantity / baseQuantity
        }
        return quantity / max(baseQuantity, 0.0001)
    }

    private func save() async {
        AppHaptics.medium()
        let quantity = max(servingQuantity.doubleValue, 0)
        let unit = servingUnit.trimmed.nilIfBlank ?? "serving"
        let weight = servingWeight.optionalDouble
        switch selection {
        case .library(let item):
            await store.logLibraryItem(
                item.id,
                mealType: mealType,
                servingQty: quantity,
                servingUnit: unit,
                servingWeight: weight,
                calories: calories.doubleValue,
                protein: protein.doubleValue,
                carbs: carbs.doubleValue,
                fat: fat.doubleValue,
                notes: notes
            )
        case .canonical(let item):
            await store.logCanonicalFood(
                item.id,
                mealType: mealType,
                servingQty: quantity,
                servingUnit: unit,
                servingWeight: weight,
                calories: calories.doubleValue,
                protein: protein.doubleValue,
                carbs: carbs.doubleValue,
                fat: fat.doubleValue,
                notes: notes
            )
        case .suggested:
            await store.logFood(
                name: name,
                calories: calories.doubleValue,
                protein: protein.optionalDouble,
                carbs: carbs.optionalDouble,
                fat: fat.optionalDouble,
                fiber: nil,
                sugars: nil,
                sodium: nil,
                potassium: nil,
                notes: notes,
                sourceTitle: suggestedSourceTitle,
                sourceURL: suggestedSourceURL,
                mealType: mealType,
                photoData: nil,
                saveToLibrary: saveToLibrary,
                servingQty: quantity,
                servingUnit: unit,
                servingWeight: weight
            )
        }
    }

    private var suggestedSourceTitle: String {
        if case .suggested(let item) = selection {
            return item.source ?? "Food search"
        }
        return "Food search"
    }

    private var suggestedSourceURL: String {
        if case .suggested(let item) = selection {
            return item.sourceURL ?? ""
        }
        return ""
    }

    private static func seed(for selection: DashboardFoodSearchSelection) -> (
        name: String,
        quantity: Double,
        unit: String,
        weight: Double?,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double
    ) {
        switch selection {
        case .library(let item):
            return (
                item.brand.map { "\($0) \(item.name)" } ?? item.name,
                item.defaultServingQty ?? 1,
                item.defaultServingUnit ?? "serving",
                item.defaultServingWeight,
                item.calories,
                item.protein,
                item.carbs,
                item.fat
            )
        case .canonical(let item):
            return (
                item.title,
                item.defaultServingQty ?? 1,
                item.defaultServingUnit ?? "serving",
                item.defaultServingWeight,
                item.calories,
                item.protein,
                item.carbs,
                item.fat
            )
        case .suggested(let item):
            return (
                item.insertText,
                item.servingQuantity ?? 1,
                item.servingUnit ?? "serving",
                item.servingWeight,
                item.calories ?? 0,
                item.protein ?? 0,
                item.carbs ?? 0,
                item.fat ?? 0
            )
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            MacrodexTheme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(MacrodexTheme.surface.opacity(0.92))
                        .frame(width: 108, height: 108)
                    Circle()
                        .stroke(MacrodexTheme.border.opacity(0.85), lineWidth: 1)
                        .frame(width: 108, height: 108)
                    Image(systemName: "terminal")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(MacrodexTheme.accent)
                }

                Text("Macrodex")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(MacrodexTheme.textPrimary)
            }
        }
    }
}
