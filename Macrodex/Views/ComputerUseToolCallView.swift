import SwiftUI
import UIKit

struct ComputerUseToolCallView: View {
    let data: ConversationMcpToolCallData
    let view: ComputerUseView
    @State private var isDetailPresented = false
    @State private var a11yExpanded = false
    private let contentFontSize = MacrodexFont.conversationBodyPointSize

    init(
        data: ConversationMcpToolCallData,
        view: ComputerUseView,
        externalExpanded: Bool? = nil,
        onExpandedChange: ((Bool) -> Void)? = nil
    ) {
        self.data = data
        self.view = view
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
            Text("Working")
                .macrodexFont(size: contentFontSize)
                .foregroundColor(MacrodexTheme.textSystem)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows tool details")
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Working")
                            .macrodexFont(.headline, weight: .semibold)
                            .foregroundColor(MacrodexTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(view.summary)
                            .macrodexFont(.callout)
                            .foregroundColor(MacrodexTheme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let screenshot = view.screenshotPng {
                        screenshotPreview(screenshot)
                    }
                    if let error = data.errorMessage, !error.isEmpty {
                        errorBlock(error)
                    }
                    if let text = view.accessibilityText, !text.isEmpty {
                        accessibilityBlock(text)
                    }
                }
                .padding(16)
            }
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Tool Details")
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
    private func screenshotPreview(_ data: Data) -> some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(MacrodexTheme.border.opacity(0.4), lineWidth: 0.5)
                )
        } else {
            placeholderTile("Screenshot unavailable", tone: MacrodexTheme.textSecondary)
        }
    }

    private func errorBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ERROR")
                .macrodexFont(.caption2, weight: .bold)
                .foregroundColor(MacrodexTheme.danger)
            Text(message)
                .macrodexFont(size: contentFontSize)
                .foregroundColor(MacrodexTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func accessibilityBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("ACCESSIBILITY TREE")
                    .macrodexFont(.caption2, weight: .bold)
                    .foregroundColor(MacrodexTheme.textSecondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        a11yExpanded.toggle()
                    }
                } label: {
                    Text(a11yExpanded ? "Collapse" : "Expand")
                        .macrodexFont(.caption2, weight: .medium)
                        .foregroundColor(MacrodexTheme.accent)
                }
                .buttonStyle(.plain)
            }

            Text(a11yExpanded ? text : collapsedPreview(text))
                .font(.system(size: 11, design: .monospaced))
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

    private func placeholderTile(_ message: String, tone: Color) -> some View {
        Text(message)
            .macrodexFont(.caption)
            .foregroundColor(tone)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MacrodexTheme.codeBackground.opacity(0.82))
            )
    }

    private func collapsedPreview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= 6 { return text }
        let head = lines.prefix(6).joined(separator: "\n")
        return "\(head)\n… (\(lines.count - 6) more lines)"
    }

}
