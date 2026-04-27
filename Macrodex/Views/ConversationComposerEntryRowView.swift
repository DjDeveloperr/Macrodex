import SwiftUI
import UIKit

struct ConversationComposerEntryRowView: View {
    @Binding var showAttachMenu: Bool
    @Binding var inputText: String
    @Binding var isComposerFocused: Bool
    let voiceManager: VoiceTranscriptionManager
    let isTurnActive: Bool
    let hasAttachment: Bool
    let isFoodSearchMode: Bool
    let showsFoodSearchButton: Bool
    let keepsAttachmentButtonVisible: Bool
    let onPasteImage: (UIImage) -> Void
    let onToggleFoodSearchMode: () -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void

    init(
        showAttachMenu: Binding<Bool>,
        inputText: Binding<String>,
        isComposerFocused: Binding<Bool>,
        voiceManager: VoiceTranscriptionManager,
        isTurnActive: Bool,
        hasAttachment: Bool,
        isFoodSearchMode: Bool = false,
        showsFoodSearchButton: Bool = false,
        keepsAttachmentButtonVisible: Bool = false,
        onPasteImage: @escaping (UIImage) -> Void,
        onToggleFoodSearchMode: @escaping () -> Void = {},
        onSendText: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onInterrupt: @escaping () -> Void
    ) {
        _showAttachMenu = showAttachMenu
        _inputText = inputText
        _isComposerFocused = isComposerFocused
        self.voiceManager = voiceManager
        self.isTurnActive = isTurnActive
        self.hasAttachment = hasAttachment
        self.isFoodSearchMode = isFoodSearchMode
        self.showsFoodSearchButton = showsFoodSearchButton
        self.keepsAttachmentButtonVisible = keepsAttachmentButtonVisible
        self.onPasteImage = onPasteImage
        self.onToggleFoodSearchMode = onToggleFoodSearchMode
        self.onSendText = onSendText
        self.onStopRecording = onStopRecording
        self.onStartRecording = onStartRecording
        self.onInterrupt = onInterrupt
    }

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSend: Bool {
        hasText || hasAttachment
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !voiceManager.isRecording && !voiceManager.isTranscribing && (!isTurnActive || keepsAttachmentButtonVisible) {
                Button {
                    showAttachMenu = true
                } label: {
                    Image(systemName: "plus")
                        .font(MacrodexFont.styled(size: 17, weight: .semibold))
                        .foregroundColor(MacrodexTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .modifier(GlassCircleModifier())
                }
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Add attachment")
            }

            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ConversationComposerTextView(
                        text: $inputText,
                        isFocused: $isComposerFocused,
                        onPasteImage: onPasteImage
                    )

                    if inputText.isEmpty {
                        Text(isFoodSearchMode ? "Search foods..." : "Ask anything...")
                            .font(.system(size: 17))
                            .foregroundColor(MacrodexTheme.textMuted)
                            .padding(.leading, 16)
                            .padding(.top, 10)
                            .allowsHitTesting(false)
                    }
                }

                if isFoodSearchMode && hasText {
                    Button {
                        inputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(MacrodexFont.styled(size: 22))
                            .foregroundColor(MacrodexTheme.textSecondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                    .accessibilityLabel("Clear food search")
                } else if canSend {
                    Button(action: onSendText) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(MacrodexFont.styled(size: 22))
                            .foregroundColor(MacrodexTheme.accent)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                    .accessibilityLabel("Send message")
                } else if voiceManager.isRecording {
                    AudioWaveformView(level: voiceManager.audioLevel)
                        .frame(width: 48, height: 20)

                    Button(action: onStopRecording) {
                        Image(systemName: "stop.circle.fill")
                            .font(MacrodexFont.styled(size: 22))
                            .foregroundColor(MacrodexTheme.accentStrong)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                    .accessibilityLabel("Stop recording")
                } else if voiceManager.isTranscribing {
                    ProgressView()
                        .tint(MacrodexTheme.accent)
                        .padding(.trailing, 8)
                        .accessibilityLabel("Transcribing audio")
                } else {
                    Button(action: onStartRecording) {
                        Image(systemName: "mic.fill")
                            .font(MacrodexFont.styled(size: 15))
                            .foregroundColor(MacrodexTheme.textSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                    .accessibilityLabel("Start voice input")
                }
            }
            .frame(minHeight: 36)
            .modifier(GlassRoundedRectModifier(cornerRadius: 20))

            if isTurnActive {
                Button(action: onInterrupt) {
                    Image(systemName: "stop.fill")
                        .font(MacrodexFont.styled(size: 13, weight: .semibold))
                        .foregroundColor(MacrodexTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .modifier(GlassCircleModifier())
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityLabel("Stop response")
            } else if showsFoodSearchButton && !voiceManager.isRecording && !voiceManager.isTranscribing {
                Button(action: onToggleFoodSearchMode) {
                    Image(systemName: "magnifyingglass")
                        .font(MacrodexFont.styled(size: 15, weight: .semibold))
                        .foregroundColor(isFoodSearchMode ? MacrodexTheme.accent : MacrodexTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .modifier(GlassCircleModifier())
                }
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel(isFoodSearchMode ? "Close food search" : "Search foods")
            }

        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: isTurnActive)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}
