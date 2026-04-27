import SwiftUI

/// Rich rendering for local chat lookup tool results.
/// Decodes structured JSON from contentSummary and renders using the same
/// visual style as the home page server/session cards.
struct CrossServerToolResultView: View {
    let data: ConversationDynamicToolCallData
    @State private var isDetailPresented = false

    var body: some View {
        if let payload = decode() {
            Button {
                isDetailPresented = true
            } label: {
                headerRow
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .sheet(isPresented: $isDetailPresented) {
                detailSheet(payload)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).macrodexFont(.caption).foregroundColor(MacrodexTheme.textMuted).padding(.vertical, 4)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Working")
                .macrodexFont(size: MacrodexFont.conversationBodyPointSize)
                .foregroundColor(MacrodexTheme.textSystem)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows tool details")
    }

    private func detailSheet(_ payload: DecodedPayload) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Working")
                        .macrodexFont(.headline, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    payloadContent(payload)
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
    private func payloadContent(_ payload: DecodedPayload) -> some View {
        switch payload {
        case .servers(let items):
            if items.isEmpty {
                emptyRow("No servers.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.name) { s in
                        SessionServerCardRow(
                            icon: s.isLocal ? "iphone" : "server.rack",
                            title: s.name,
                            subtitle: s.hostname,
                            trailing: .status(connected: s.isConnected)
                        )
                    }
                }
            }
        case .sessions(let items):
            if items.isEmpty {
                emptyRow("No chats.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.threadId) { s in
                        SessionServerCardRow(
                            icon: "text.bubble",
                            title: s.title,
                            subtitle: [s.serverName, s.model.isEmpty ? nil : s.model].compactMap { $0 }.joined(separator: " · "),
                            trailing: .none
                        )
                    }
                }
            }
        }
    }

    // MARK: - Decoding

    private struct ServerItem: Decodable {
        let name: String
        let hostname: String
        let isConnected: Bool
        let isLocal: Bool
    }

    private struct SessionItem: Decodable {
        // From ThreadSummary (server response)
        let id: String
        let preview: String?
        let modelProvider: String?
        let updatedAt: Int64?
        let cwd: String?
        // Added by our handler
        let serverName: String?

        var threadId: String { id }
        var title: String {
            let t = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t == "Untitled session" ? "New Chat" : t
        }
        var model: String { modelProvider ?? "" }
        var parsedDate: Date? {
            updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        }

        private enum CodingKeys: String, CodingKey {
            case id, preview, modelProvider, updatedAt, cwd, serverName
            case modelProviderSnake = "model_provider"
            case updatedAtSnake = "updated_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            preview = try c.decodeIfPresent(String.self, forKey: .preview)
            modelProvider = try c.decodeIfPresent(String.self, forKey: .modelProvider)
                ?? c.decodeIfPresent(String.self, forKey: .modelProviderSnake)
            updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt)
                ?? c.decodeIfPresent(Int64.self, forKey: .updatedAtSnake)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            serverName = try c.decodeIfPresent(String.self, forKey: .serverName)
        }
    }

    private enum DecodedPayload {
        case servers([ServerItem])
        case sessions([SessionItem])
    }

    private func decode() -> DecodedPayload? {
        guard let summary = data.contentSummary,
              let jsonData = summary.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = obj["type"] as? String,
              let itemsData = try? JSONSerialization.data(withJSONObject: obj["items"] ?? []) else {
            return nil
        }
        switch type {
        case "servers":
            return (try? JSONDecoder().decode([ServerItem].self, from: itemsData)).map { .servers($0) }
        case "sessions":
            return (try? JSONDecoder().decode([SessionItem].self, from: itemsData)).map { .sessions($0) }
        default:
            return nil
        }
    }
}

// MARK: - Shared card row used by both tool results and home page

/// A reusable card row matching the home page server/session visual style.
struct SessionServerCardRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var trailing: Trailing = .none

    enum Trailing {
        case none
        case status(connected: Bool)
        case statusLabel(String, Color)
        case badge(String)
        case chevron
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .macrodexFont(size: 16, weight: .medium)
                .foregroundColor(MacrodexTheme.accent)
                .frame(width: 28, height: 28)
                .background(MacrodexTheme.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .macrodexFont(.subheadline)
                    .foregroundColor(MacrodexTheme.textPrimary)
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            switch trailing {
            case .none:
                EmptyView()
            case .status(let connected):
                HStack(spacing: 6) {
                    Circle()
                        .fill(connected ? MacrodexTheme.accent : MacrodexTheme.textMuted.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(connected ? "Connected" : "Offline")
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textMuted)
                }
            case .statusLabel(let label, let color):
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                    Text(label)
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textMuted)
                }
            case .badge(let text):
                Text(text)
                    .macrodexFont(.caption, weight: .semibold)
                    .foregroundColor(MacrodexTheme.accent)
            case .chevron:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(MacrodexTheme.surface.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(MacrodexTheme.border.opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
