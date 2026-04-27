import SwiftUI
import PhotosUI
import UIKit

struct ConversationComposerModalCoordinator<Content: View>: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState

    let snapshot: ConversationComposerSnapshot
    let skills: [SkillMetadata]
    let skillsLoading: Bool
    @Binding var showAttachMenu: Bool
    @Binding var showPhotoPicker: Bool
    @Binding var showCamera: Bool
    @Binding var selectedPhotos: [PhotosPickerItem]
    @Binding var cameraImage: UIImage?
    @Binding var showModelSelector: Bool
    @Binding var showPermissionsSheet: Bool
    @Binding var showSkillsSheet: Bool
    @Binding var showRenamePrompt: Bool
    @Binding var renameCurrentThreadTitle: String
    @Binding var renameDraft: String
    @Binding var slashErrorMessage: String?
    @Binding var showMicPermissionAlert: Bool
    let onOpenSettings: () -> Void
    let onLoadSelectedPhotos: ([PhotosPickerItem]) async -> Void
    let onLoadSkills: (Bool, Bool) async -> Void
    let onRenameThread: (String) async -> Void
    var onScanNutritionLabel: (() -> Void)? = nil
    @ViewBuilder let content: Content

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty {
                    return pending
                }
                return snapshot.threadModel.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.selectedModel = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty {
                    return pending
                }
                return snapshot.threadReasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.reasoningEffort = $0 }
        )
    }

    private var selectedApprovalValue: String {
        appState.approvalPolicy(for: snapshot.threadKey)
    }

    private var selectedSandboxValue: String {
        appState.sandboxMode(for: snapshot.threadKey)
    }

    private var selectedApprovalLabel: String {
        ComposerApprovalOption.allCases.first { $0.wireValue == selectedApprovalValue }?.title ?? "Custom"
    }

    private var selectedApprovalDescription: String {
        ComposerApprovalOption.allCases.first { $0.wireValue == selectedApprovalValue }?.description ?? "This approval policy is managed by the server."
    }

    private var selectedSandboxLabel: String {
        ComposerSandboxOption.allCases.first { $0.wireValue == selectedSandboxValue }?.title ?? "Custom"
    }

    private var selectedSandboxDescription: String {
        ComposerSandboxOption.allCases.first { $0.wireValue == selectedSandboxValue }?.description ?? "This sandbox setting is managed by the server."
    }

    private var currentThread: AppThreadSnapshot? {
        appModel.snapshot?.threads.first(where: { $0.key == snapshot.threadKey })
    }

    private var hasAuthoritativeThreadPermissions: Bool {
        guard let thread = currentThread else { return false }
        return threadPermissionsAreAuthoritative(
            approvalPolicy: thread.effectiveApprovalPolicy,
            sandboxPolicy: thread.effectiveSandboxPolicy
        )
    }

    private var currentApprovalLabel: String {
        guard hasAuthoritativeThreadPermissions else { return "Syncing..." }
        return currentThread?.effectiveApprovalPolicy?.displayTitle ?? "Syncing..."
    }

    private var currentSandboxLabel: String {
        guard hasAuthoritativeThreadPermissions else { return "Syncing..." }
        return currentThread?.effectiveSandboxPolicy?.displayTitle ?? "Syncing..."
    }

    private var usesThreadDefaults: Bool {
        selectedApprovalValue == ComposerApprovalOption.default.wireValue
            && selectedSandboxValue == ComposerSandboxOption.default.wireValue
    }

    var body: some View {
        content
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
                    onScanNutritionLabel: onScanNutritionLabel.map { action in
                        {
                            showAttachMenu = false
                            action()
                        }
                    }
                )
                .presentationDetents([.height(onScanNutritionLabel == nil ? 210 : 274)])
                .presentationDragIndicator(.visible)
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 6, matching: .images)
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                Task { await onLoadSelectedPhotos(items) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView(image: $cameraImage)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showModelSelector) {
                ModelSelectorSheet(
                    models: snapshot.availableModels,
                    selectedModel: selectedModelBinding,
                    reasoningEffort: reasoningEffortBinding
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPermissionsSheet) {
                permissionsSheetContent
                    .task(id: snapshot.threadKey.threadId) {
                        _ = await appModel.hydrateThreadPermissions(for: snapshot.threadKey, appState: appState)
                    }
            }
            .sheet(isPresented: $showSkillsSheet) {
                skillsSheetContent
            }
            .alert("Rename Chat", isPresented: Binding(
                get: { showRenamePrompt },
                set: { isPresented in
                    showRenamePrompt = isPresented
                    if !isPresented {
                        renameCurrentThreadTitle = ""
                        renameDraft = ""
                    }
                }
            )) {
                TextField("New chat title", text: $renameDraft)
                Button("Cancel", role: .cancel) {
                    showRenamePrompt = false
                }
                Button("Rename") {
                    let nextName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !nextName.isEmpty else { return }
                    Task { await onRenameThread(nextName) }
                }
            } message: {
                Text("Current chat title:\n\(renameCurrentThreadTitle)")
            }
            .alert("Slash Command Error", isPresented: Binding(
                get: { slashErrorMessage != nil },
                set: { if !$0 { slashErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { slashErrorMessage = nil }
            } message: {
                Text(slashErrorMessage ?? "Unknown error")
            }
            .alert("Microphone Access", isPresented: $showMicPermissionAlert) {
                Button("Open Settings", action: onOpenSettings)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Microphone permission is required for voice input. Enable it in Settings.")
            }
    }

    @ViewBuilder
    private var permissionsSheetContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Chat permissions")
                                    .foregroundStyle(MacrodexTheme.textPrimary)
                                    .macrodexFont(.headline)
                                Text("Changes apply on your next turn and later turns.")
                                    .foregroundStyle(MacrodexTheme.textMuted)
                                    .macrodexFont(.caption)
                            }
                            Spacer(minLength: 12)
                            Text(usesThreadDefaults ? "Using defaults" : "Custom override")
                                .foregroundStyle(usesThreadDefaults ? MacrodexTheme.textSecondary : MacrodexTheme.accentStrong)
                                .macrodexFont(size: 11, weight: .semibold)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill((usesThreadDefaults ? MacrodexTheme.surfaceLight : MacrodexTheme.accentStrong).opacity(0.16))
                                )
                        }

                        HStack(spacing: 10) {
                            permissionSummaryTile(
                                title: "Next turn",
                                approval: selectedApprovalLabel,
                                sandbox: selectedSandboxLabel,
                                accent: MacrodexTheme.accentStrong
                            )
                            permissionSummaryTile(
                                title: "Current chat",
                                approval: currentApprovalLabel,
                                sandbox: currentSandboxLabel,
                                accent: hasAuthoritativeThreadPermissions ? MacrodexTheme.textSecondary : MacrodexTheme.warning
                            )
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(MacrodexTheme.surface.opacity(0.82))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(MacrodexTheme.border.opacity(0.55), lineWidth: 1)
                    )

                    permissionSection(
                        title: "Approval policy",
                        subtitle: "Choose when the agent asks for approval"
                    ) {
                        permissionDropdown(
                            title: selectedApprovalLabel,
                            detail: selectedApprovalDescription
                        ) {
                            ForEach(ComposerApprovalOption.allCases) { option in
                                permissionMenuItem(
                                    title: option.title,
                                    description: option.description,
                                    isSelected: selectedApprovalValue == option.wireValue
                                ) {
                                    appState.setPermissions(
                                        approvalPolicy: option.wireValue,
                                        sandboxMode: selectedSandboxValue,
                                        for: snapshot.threadKey
                                    )
                                }
                            }
                        }
                    }

                    permissionSection(
                        title: "Sandbox settings",
                        subtitle: "Choose how much the agent can do when running commands"
                    ) {
                        permissionDropdown(
                            title: selectedSandboxLabel,
                            detail: selectedSandboxDescription
                        ) {
                            ForEach(ComposerSandboxOption.allCases) { option in
                                permissionMenuItem(
                                    title: option.title,
                                    description: option.description,
                                    isSelected: selectedSandboxValue == option.wireValue
                                ) {
                                    appState.setPermissions(
                                        approvalPolicy: selectedApprovalValue,
                                        sandboxMode: option.wireValue,
                                        for: snapshot.threadKey
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 28)
            }
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showPermissionsSheet = false }
                        .foregroundColor(MacrodexTheme.accent)
                }
            }
        }
    }

    private func permissionSummaryTile(
        title: String,
        approval: String,
        sandbox: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .foregroundStyle(MacrodexTheme.textSecondary)
                .macrodexFont(size: 11, weight: .semibold)
            VStack(alignment: .leading, spacing: 8) {
                permissionSummaryRow(label: "Approval", value: approval, accent: accent)
                permissionSummaryRow(label: "Sandbox", value: sandbox, accent: accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MacrodexTheme.surfaceLight.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacrodexTheme.border.opacity(0.45), lineWidth: 1)
        )
    }

    private func permissionSummaryRow(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .foregroundStyle(MacrodexTheme.textMuted)
                .macrodexFont(size: 10, weight: .medium)
            Text(value)
                .foregroundStyle(accent)
                .macrodexFont(.subheadline, weight: .semibold)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionSection<SectionContent: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> SectionContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(MacrodexTheme.textPrimary)
                    .macrodexFont(.headline)
                Text(subtitle)
                    .foregroundStyle(MacrodexTheme.textSecondary)
                    .macrodexFont(.caption)
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(MacrodexTheme.surface.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(MacrodexTheme.border.opacity(0.5), lineWidth: 1)
        )
    }

    private func permissionDropdown<MenuContent: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> MenuContent
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(MacrodexTheme.textPrimary)
                        .macrodexFont(size: 14, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(detail)
                        .foregroundStyle(MacrodexTheme.textMuted)
                        .macrodexFont(size: 11)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(MacrodexTheme.textMuted)
                    .imageScale(.small)
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MacrodexTheme.surfaceLight.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(MacrodexTheme.border.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func permissionMenuItem(
        title: String,
        description: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .foregroundStyle(MacrodexTheme.textPrimary)
                        .macrodexFont(size: 14, weight: .semibold)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(MacrodexTheme.accentStrong)
                            .imageScale(.small)
                    }
                }
                Text(description)
                    .foregroundStyle(MacrodexTheme.textMuted)
                    .macrodexFont(size: 11)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    @ViewBuilder
    private var skillsSheetContent: some View {
        NavigationStack {
            Group {
                if skillsLoading {
                    ProgressView().tint(MacrodexTheme.accent)
                } else if skills.isEmpty {
                    Text("No skills available for this workspace")
                        .macrodexFont(.footnote)
                        .foregroundColor(MacrodexTheme.textMuted)
                } else {
                    List {
                        ForEach(skills) { skill in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(skill.name)
                                        .macrodexFont(.subheadline)
                                        .foregroundColor(MacrodexTheme.textPrimary)
                                    Spacer()
                                    if skill.enabled {
                                        Text("enabled")
                                            .macrodexFont(.caption2)
                                            .foregroundColor(MacrodexTheme.accent)
                                    }
                                }
                                Text(skill.description)
                                    .macrodexFont(.caption)
                                    .foregroundColor(MacrodexTheme.textSecondary)
                                Text(skill.path.value)
                                    .macrodexFont(.caption2)
                                    .foregroundColor(MacrodexTheme.textMuted)
                            }
                            .listRowBackground(MacrodexTheme.surface.opacity(0.6))
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reload") { Task { await onLoadSkills(true, true) } }
                        .foregroundColor(MacrodexTheme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSkillsSheet = false }
                        .foregroundColor(MacrodexTheme.accent)
                }
            }
        }
    }
}
