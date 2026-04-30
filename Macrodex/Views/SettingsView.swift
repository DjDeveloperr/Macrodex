import SwiftUI

struct DrawerSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @State private var isWorking = false
    @State private var authError: String?
    @State private var healthKitStatus = codex_healthkit_status_summary() ?? "HealthKit status unavailable"
    @AppStorage("autoArchiveChatsAfter14Days") private var legacyAutoArchiveChatsAfter14Days = true
    @AppStorage("autoArchiveChatsAfterDays") private var autoArchiveChatsAfterDays = 14
    @AppStorage("fastMode") private var fastMode = false

    private var server: AppServerSnapshot? {
        appModel.snapshot?.servers.first(where: \.isLocal) ?? appModel.snapshot?.servers.first
    }

    private var isAutoArchiveEnabled: Binding<Bool> {
        Binding(
            get: { autoArchiveChatsAfterDays > 0 },
            set: { enabled in
                autoArchiveChatsAfterDays = enabled ? max(autoArchiveChatsAfterDays, 14) : 0
                legacyAutoArchiveChatsAfter14Days = enabled
            }
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    accountCard
                    modelDefaultsCard
                    databaseCard
                    healthKitCard
                    chatManagementCard
                    rateLimitsCard
                    sessionCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DrawerMenuButton()
            }
        }
        .task(id: server?.serverId) {
            refreshHealthKitStatus()
            await loadMetadata()
        }
    }

    @ViewBuilder
    private var modelDefaultsCard: some View {
        drawerCard {
            drawerCardHeader(title: "Models", systemImage: "cpu")

            let models = server.map { appModel.availableModels(for: $0.serverId) } ?? []
            let imageModels = models.filter { model in
                model.inputModalities.contains(.image)
                    || ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex"].contains(model.id)
            }

            if models.isEmpty {
                Text("Model metadata is still loading.")
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.textSecondary)
            } else {
                modelDefaultPicker(
                    title: "Default chat",
                    selection: Binding(
                        get: { appState.defaultChatModel },
                        set: { appState.defaultChatModel = $0 }
                    ),
                    models: models
                )

                modelDefaultPicker(
                    title: "With images",
                    selection: Binding(
                        get: { appState.defaultImageModel },
                        set: { appState.defaultImageModel = $0 }
                    ),
                    models: imageModels.isEmpty ? models : imageModels
                )

                Toggle(isOn: $fastMode) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fast service tier")
                            .macrodexFont(.subheadline, weight: .semibold)
                            .foregroundColor(MacrodexTheme.textPrimary)
                        Text("Use fast tier for chat, voice handoff, and AI food search when available.")
                            .macrodexFont(.caption)
                            .foregroundColor(MacrodexTheme.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                Text("Chat defaults use GPT-5.4 Mini. Image chats use GPT-5.4 unless you choose another vision-capable model.")
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var chatManagementCard: some View {
        drawerCard {
            drawerCardHeader(title: "Chats", systemImage: "bubble.left.and.bubble.right")

            Toggle(isOn: isAutoArchiveEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto-archive old chats")
                        .macrodexFont(.subheadline, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textPrimary)
                    Text("Pinned chats stay visible.")
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textSecondary)
                }
            }
            .toggleStyle(.switch)

            if autoArchiveChatsAfterDays > 0 {
                Stepper(value: $autoArchiveChatsAfterDays, in: 1...90, step: 1) {
                    drawerRow("Archive after", value: "\(autoArchiveChatsAfterDays) days")
                }
            }
        }
    }

    @ViewBuilder
    private var databaseCard: some View {
        drawerCard {
            drawerCardHeader(title: "Database", systemImage: "externaldrive.badge.icloud")

            NavigationLink {
                DatabaseBackupsView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "icloud.and.arrow.up")
                        .foregroundColor(MacrodexTheme.textPrimary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Backups & iCloud")
                            .macrodexFont(.subheadline, weight: .semibold)
                            .foregroundColor(MacrodexTheme.textPrimary)
                        Text("Create, restore, reset, and upload database backups.")
                            .macrodexFont(.caption)
                            .foregroundColor(MacrodexTheme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(MacrodexTheme.textMuted)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var healthKitCard: some View {
        drawerCard {
            drawerCardHeader(title: "Health", systemImage: "heart.text.square")

            Text(healthKitStatus)
                .macrodexFont(.caption)
                .foregroundColor(MacrodexTheme.textSecondary)

            Button {
                requestHealthKitAccess()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .foregroundColor(MacrodexTheme.textPrimary)
                    Text("Request HealthKit Access")
                        .macrodexFont(.subheadline, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textPrimary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var accountCard: some View {
        drawerCard {
            drawerCardHeader(title: "Provider", systemImage: "person.crop.circle.badge.checkmark")

            if let server {
                switch server.account {
                case .chatgpt(let email, let planType):
                    drawerRow("Email", value: email.isEmpty ? "Unknown" : email)
                    drawerRow("Plan", value: planType.displayLabel)
                case .apiKey:
                    drawerRow("Account", value: "API key")
                    Text("This device is using a saved provider API key.")
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textSecondary)
                case nil:
                    drawerRow("Status", value: "Not signed in")
                    loginButton
                }
            } else {
                Text("No server connection is available.")
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.textSecondary)
            }

            if let authError {
                Text(authError)
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.danger)
            }
        }
    }

    @ViewBuilder
    private var rateLimitsCard: some View {
        drawerCard {
            drawerCardHeader(title: "Rate Limits", systemImage: "gauge")

            if let rateLimits = server?.rateLimits {
                if let planType = rateLimits.planType {
                    drawerRow("Plan", value: planType.displayLabel)
                }
                if let primary = rateLimits.primary {
                    rateLimitRow(title: "Primary", window: primary)
                }
                if let secondary = rateLimits.secondary {
                    rateLimitRow(title: "Secondary", window: secondary)
                }
                if let credits = rateLimits.credits {
                    drawerRow("Credits", value: creditsSummary(credits))
                }
            } else if server?.account != nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MacrodexTheme.accent)
                    Text("Loading rate limits...")
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textSecondary)
                }
            } else {
                Text("Sign in with ChatGPT to see current limits.")
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var sessionCard: some View {
        drawerCard {
            drawerCardHeader(title: "Session", systemImage: "rectangle.portrait.and.arrow.right")

            if server?.account != nil {
                Button(role: .destructive) {
                    Task { await logout() }
                } label: {
                    HStack {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .tint(MacrodexTheme.textOnAccent)
                        }
                        Text("Log Out")
                            .macrodexFont(.subheadline, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(MacrodexTheme.danger)
                .disabled(isWorking)

                Text("Clears local ChatGPT tokens and any saved API key.")
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.textSecondary)
            } else {
                Text("No active account to log out.")
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.textSecondary)
            }
        }
    }

    private var loginButton: some View {
        Button {
            Task { await loginWithChatGPT() }
        } label: {
            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MacrodexTheme.textOnAccent)
                }
                Text("Sign In with ChatGPT")
                    .macrodexFont(.subheadline, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(MacrodexTheme.accent)
        .disabled(isWorking)
    }

    private func drawerCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(MacrodexTheme.surface.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(MacrodexTheme.border.opacity(0.72), lineWidth: 1)
        )
    }

    private func drawerCardHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(MacrodexTheme.textPrimary)
                .frame(width: 30, height: 30)
                .background(MacrodexTheme.surfaceLight.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title)
                .macrodexFont(.headline, weight: .semibold)
                .foregroundColor(MacrodexTheme.textPrimary)
        }
    }

    private func drawerRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .macrodexFont(.caption)
                .foregroundColor(MacrodexTheme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .macrodexFont(.subheadline, weight: .medium)
                .foregroundColor(MacrodexTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func modelDefaultPicker(
        title: String,
        selection: Binding<String>,
        models: [ModelInfo]
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .macrodexFont(.caption)
                .foregroundColor(MacrodexTheme.textSecondary)
            Spacer(minLength: 12)
            Picker(title, selection: selection) {
                ForEach(models.filter { !$0.id.localizedCaseInsensitiveContains("spark") }) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(MacrodexTheme.textPrimary)
            .foregroundStyle(MacrodexTheme.textPrimary)
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    private func rateLimitRow(title: String, window: RateLimitWindow) -> some View {
        let used = min(max(Int(window.usedPercent), 0), 100)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.textSecondary)
                Spacer()
                Text(rateLimitSummary(window))
                    .macrodexFont(.caption, weight: .semibold)
                    .foregroundColor(rateLimitColor(usedPercent: used))
            }
            ProgressView(value: Double(used), total: 100)
                .tint(rateLimitColor(usedPercent: used))
        }
    }

    private func rateLimitSummary(_ window: RateLimitWindow) -> String {
        let used = min(max(Int(window.usedPercent), 0), 100)
        guard let resetsAt = window.resetsAt else {
            return "\(used)% used"
        }
        return "\(used)% used, \(resetDescription(epochSeconds: resetsAt))"
    }

    private func rateLimitColor(usedPercent: Int) -> Color {
        if usedPercent >= 80 { return MacrodexTheme.danger }
        if usedPercent >= 60 { return MacrodexTheme.warning }
        return MacrodexTheme.accent
    }

    private func resetDescription(epochSeconds: Int64) -> String {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: resetDate, relativeTo: Date())
    }

    private func creditsSummary(_ credits: CreditsSnapshot) -> String {
        if credits.unlimited {
            return "Unlimited"
        }
        if let balance = credits.balance, !balance.isEmpty {
            return balance
        }
        return credits.hasCredits ? "Available" : "None"
    }

    private func loadMetadata() async {
        guard let server else { return }
        await appModel.loadConversationMetadataIfNeeded(serverId: server.serverId)
        await appModel.refreshSnapshot()
    }

    private func refreshHealthKitStatus() {
        healthKitStatus = codex_healthkit_status_summary() ?? "HealthKit status unavailable"
    }

    private func requestHealthKitAccess() {
        codex_healthkit_request_authorization_from_settings()
        healthKitStatus = "HealthKit access prompt opened."
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refreshHealthKitStatus()
        }
    }

    private func loginWithChatGPT() async {
        guard let server, server.isLocal else {
            authError = "ChatGPT login is only available for the local server."
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            authError = nil
            let tokens = try await ChatGPTOAuth.login()
            _ = try await appModel.client.loginAccount(
                serverId: server.serverId,
                params: .chatgptAuthTokens(
                    accessToken: tokens.accessToken,
                    chatgptAccountId: tokens.accountID,
                    chatgptPlanType: tokens.planType
                )
            )
            await appModel.refreshSnapshot()
            await appModel.loadRateLimitsIfNeeded(serverId: server.serverId)
            await appModel.refreshSnapshot()
        } catch ChatGPTOAuthError.cancelled {
            return
        } catch {
            authError = error.localizedDescription
        }
    }

    private func logout() async {
        guard let server, server.isLocal else {
            authError = "Logout is only available for the local server."
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            authError = nil
            try? ChatGPTOAuthTokenStore.shared.clear()
            try? OpenAIApiKeyStore.shared.clear()
            try? GoogleAIApiKeyStore.shared.clear()
            _ = try await appModel.client.logoutAccount(serverId: server.serverId)
            try await appModel.restartLocalServer()
            await appModel.refreshSnapshot()
        } catch {
            authError = error.localizedDescription
        }
    }

}

struct SettingsInfoRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(MacrodexTheme.textPrimary)
                .frame(width: 20)
            Text(title)
                .macrodexFont(.subheadline)
                .foregroundColor(MacrodexTheme.textPrimary)
            Spacer(minLength: 12)
            Text(value)
                .macrodexFont(.caption)
                .foregroundColor(MacrodexTheme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .listRowBackground(MacrodexTheme.surface.opacity(0.6))
    }
}

private extension PlanType {
    var displayLabel: String {
        switch self {
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
}

#if DEBUG
#Preview("Settings") {
    MacrodexPreviewScene(includeBackground: false) {
        DrawerSettingsView()
    }
}
#endif
