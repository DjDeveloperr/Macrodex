import SwiftUI
import UIKit

struct ImageGenerationToolCallView: View {
    let data: ConversationImageGenerationData
    @State private var isDetailPresented = false
    @State private var promptExpanded = false
    @State private var showShareSheet = false
    private let contentFontSize = MacrodexFont.conversationBodyPointSize

    init(
        data: ConversationImageGenerationData,
        externalExpanded: Bool? = nil
    ) {
        self.data = data
    }

    var body: some View {
        Button {
            isDetailPresented = true
        } label: {
            header
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .sheet(isPresented: $isDetailPresented) {
            detailSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(summary)
                .macrodexFont(size: contentFontSize)
                .foregroundColor(MacrodexTheme.textSystem)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows image generation details")
    }

    private var summary: String {
        "Working"
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary)
                        .macrodexFont(.headline, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    imagePreview
                    if let prompt = data.revisedPrompt, !prompt.isEmpty {
                        promptBlock(prompt)
                    }
                }
                .padding(16)
            }
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isDetailPresented = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let bytes = data.imagePNG, let image = UIImage(data: bytes) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(MacrodexTheme.border.opacity(0.4), lineWidth: 0.5)
                )
                .contextMenu {
                    Button {
                        UIPasteboard.general.image = image
                    } label: {
                        Label("Copy Image", systemImage: "doc.on.doc")
                    }
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
                .sheet(isPresented: $showShareSheet) {
                    ShareSheet(items: [image])
                }
        } else if data.isInProgress {
            placeholderTile(icon: "photo.artframe", message: "Generating…", tone: MacrodexTheme.textSecondary)
        } else if data.status == .failed {
            placeholderTile(icon: "exclamationmark.triangle.fill", message: "Image unavailable", tone: MacrodexTheme.danger)
        } else {
            placeholderTile(icon: "photo", message: "Image unavailable", tone: MacrodexTheme.textSecondary)
        }
    }

    private func promptBlock(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("REVISED PROMPT")
                    .macrodexFont(.caption2, weight: .bold)
                    .foregroundColor(MacrodexTheme.textSecondary)
                Spacer()
                if shouldShowPromptToggle(prompt) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            promptExpanded.toggle()
                        }
                    } label: {
                        Text(promptExpanded ? "Collapse" : "Expand")
                            .macrodexFont(.caption2, weight: .medium)
                            .foregroundColor(MacrodexTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(promptExpanded ? prompt : collapsedPreview(prompt))
                .macrodexFont(size: contentFontSize)
                .foregroundColor(MacrodexTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MacrodexTheme.codeBackground.opacity(0.82))
                )
        }
    }

    private func placeholderTile(icon: String, message: String, tone: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .macrodexFont(size: 24, weight: .medium)
                .foregroundColor(tone)
            Text(message)
                .macrodexFont(.caption)
                .foregroundColor(tone)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MacrodexTheme.codeBackground.opacity(0.82))
        )
    }

    private func shouldShowPromptToggle(_ prompt: String) -> Bool {
        prompt.count > 220 || prompt.split(separator: "\n", omittingEmptySubsequences: false).count > 4
    }

    private func collapsedPreview(_ text: String) -> String {
        let limit = 220
        if text.count <= limit { return text }
        let head = String(text.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return head + "…"
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
