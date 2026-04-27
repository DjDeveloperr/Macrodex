import SwiftUI

/// Scrollable list of every thread across connected servers, sorted by
/// recency, filtered by the current query. Tapping a row calls `onAdd`.
/// Shows an indicator on rows already on the home list.
struct ThreadSearchResultsView: View {
    let sessions: [HomeDashboardRecentSession]
    let pinnedThreadKeys: Set<SavedThreadsStore.PinnedKey>
    let query: String
    var isLoading: Bool = false
    let onAdd: (HomeDashboardRecentSession) -> Void
    let onRemove: (HomeDashboardRecentSession) -> Void
    /// Padding applied inside the scroll view so content can scroll under
    /// the floating top/bottom chrome. Caller passes the same values the
    /// tasks list uses so the search view feels like a drop-in replacement.
    var contentInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    private var filtered: [HomeDashboardRecentSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter { session in
            session.sessionTitle.lowercased().contains(trimmed)
                || session.cwd.lowercased().contains(trimmed)
                || session.serverDisplayName.lowercased().contains(trimmed)
                || session.preview.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Color.clear.frame(height: contentInsets.top)
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(MacrodexTheme.accent)
                        Text("Loading chats…")
                            .macrodexFont(.footnote)
                            .foregroundStyle(MacrodexTheme.textMuted)
                    }
                    .padding(.vertical, 24)
                } else if filtered.isEmpty {
                    Text(sessions.isEmpty ? "No chats yet" : "No matches")
                        .macrodexFont(.footnote)
                        .foregroundStyle(MacrodexTheme.textMuted)
                        .padding(.vertical, 24)
                } else {
                    ForEach(filtered) { session in
                        ThreadSearchRow(
                            session: session,
                            isPinned: pinnedThreadKeys.contains(SavedThreadsStore.PinnedKey(threadKey: session.key)),
                            onAdd: { onAdd(session) },
                            onRemove: { onRemove(session) }
                        )
                        Divider().opacity(0.2)
                    }
                }
                Color.clear.frame(height: contentInsets.bottom)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct ThreadSearchRow: View {
    let session: HomeDashboardRecentSession
    let isPinned: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: { isPinned ? onRemove() : onAdd() }) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    FormattedText(text: session.sessionTitle, lineLimit: 1)
                        .font(.custom(MacrodexFont.markdownFontName, size: 13))
                        .fontWeight(.semibold)
                        .foregroundStyle(MacrodexTheme.textPrimary)
                    HStack(spacing: 4) {
                        Text(session.serverDisplayName)
                            .foregroundStyle(MacrodexTheme.accent.opacity(0.7))
                        if let workspace = HomeDashboardSupport.workspaceLabel(for: session.cwd) {
                            Text("\u{00b7}")
                                .foregroundStyle(MacrodexTheme.textMuted.opacity(0.5))
                            Text(workspace)
                                .foregroundStyle(MacrodexTheme.textSecondary.opacity(0.8))
                        }
                        Text("\u{00b7}")
                            .foregroundStyle(MacrodexTheme.textMuted.opacity(0.5))
                        Text(relativeDate(Int64(session.updatedAt.timeIntervalSince1970)))
                            .foregroundStyle(MacrodexTheme.textMuted.opacity(0.8))
                    }
                    .macrodexMonoFont(size: 10, weight: .regular)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isPinned ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isPinned ? MacrodexTheme.accent : MacrodexTheme.textSecondary.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
