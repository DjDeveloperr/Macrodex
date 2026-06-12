import SwiftUI
import UIKit

struct ConversationComposerEntryRowView: View {
    private enum Metrics {
        static let controlSize: CGFloat = 40
        static let inlineControlSize: CGFloat = 36
        static let inputMinHeight: CGFloat = 40
    }

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
        HStack(alignment: .bottom, spacing: 8) {
            if !voiceManager.isRecording && !voiceManager.isTranscribing && (!isTurnActive || keepsAttachmentButtonVisible) {
                Button {
                    showAttachMenu = true
                } label: {
                    Image(systemName: "plus")
                        .font(MacrodexFont.styled(size: 18, weight: .semibold))
                        .foregroundColor(MacrodexTheme.textPrimary)
                        .frame(width: Metrics.controlSize, height: Metrics.controlSize)
                        .modifier(GlassCircleModifier())
                }
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Add attachment")
                .macrodexSimDeckElement(
                    "Add attachment",
                    id: "macrodex.composer.add-attachment",
                    metadata: ["kind": "composer-control"]
                )
            }

            HStack(alignment: .bottom, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ConversationComposerTextView(
                        text: $inputText,
                        isFocused: $isComposerFocused,
                        onPasteImage: onPasteImage,
                        onCommandEnter: onSendText
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
                .macrodexSimDeckElement(
                    "Composer text input",
                    id: "macrodex.composer.text-input",
                    metadata: ["kind": "composer-input"]
                )

                if isFoodSearchMode && hasText {
                    Button {
                        inputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(MacrodexFont.styled(size: 22))
                            .foregroundColor(MacrodexTheme.textSecondary)
                            .frame(width: Metrics.inlineControlSize, height: Metrics.inlineControlSize)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                    .accessibilityLabel("Clear food search")
                } else if canSend {
                    Button(action: onSendText) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(MacrodexFont.styled(size: 22))
                            .foregroundColor(MacrodexTheme.accent)
                            .frame(width: Metrics.inlineControlSize, height: Metrics.inlineControlSize)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                    .accessibilityLabel("Send message")
                    .macrodexSimDeckElement(
                        "Send message",
                        id: "macrodex.composer.send",
                        metadata: ["kind": "composer-control"]
                    )
                } else if voiceManager.isRecording {
                    AudioWaveformView(level: voiceManager.audioLevel)
                        .frame(width: 48, height: 20)

                    Button(action: onStopRecording) {
                        Image(systemName: "stop.circle.fill")
                            .font(MacrodexFont.styled(size: 22))
                            .foregroundColor(MacrodexTheme.accentStrong)
                            .frame(width: Metrics.inlineControlSize, height: Metrics.inlineControlSize)
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
                            .frame(width: Metrics.inlineControlSize, height: Metrics.inlineControlSize)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                    .accessibilityLabel("Start voice input")
                    .macrodexSimDeckElement(
                        "Start voice input",
                        id: "macrodex.composer.voice",
                        metadata: ["kind": "composer-control"]
                    )
                }
            }
            .frame(minHeight: Metrics.inputMinHeight)
            .modifier(GlassRoundedRectModifier(cornerRadius: 20))
            .macrodexSimDeckElement(
                "Composer input",
                id: "macrodex.composer.input",
                metadata: ["kind": "composer-input-row"]
            )

            if isTurnActive {
                Button(action: onInterrupt) {
                    Image(systemName: "stop.fill")
                        .font(MacrodexFont.styled(size: 13, weight: .semibold))
                        .foregroundColor(MacrodexTheme.textPrimary)
                        .frame(width: Metrics.controlSize, height: Metrics.controlSize)
                        .modifier(GlassCircleModifier())
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityLabel("Stop response")
            } else if showsFoodSearchButton && !voiceManager.isRecording && !voiceManager.isTranscribing {
                Button(action: onToggleFoodSearchMode) {
                    Image(systemName: "magnifyingglass")
                        .font(MacrodexFont.styled(size: 16, weight: .semibold))
                        .foregroundColor(isFoodSearchMode ? MacrodexTheme.accent : MacrodexTheme.textPrimary)
                        .frame(width: Metrics.controlSize, height: Metrics.controlSize)
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
        .macrodexSimDeckElement(
            "Composer controls",
            id: "macrodex.composer.controls",
            metadata: ["kind": "composer-controls"]
        )
    }
}
