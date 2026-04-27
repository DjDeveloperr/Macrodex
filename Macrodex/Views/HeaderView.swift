import SafariServices
import SwiftUI

struct HeaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot
    @State private var pulsing = false
    @AppStorage("fastMode") private var fastMode = false

    private var server: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: thread.key.serverId)
    }

    private var availableModels: [ModelInfo] {
        appModel.availableModels(for: thread.key.serverId)
    }

    private var headerPermissionPreset: AppThreadPermissionPreset {
        let approval = appState.launchApprovalPolicy(for: thread.key) ?? thread.effectiveApprovalPolicy
        let sandbox = appState.turnSandboxPolicy(for: thread.key) ?? thread.effectiveSandboxPolicy
        return threadPermissionPreset(approvalPolicy: approval, sandboxPolicy: sandbox)
    }

    var body: some View {
        Button {
            appState.showModelSelector.toggle()
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                        .opacity(shouldPulse ? (pulsing ? 0.3 : 1.0) : 1.0)
                        .animation(shouldPulse ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulsing)
                        .onChange(of: shouldPulse) { _, pulse in
                            pulsing = pulse
                        }
                    if fastMode {
                        Image(systemName: "bolt.fill")
                            .font(MacrodexFont.styled(size: 10, weight: .semibold))
                            .foregroundColor(MacrodexTheme.warning)
                    }
                    Text(sessionModelLabel)
                        .foregroundColor(MacrodexTheme.textPrimary)
                    Text(sessionReasoningLabel)
                        .foregroundColor(MacrodexTheme.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(MacrodexFont.styled(size: 10, weight: .semibold))
                        .foregroundColor(MacrodexTheme.textSecondary)
                        .rotationEffect(.degrees(appState.showModelSelector ? 180 : 0))
                }
                .font(MacrodexFont.styled(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

                HStack(spacing: 6) {
                    Text(sessionDirectoryLabel)
                        .font(MacrodexFont.styled(size: 11, weight: .semibold))
                        .foregroundColor(MacrodexTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if thread.collaborationMode == .plan {
                        Text("plan")
                            .font(MacrodexFont.styled(size: 11, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MacrodexTheme.accent)
                            .clipShape(Capsule())
                    }

                    if headerPermissionPreset == .fullAccess {
                        Image(systemName: "lock.open.fill")
                            .font(MacrodexFont.styled(size: 10, weight: .semibold))
                            .foregroundColor(MacrodexTheme.danger)
                    }

                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: 240)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("header.modelPickerButton")
        .popover(
            isPresented: Binding(
                get: { appState.showModelSelector },
                set: { appState.showModelSelector = $0 }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            ConversationModelPickerPanel(thread: thread)
                .presentationCompactAdaptation(.popover)
        }
        .task(id: thread.key) {
            await loadModelsIfNeeded()
        }
    }

    private var shouldPulse: Bool {
        guard let transportState = server?.transportState else { return false }
        return transportState == .connecting || transportState == .unresponsive
    }

    private var statusDotColor: Color {
        guard let server else {
            return MacrodexTheme.textMuted
        }
        switch server.transportState {
        case .connecting, .unresponsive:
            return .orange
        case .connected:
            if server.isLocal {
                switch server.account {
                case .chatgpt?, .apiKey?:
                    return MacrodexTheme.success
                case nil:
                    return MacrodexTheme.danger
                }
            }
            return server.account == nil ? .orange : MacrodexTheme.success
        case .disconnected:
            return MacrodexTheme.danger
        case .unknown:
            return MacrodexTheme.textMuted
        }
    }

    private var sessionModelLabel: String {
        let pendingModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingModel.isEmpty { return pendingModel }

        let threadModel = (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !threadModel.isEmpty { return threadModel }

        return "macrodex"
    }

    private var sessionReasoningLabel: String {
        let pendingReasoning = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingReasoning.isEmpty { return pendingReasoning }

        let threadReasoning = thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadReasoning.isEmpty { return threadReasoning }

        // Fall back to the model's default reasoning effort from the loaded model list.
        let currentModel = (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let model = availableModels.first(where: { $0.model == currentModel }),
           !model.defaultReasoningEffort.wireValue.isEmpty {
            return model.defaultReasoningEffort.wireValue
        }

        return "default"
    }

    private var sessionDirectoryLabel: String {
        let currentDirectory = (thread.info.cwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentDirectory.isEmpty {
            return abbreviateHomePath(currentDirectory)
        }

        return "~"
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.selectedModel = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.reasoningEffort = $0 }
        )
    }

    private func loadModelsIfNeeded() async {
        await appModel.loadConversationMetadataIfNeeded(serverId: thread.key.serverId)
    }
}

struct ConversationModelPickerPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot

    private var availableModels: [ModelInfo] {
        appModel.availableModels(for: thread.key.serverId)
    }

    var body: some View {
        InlineModelSelectorView(
            models: availableModels,
            selectedModel: selectedModelBinding,
            reasoningEffort: reasoningEffortBinding,
            threadKey: thread.key,
            onDismiss: {
                appState.showModelSelector = false
            }
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .task(id: thread.key) {
            await appModel.loadConversationMetadataIfNeeded(serverId: thread.key.serverId)
        }
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.selectedModel = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.reasoningEffort = $0 }
        )
    }
}

struct ConversationToolbarControls: View {
    enum Control {
        case modelSettings
    }

    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot
    let control: Control
    @State private var showModelSelector = false

    private var server: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: thread.key.serverId)
    }

    var body: some View {
        Group {
            switch control {
            case .modelSettings:
                modelSettingsButton
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .sheet(isPresented: $showModelSelector) {
            ModelSelectorSheet(
                models: server?.availableModels ?? [],
                selectedModel: selectedModelBinding,
                reasoningEffort: reasoningEffortBinding
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var modelSettingsButton: some View {
        Button {
            showModelSelector = true
        } label: {
            Image(systemName: "gearshape")
                .font(MacrodexFont.styled(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .accessibilityIdentifier("header.modelSettingsButton")
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.selectedModel = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.reasoningEffort = $0 }
        )
    }
}

private struct RemoteAuthSession: Identifiable {
    let id = UUID()
    let url: URL
}

struct InlineModelSelectorView: View {
    let models: [ModelInfo]
    @Binding var selectedModel: String
    @Binding var reasoningEffort: String
    var threadKey: ThreadKey?
    @AppStorage("fastMode") private var fastMode = false
    var onDismiss: () -> Void

    private var currentModel: ModelInfo? {
        if let match = models.first(where: { $0.id == selectedModel }) {
            return match
        }
        // When shown from the home composer, `selectedModel` may be empty
        // because the user hasn't picked yet. Fall back to the default
        // model so the reasoning effort row has something to render.
        return models.first(where: { $0.isDefault }) ?? models.first
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(models) { model in
                        Button {
                            selectedModel = model.id
                            reasoningEffort = model.defaultReasoningEffort.wireValue
                            // Auto-dismiss only in the thread-scoped popover
                            // context. In the home sheet (no thread yet) we
                            // let the user pick a model AND change plan or
                            // permissions before hitting Done.
                            if threadKey != nil { onDismiss() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.displayName)
                                            .macrodexFont(.footnote)
                                            .foregroundColor(MacrodexTheme.textPrimary)
                                        if model.isDefault {
                                            Text("default")
                                                .macrodexFont(.caption2, weight: .medium)
                                                .foregroundColor(MacrodexTheme.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(MacrodexTheme.accent.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(model.description)
                                        .macrodexFont(.caption2)
                                        .foregroundColor(MacrodexTheme.textSecondary)
                                }
                                Spacer()
                                if model.id == selectedModel {
                                    Image(systemName: "checkmark")
                                        .macrodexFont(size: 12, weight: .medium)
                                        .foregroundColor(MacrodexTheme.accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        if model.id != models.last?.id {
                            Divider().background(MacrodexTheme.separator).padding(.leading, 16)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            if let info = currentModel, !info.supportedReasoningEfforts.isEmpty {
                Divider().background(MacrodexTheme.separator).padding(.horizontal, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(info.supportedReasoningEfforts) { effort in
                            Button {
                                reasoningEffort = effort.reasoningEffort.wireValue
                                if threadKey != nil { onDismiss() }
                            } label: {
                                Text(effort.reasoningEffort.wireValue)
                                    .macrodexFont(.caption2, weight: .medium)
                                    .foregroundColor(effort.reasoningEffort.wireValue == reasoningEffort ? MacrodexTheme.textOnAccent : MacrodexTheme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(effort.reasoningEffort.wireValue == reasoningEffort ? MacrodexTheme.accent : MacrodexTheme.surfaceLight)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            Divider().background(MacrodexTheme.separator).padding(.horizontal, 12)

            HStack(spacing: 6) {
                Button {
                    fastMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .macrodexFont(size: 9, weight: .semibold)
                        Text("Fast")
                            .macrodexFont(.caption2, weight: .medium)
                    }
                    .foregroundColor(fastMode ? MacrodexTheme.textOnAccent : MacrodexTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(fastMode ? MacrodexTheme.warning : MacrodexTheme.surfaceLight)
                    .clipShape(Capsule())
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct ModelSelectorSheet: View {
    let models: [ModelInfo]
    @Binding var selectedModel: String
    @Binding var reasoningEffort: String
    @AppStorage("fastMode") private var fastMode = false

    private var currentModel: ModelInfo? {
        if let match = models.first(where: { $0.id == selectedModel }) {
            return match
        }
        return models.first(where: { $0.isDefault }) ?? models.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            ForEach(models) { model in
                Button {
                    selectedModel = model.id
                    reasoningEffort = model.defaultReasoningEffort.wireValue
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.displayName)
                                    .macrodexFont(.footnote)
                                    .foregroundColor(MacrodexTheme.textPrimary)
                                if model.isDefault {
                                    Text("default")
                                        .macrodexFont(.caption2, weight: .medium)
                                        .foregroundColor(MacrodexTheme.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(MacrodexTheme.accent.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(model.description)
                                .macrodexFont(.caption2)
                                .foregroundColor(MacrodexTheme.textSecondary)
                        }
                        Spacer()
                        if model.id == selectedModel {
                            Image(systemName: "checkmark")
                                .macrodexFont(size: 12, weight: .medium)
                                .foregroundColor(MacrodexTheme.accent)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                Divider().background(MacrodexTheme.separator).padding(.leading, 20)
            }

            if let info = currentModel, !info.supportedReasoningEfforts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(info.supportedReasoningEfforts) { effort in
                            Button {
                                reasoningEffort = effort.reasoningEffort.wireValue
                            } label: {
                                Text(effort.reasoningEffort.wireValue)
                                    .macrodexFont(.caption2, weight: .medium)
                                    .foregroundColor(effort.reasoningEffort.wireValue == reasoningEffort ? MacrodexTheme.textOnAccent : MacrodexTheme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(effort.reasoningEffort.wireValue == reasoningEffort ? MacrodexTheme.accent : MacrodexTheme.surfaceLight)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }

            Divider().background(MacrodexTheme.separator).padding(.leading, 20)

            HStack(spacing: 6) {
                Button {
                    fastMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .macrodexFont(size: 9, weight: .semibold)
                        Text("Fast")
                            .macrodexFont(.caption2, weight: .medium)
                    }
                    .foregroundColor(fastMode ? MacrodexTheme.textOnAccent : MacrodexTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(fastMode ? MacrodexTheme.warning : MacrodexTheme.surfaceLight)
                    .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            }
        }
        .padding(.top, 20)
        .background(.ultraThinMaterial)
    }
}

#if DEBUG
#Preview("Header") {
    let appModel = MacrodexPreviewData.makeConversationAppModel()
    MacrodexPreviewScene(appModel: appModel) {
        HeaderView(thread: appModel.snapshot!.threads[0])
    }
}
#endif
