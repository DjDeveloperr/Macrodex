import SwiftUI
import UIKit

struct ConversationComposerContentView: View {
    let attachedImages: [UIImage]
    let collaborationMode: AppModeKind
    let activePlanProgress: AppPlanProgressSnapshot?
    let pendingUserInputRequest: PendingUserInputRequest?
    let hasPendingPlanImplementation: Bool
    let activeTaskSummary: ConversationActiveTaskSummary?
    let queuedFollowUps: [AppQueuedFollowUpPreview]
    let rateLimits: RateLimitSnapshot?
    let contextPercent: Int64?
    let isTurnActive: Bool
    let showModeChip: Bool
    let voiceManager: VoiceTranscriptionManager
    let isFoodSearchMode: Bool
    let showsFoodSearchButton: Bool
    let keepsAttachmentButtonVisible: Bool
    @Binding var showAttachMenu: Bool
    let onRemoveAttachment: (Int) -> Void
    let onRespondToPendingUserInput: ([String: [String]]) -> Void
    let onImplementPlan: () -> Void
    let onDismissPlanImplementation: () -> Void
    let onSteerQueuedFollowUp: (AppQueuedFollowUpPreview) -> Void
    let onDeleteQueuedFollowUp: (AppQueuedFollowUpPreview) -> Void
    let onPasteImage: (UIImage) -> Void
    let onToggleFoodSearchMode: () -> Void
    let onOpenModePicker: () -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void
    @Binding var inputText: String
    @Binding var isComposerFocused: Bool

    init(
        attachedImages: [UIImage],
        collaborationMode: AppModeKind,
        activePlanProgress: AppPlanProgressSnapshot?,
        pendingUserInputRequest: PendingUserInputRequest?,
        hasPendingPlanImplementation: Bool = false,
        activeTaskSummary: ConversationActiveTaskSummary?,
        queuedFollowUps: [AppQueuedFollowUpPreview],
        rateLimits: RateLimitSnapshot?,
        contextPercent: Int64?,
        isTurnActive: Bool,
        showModeChip: Bool = true,
        voiceManager: VoiceTranscriptionManager,
        isFoodSearchMode: Bool = false,
        showsFoodSearchButton: Bool = false,
        keepsAttachmentButtonVisible: Bool = false,
        showAttachMenu: Binding<Bool>,
        onRemoveAttachment: @escaping (Int) -> Void,
        onRespondToPendingUserInput: @escaping ([String: [String]]) -> Void,
        onImplementPlan: @escaping () -> Void = {},
        onDismissPlanImplementation: @escaping () -> Void = {},
        onSteerQueuedFollowUp: @escaping (AppQueuedFollowUpPreview) -> Void,
        onDeleteQueuedFollowUp: @escaping (AppQueuedFollowUpPreview) -> Void,
        onPasteImage: @escaping (UIImage) -> Void,
        onToggleFoodSearchMode: @escaping () -> Void = {},
        onOpenModePicker: @escaping () -> Void,
        onSendText: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        inputText: Binding<String>,
        isComposerFocused: Binding<Bool>
    ) {
        self.attachedImages = attachedImages
        self.collaborationMode = collaborationMode
        self.activePlanProgress = activePlanProgress
        self.pendingUserInputRequest = pendingUserInputRequest
        self.hasPendingPlanImplementation = hasPendingPlanImplementation
        self.activeTaskSummary = activeTaskSummary
        self.queuedFollowUps = queuedFollowUps
        self.rateLimits = rateLimits
        self.contextPercent = contextPercent
        self.isTurnActive = isTurnActive
        self.showModeChip = showModeChip
        self.voiceManager = voiceManager
        self.isFoodSearchMode = isFoodSearchMode
        self.showsFoodSearchButton = showsFoodSearchButton
        self.keepsAttachmentButtonVisible = keepsAttachmentButtonVisible
        _showAttachMenu = showAttachMenu
        self.onRemoveAttachment = onRemoveAttachment
        self.onRespondToPendingUserInput = onRespondToPendingUserInput
        self.onImplementPlan = onImplementPlan
        self.onDismissPlanImplementation = onDismissPlanImplementation
        self.onSteerQueuedFollowUp = onSteerQueuedFollowUp
        self.onDeleteQueuedFollowUp = onDeleteQueuedFollowUp
        self.onPasteImage = onPasteImage
        self.onToggleFoodSearchMode = onToggleFoodSearchMode
        self.onOpenModePicker = onOpenModePicker
        self.onSendText = onSendText
        self.onStopRecording = onStopRecording
        self.onStartRecording = onStartRecording
        self.onInterrupt = onInterrupt
        _inputText = inputText
        _isComposerFocused = isComposerFocused
    }

    var body: some View {
        VStack(spacing: 0) {
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(attachedImages.enumerated()), id: \.offset) { index, image in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button {
                                    onRemoveAttachment(index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .macrodexFont(.body)
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.6)))
                                }
                                .offset(x: 4, y: -4)
                                .accessibilityLabel("Remove attached image")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            VStack(alignment: .trailing, spacing: 0) {
                if let activeTaskSummary {
                    ConversationComposerActiveTaskRowView(summary: activeTaskSummary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if let pendingUserInputRequest {
                    PendingUserInputPromptView(request: pendingUserInputRequest, onSubmit: onRespondToPendingUserInput)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if !queuedFollowUps.isEmpty {
                    QueuedFollowUpsPreviewView(
                        previews: queuedFollowUps,
                        onSteer: onSteerQueuedFollowUp,
                        onDelete: onDeleteQueuedFollowUp
                    )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                ConversationComposerEntryRowView(
                    showAttachMenu: $showAttachMenu,
                    inputText: $inputText,
                    isComposerFocused: $isComposerFocused,
                    voiceManager: voiceManager,
                    isTurnActive: isTurnActive,
                    hasAttachment: !attachedImages.isEmpty,
                    isFoodSearchMode: isFoodSearchMode,
                    showsFoodSearchButton: showsFoodSearchButton,
                    keepsAttachmentButtonVisible: keepsAttachmentButtonVisible,
                    onPasteImage: onPasteImage,
                    onToggleFoodSearchMode: onToggleFoodSearchMode,
                    onSendText: onSendText,
                    onStopRecording: onStopRecording,
                    onStartRecording: onStartRecording,
                    onInterrupt: onInterrupt
                )

            }
        }
    }
}

struct ConversationComposerModeChip: View {
    let mode: AppModeKind
    let onTap: () -> Void

    private var label: String {
        switch mode {
        case .plan:
            return "Plan"
        case .`default`:
            return "Default"
        }
    }

    private var foreground: Color {
        mode == .plan ? Color.black : MacrodexTheme.textPrimary
    }

    private var background: Color {
        mode == .plan ? MacrodexTheme.accent : MacrodexTheme.surfaceLight
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(label)
                    .macrodexFont(.caption, weight: .semibold)
                Image(systemName: "chevron.up.chevron.down")
                    .macrodexFont(size: 10, weight: .semibold)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(background))
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationComposerPlanProgressView: View {
    let progress: AppPlanProgressSnapshot

    private var completedCount: Int {
        progress.plan.filter { $0.status == .completed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                    .macrodexFont(size: 12, weight: .semibold)
                    .foregroundStyle(MacrodexTheme.accent)
                Text("Plan Progress")
                    .macrodexFont(.caption, weight: .semibold)
                    .foregroundStyle(MacrodexTheme.textPrimary)
                Text("\(completedCount)/\(progress.plan.count)")
                    .macrodexMonoFont(size: 11, weight: .semibold)
                    .foregroundStyle(MacrodexTheme.textSecondary)
            }

            if let explanation = progress.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explanation.isEmpty {
                Text(explanation)
                    .macrodexFont(.caption)
                    .foregroundStyle(MacrodexTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(progress.plan.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: iconName(for: step.status))
                            .macrodexFont(size: 11, weight: .semibold)
                            .foregroundStyle(iconColor(for: step.status))
                            .padding(.top, 2)
                        Text("\(index + 1).")
                            .macrodexMonoFont(size: 11, weight: .semibold)
                            .foregroundStyle(MacrodexTheme.textMuted)
                            .padding(.top, 1)
                        Text(step.step)
                            .macrodexFont(.caption)
                            .foregroundStyle(MacrodexTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MacrodexTheme.codeBackground.opacity(0.92))
        )
    }

    private func iconName(for status: AppPlanStepStatus) -> String {
        switch status {
        case .completed:
            return "checkmark.circle.fill"
        case .inProgress:
            return "circle.fill"
        case .pending:
            return "circle"
        }
    }

    private func iconColor(for status: AppPlanStepStatus) -> Color {
        switch status {
        case .completed:
            return MacrodexTheme.success
        case .inProgress:
            return MacrodexTheme.warning
        case .pending:
            return MacrodexTheme.textMuted
        }
    }
}

private struct ConversationComposerActiveTaskRowView: View {
    let summary: ConversationActiveTaskSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .macrodexFont(size: 11, weight: .semibold)
                .foregroundColor(MacrodexTheme.warning)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.title)
                        .macrodexFont(.caption, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textPrimary)

                    Text(summary.progressLabel)
                        .macrodexMonoFont(size: 10, weight: .semibold)
                        .foregroundColor(MacrodexTheme.warning)
                }

                Text(summary.detail)
                    .macrodexFont(.caption2)
                    .foregroundColor(MacrodexTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacrodexTheme.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
