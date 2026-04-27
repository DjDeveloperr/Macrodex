import SwiftUI

/// Shared sheet for model + reasoning options. Used
/// by the home composer's `HomeModelChip` (no thread yet — `threadKey` nil)
/// and by any caller in a thread context (existing conversation).
struct ConversationOptionsSheet: View {
    let models: [ModelInfo]
    @Binding var selectedModel: String
    @Binding var reasoningEffort: String
    var threadKey: ThreadKey?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Present the inline selector exactly as it appears in the
        // conversation popover — no NavigationStack, no title bar. The
        // sheet drag indicator handles dismissal; a Done row from
        // InlineModelSelectorView itself stays available via `onDismiss`.
        InlineModelSelectorView(
            models: models,
            selectedModel: $selectedModel,
            reasoningEffort: $reasoningEffort,
            threadKey: threadKey,
            onDismiss: { dismiss() }
        )
        .background(MacrodexTheme.surface.ignoresSafeArea())
    }
}
