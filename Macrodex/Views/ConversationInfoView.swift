import SwiftUI
import Charts

struct ConversationInfoView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    /// When nil, the screen shows server-only info (no session-specific sections).
    let threadKey: ThreadKey?
    /// Server ID used when threadKey is nil (server-only mode).
    let serverId: String?
    var onOpenConversation: ((ThreadKey) -> Void)?

    /// Whether we're in server-only mode (no specific thread).
    private var isServerOnly: Bool { threadKey == nil }

    private var resolvedServerId: String? {
        threadKey?.serverId ?? serverId
    }

    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var stats: AppConversationStats?
    @State private var serverUsage: AppServerUsageStats?

    private var thread: AppThreadSnapshot? {
        guard let threadKey else { return nil }
        return appModel.snapshot?.threads.first { $0.key == threadKey }
    }

    private var server: AppServerSnapshot? {
        guard let sid = resolvedServerId else { return nil }
        return appModel.snapshot?.servers.first { $0.serverId == sid }
    }

    private var allServerThreads: [AppThreadSnapshot] {
        guard let snapshot = appModel.snapshot, let sid = resolvedServerId else { return [] }
        return snapshot.threads.filter { $0.key.serverId == sid }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !isServerOnly {
                    // Hero header
                    heroSection
                        .padding(.bottom, 20)

                    // Action buttons row (Telegram-style)
                    actionButtonsRow
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)

                    // Thin divider
                    Rectangle()
                        .fill(MacrodexTheme.separator.opacity(0.4))
                        .frame(height: 0.5)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }

                // Content sections
                VStack(spacing: 16) {
                    if !isServerOnly {
                        contextWindowSection
                        conversationStatsSection
                    }
                    serverChartsSection
                    serverInfoSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(MacrodexTheme.backgroundGradient)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(isServerOnly ? "Server Info" : "Info")
                    .macrodexFont(size: 16, weight: .semibold)
                    .foregroundStyle(MacrodexTheme.textPrimary)
            }
        }
        .onAppear { computeData() }
        .onChange(of: thread?.hydratedConversationItems.count) { computeData() }
        .alert("Rename Chat", isPresented: $isRenaming) {
            TextField("Chat name", text: $renameText)
            Button("Save") { saveRename() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 12) {
            // Status dot + title
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(thread?.displayTitle ?? "New Chat")
                    .macrodexFont(size: 22, weight: .bold)
                    .foregroundStyle(MacrodexTheme.textPrimary)
                    .lineLimit(2)
            }

            // Model + reasoning badges
            HStack(spacing: 8) {
                if let model = thread?.model ?? thread?.info.model {
                    Text(model)
                        .macrodexFont(size: 13, weight: .medium)
                        .foregroundStyle(MacrodexTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .modifier(GlassRectModifier(cornerRadius: 8))
                }
                if let effort = thread?.reasoningEffort {
                    Text(effort)
                        .macrodexFont(size: 12, weight: .regular)
                        .foregroundStyle(MacrodexTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .modifier(GlassRectModifier(cornerRadius: 8))
                }
            }

            // Metadata row: cwd + timestamps
            VStack(spacing: 6) {
                if let cwd = thread?.info.cwd {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(MacrodexTheme.textMuted)
                        Text(abbreviatePath(cwd))
                            .macrodexFont(size: 12)
                            .foregroundStyle(MacrodexTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let tid = threadKey?.threadId {
                    HStack(spacing: 5) {
                        Image(systemName: "number")
                            .font(.system(size: 10))
                            .foregroundStyle(MacrodexTheme.textMuted)
                        Text(tid)
                            .macrodexFont(size: 11)
                            .foregroundStyle(MacrodexTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 12) {
                    if let created = thread?.info.createdAt {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                                .foregroundStyle(MacrodexTheme.textMuted)
                            Text(relativeDate(created))
                                .macrodexFont(size: 11)
                                .foregroundStyle(MacrodexTheme.textMuted)
                        }
                    }
                    if let updated = thread?.info.updatedAt {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                                .foregroundStyle(MacrodexTheme.textMuted)
                            Text(relativeDate(updated))
                                .macrodexFont(size: 11)
                                .foregroundStyle(MacrodexTheme.textMuted)
                        }
                    }
                }
            }
        }
        .padding(.top, 16)
    }

    private func abbreviatePath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Action Buttons Row (Telegram-style)

    private var actionButtonsRow: some View {
        HStack(spacing: 0) {
            actionCircle(icon: "arrow.branch", label: "Fork") {
                Task { await forkConversation() }
            }
            actionCircle(icon: "pencil", label: "Rename") {
                renameText = thread?.info.title ?? ""
                isRenaming = true
            }
        }
    }

    private func actionCircle(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(MacrodexTheme.accent)
                    .frame(width: 52, height: 52)
                    .modifier(GlassRectModifier(cornerRadius: 14))
                Text(label)
                    .macrodexFont(size: 11, weight: .medium)
                    .foregroundStyle(MacrodexTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func timestampLabel(_ label: String, timestamp: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .macrodexFont(size: 10, weight: .medium)
                .foregroundStyle(MacrodexTheme.textMuted)
            Text(relativeDate(timestamp))
                .macrodexFont(size: 12)
                .foregroundStyle(MacrodexTheme.textSecondary)
        }
    }

    private var statusColor: Color {
        switch thread?.info.status {
        case .active: return MacrodexTheme.success
        case .idle: return MacrodexTheme.textMuted
        case .systemError: return MacrodexTheme.danger
        case .notLoaded: return MacrodexTheme.textMuted
        default: return MacrodexTheme.textMuted
        }
    }

    private var statusLabel: String {
        switch thread?.info.status {
        case .active: return "Active"
        case .idle: return "Idle"
        case .systemError: return "Error"
        case .notLoaded: return "Not Loaded"
        default: return "Unknown"
        }
    }

    // MARK: - Context Window

    private var contextWindowSection: some View {
        Group {
            if let used = thread?.contextTokensUsed, let window = thread?.modelContextWindow, window > 0 {
                let percent = Double(used) / Double(window)
                VStack(spacing: 8) {
                    HStack {
                        Text("Context Window")
                            .macrodexFont(size: 14, weight: .semibold)
                            .foregroundStyle(MacrodexTheme.textPrimary)
                        Spacer()
                        Text("\(Int(percent * 100))%")
                            .macrodexFont(size: 14, weight: .bold)
                            .foregroundStyle(contextColor(percent: percent))
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(MacrodexTheme.border)
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(contextColor(percent: percent))
                                .frame(width: geo.size.width * min(1, percent), height: 8)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text(formatTokens(used))
                            .macrodexFont(size: 11)
                            .foregroundStyle(MacrodexTheme.textMuted)
                        Spacer()
                        Text(formatTokens(window))
                            .macrodexFont(size: 11)
                            .foregroundStyle(MacrodexTheme.textMuted)
                    }
                }
                .padding(16)
                .modifier(GlassRectModifier(cornerRadius: 12))
            }
        }
    }

    private func contextColor(percent: Double) -> Color {
        if percent >= 0.8 { return MacrodexTheme.danger }
        if percent >= 0.6 { return MacrodexTheme.warning }
        return MacrodexTheme.accent
    }

    private func formatTokens(_ tokens: UInt64) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    // MARK: - Per-Conversation Stats

    private var conversationStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversation Stats")
                .macrodexFont(size: 14, weight: .semibold)
                .foregroundStyle(MacrodexTheme.textPrimary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                statCard("Messages", value: "\(stats?.totalMessages ?? 0)", detail: "\(stats?.userMessageCount ?? 0) user · \(stats?.assistantMessageCount ?? 0) assistant")
                statCard("Turns", value: "\(stats?.turnCount ?? 0)")
                statCard("Commands", value: "\(stats?.commandsExecuted ?? 0)", detail: "\(stats?.commandsSucceeded ?? 0) ok · \(stats?.commandsFailed ?? 0) fail")
                statCard("Files Changed", value: "\(stats?.filesChanged ?? 0)", detail: "+\(stats?.diffAdditions ?? 0) / -\(stats?.diffDeletions ?? 0)")
                statCard("MCP Calls", value: "\(stats?.mcpToolCallCount ?? 0)")
            }
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func statCard(_ title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .macrodexFont(size: 20, weight: .bold)
                .foregroundStyle(MacrodexTheme.accent)
            Text(title)
                .macrodexFont(size: 12, weight: .medium)
                .foregroundStyle(MacrodexTheme.textSecondary)
            if let detail {
                Text(detail)
                    .macrodexFont(size: 10)
                    .foregroundStyle(MacrodexTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .modifier(GlassRectModifier(cornerRadius: 8))
    }

    // MARK: - Section B: Server-Wide Charts

    private var serverChartsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Usage")
                .macrodexFont(size: 14, weight: .semibold)
                .foregroundStyle(MacrodexTheme.textPrimary)

            if let usage = serverUsage {
                if !usage.tokensByThread.isEmpty {
                    tokenUsageChart(usage)
                }

                if !usage.activityByDay.isEmpty {
                    activityChart(usage)
                }

                if !usage.modelUsage.isEmpty {
                    modelBreakdownChart(usage)
                }
            }

            if let rateLimits = server?.rateLimits {
                rateLimitGauge(rateLimits)
            }
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func tokenUsageChart(_ usage: AppServerUsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token Usage by Conversation")
                .macrodexFont(size: 12, weight: .medium)
                .foregroundStyle(MacrodexTheme.textSecondary)

            Chart(Array(usage.tokensByThread.enumerated()), id: \.offset) { _, entry in
                AreaMark(
                    x: .value("Chat", entry.threadTitle),
                    y: .value("Tokens", entry.tokens)
                )
                .foregroundStyle(MacrodexTheme.accent.opacity(0.3))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Chat", entry.threadTitle),
                    y: .value("Tokens", entry.tokens)
                )
                .foregroundStyle(MacrodexTheme.accent)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(MacrodexTheme.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(MacrodexTheme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(MacrodexTheme.textMuted)
                }
            }
            .frame(height: 160)
        }
    }

    private func activityChart(_ usage: AppServerUsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity Timeline")
                .macrodexFont(size: 12, weight: .medium)
                .foregroundStyle(MacrodexTheme.textSecondary)

            Chart(Array(usage.activityByDay.enumerated()), id: \.offset) { _, entry in
                BarMark(
                    x: .value("Date", Date(timeIntervalSince1970: TimeInterval(entry.dateEpoch)), unit: .day),
                    y: .value("Activity", entry.turnCount)
                )
                .foregroundStyle(MacrodexTheme.accent.opacity(0.7))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(MacrodexTheme.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(MacrodexTheme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(MacrodexTheme.textMuted)
                }
            }
            .frame(height: 140)
        }
    }

    private func modelBreakdownChart(_ usage: AppServerUsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Usage")
                .macrodexFont(size: 12, weight: .medium)
                .foregroundStyle(MacrodexTheme.textSecondary)

            Chart(Array(usage.modelUsage.enumerated()), id: \.offset) { _, entry in
                BarMark(
                    x: .value("Count", entry.threadCount),
                    y: .value("Model", entry.model)
                )
                .foregroundStyle(MacrodexTheme.accent.opacity(0.7))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(MacrodexTheme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(MacrodexTheme.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MacrodexTheme.textSecondary)
                }
            }
            .frame(height: CGFloat(max(usage.modelUsage.count * 32, 60)))
        }
    }

    private func rateLimitGauge(_ rateLimits: RateLimitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rate Limits")
                .macrodexFont(size: 12, weight: .medium)
                .foregroundStyle(MacrodexTheme.textSecondary)

            HStack(spacing: 16) {
                if let primary = rateLimits.primary {
                    rateLimitRing(label: "Primary", window: primary)
                }
                if let secondary = rateLimits.secondary {
                    rateLimitRing(label: "Secondary", window: secondary)
                }
            }
        }
    }

    private func rateLimitRing(label: String, window: RateLimitWindow) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(MacrodexTheme.border, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: Double(window.usedPercent) / 100)
                    .stroke(rateLimitColor(percent: Int(window.usedPercent)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(window.usedPercent)%")
                    .macrodexFont(size: 12, weight: .bold)
                    .foregroundStyle(MacrodexTheme.textPrimary)
            }
            .frame(width: 56, height: 56)

            Text(label)
                .macrodexFont(size: 10)
                .foregroundStyle(MacrodexTheme.textMuted)
        }
    }

    private func rateLimitColor(percent: Int) -> Color {
        if percent >= 80 { return MacrodexTheme.danger }
        if percent >= 60 { return MacrodexTheme.warning }
        return MacrodexTheme.accent
    }

    // MARK: - Section C: Server Info

    private var serverInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server")
                .macrodexFont(size: 14, weight: .semibold)
                .foregroundStyle(MacrodexTheme.textPrimary)

            if let server {
                infoRow("Name", value: server.displayName)
                infoRow("Address", value: "\(server.host):\(server.port)")
                infoRow("Mode", value: server.connectionModeLabel)

                HStack(spacing: 6) {
                    Text("Health")
                        .macrodexFont(size: 12)
                        .foregroundStyle(MacrodexTheme.textMuted)
                    Spacer()
                    Circle()
                        .fill(healthColor(server.health))
                        .frame(width: 8, height: 8)
                    Text(healthLabel(server.health))
                        .macrodexFont(size: 12)
                        .foregroundStyle(MacrodexTheme.textSecondary)
                }

                if let account = server.account {
                    accountRow(account)
                }

                if let models = server.availableModels, !models.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Available Models")
                            .macrodexFont(size: 12)
                            .foregroundStyle(MacrodexTheme.textMuted)
                        ForEach(models.prefix(8), id: \.id) { model in
                            Text(model.displayName)
                                .macrodexFont(size: 12)
                                .foregroundStyle(MacrodexTheme.textSecondary)
                        }
                        if models.count > 8 {
                            Text("+\(models.count - 8) more")
                                .macrodexFont(size: 11)
                                .foregroundStyle(MacrodexTheme.textMuted)
                        }
                    }
                }
            }
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .macrodexFont(size: 12)
                .foregroundStyle(MacrodexTheme.textMuted)
            Spacer()
            Text(value)
                .macrodexFont(size: 12)
                .foregroundStyle(MacrodexTheme.textSecondary)
        }
    }

    private func healthColor(_ health: AppServerHealth) -> Color {
        switch health {
        case .connected: return MacrodexTheme.success
        case .connecting: return MacrodexTheme.warning
        case .disconnected, .unresponsive: return MacrodexTheme.danger
        case .unknown: return MacrodexTheme.textMuted
        }
    }

    private func healthLabel(_ health: AppServerHealth) -> String {
        switch health {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .unresponsive: return "Unresponsive"
        case .unknown: return "Unknown"
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack {
            Text("Account")
                .macrodexFont(size: 12)
                .foregroundStyle(MacrodexTheme.textMuted)
            Spacer()
            switch account {
            case .apiKey:
                Text("API Key")
                    .macrodexFont(size: 12)
                    .foregroundStyle(MacrodexTheme.textSecondary)
            case .chatgpt(let email, let planType):
                VStack(alignment: .trailing, spacing: 2) {
                    Text(email)
                        .macrodexFont(size: 12)
                        .foregroundStyle(MacrodexTheme.textSecondary)
                    Text(planTypeLabel(planType))
                        .macrodexFont(size: 10)
                        .foregroundStyle(MacrodexTheme.textMuted)
                }
            }
        }
    }

    private func planTypeLabel(_ planType: PlanType) -> String {
        switch planType {
        case .free: return "Free"
        case .go: return "Go"
        case .plus: return "Plus"
        case .pro: return "Pro"
        case .team: return "Team"
        case .business: return "Business"
        case .enterprise: return "Enterprise"
        case .edu: return "Edu"
        case .unknown: return "Unknown"
        }
    }

    // (Actions are now in the hero section's actionButtonsRow)

    // MARK: - Actions

    private func forkConversation() async {
        guard let threadKey else { return }
        do {
            let sourceKey = await appModel.hydrateThreadPermissions(for: threadKey, appState: appState)
                ?? threadKey
            let newKey = try await appModel.client.forkThread(
                serverId: sourceKey.serverId,
                params: AppThreadLaunchConfig(
                    model: thread?.model,
                    approvalPolicy: appState.launchApprovalPolicy(for: sourceKey),
                    sandbox: appState.launchSandboxMode(for: sourceKey),
                    developerInstructions: AgentRuntimeInstructions.developerInstructions(for: sourceKey),
                    persistExtendedHistory: true
                ).threadForkRequest(threadId: sourceKey.threadId, cwdOverride: thread?.info.cwd)
            )
            appModel.store.setActiveThread(key: newKey)
            await appModel.refreshSnapshot()
            onOpenConversation?(newKey)
        } catch {
            LLog.error("info", "failed to fork thread", error: error)
        }
    }

    private func saveRename() {
        guard let threadKey else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        isRenaming = false
        Task {
            do {
                _ = try await appModel.client.renameThread(
                    serverId: threadKey.serverId,
                    params: AppRenameThreadRequest(threadId: threadKey.threadId, name: title)
                )
                ManualThreadTitleStore.markManuallyRenamed(threadKey)
                await appModel.refreshSnapshot()
            } catch {
                LLog.error("info", "failed to rename thread", error: error)
            }
        }
    }

    private func computeData() {
        if let thread {
            stats = thread.stats
        }
        if let server {
            serverUsage = server.usageStats
        }
    }
}
