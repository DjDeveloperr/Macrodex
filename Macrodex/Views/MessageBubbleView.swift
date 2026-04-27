import SwiftUI
import Hairball
import HairballUI
import UIKit

extension View {
    @ViewBuilder
    func applyStreamingEffect(_ effect: (any StreamingTextEffect)?) -> some View {
        if let effect {
            self.streamingTextEffect(effect)
        } else {
            self
        }
    }
}

// MARK: - Active Thread Key Environment

private struct ActiveThreadKeyKey: EnvironmentKey {
    static let defaultValue: ThreadKey? = nil
}

extension EnvironmentValues {
    var activeThreadKey: ThreadKey? {
        get { self[ActiveThreadKeyKey.self] }
        set { self[ActiveThreadKeyKey.self] = newValue }
    }
}

extension View {
    func activeThreadKey(_ key: ThreadKey?) -> some View {
        environment(\.activeThreadKey, key)
    }
}

// MARK: - Reusable bubble components

enum MacrodexMarkdownStyleVariant {
    case content
    case system
}

struct MacrodexMarkdownView: View {
    let markdown: String
    var style: MacrodexMarkdownStyleVariant = .content
    var bodySize: CGFloat = MacrodexFont.conversationBodyPointSize
    var codeSize: CGFloat = MacrodexFont.conversationBodyPointSize
    var selectionEnabled = true

    var body: some View {
        renderedMarkdown(selectionEnabled: selectionEnabled)
    }

    @ViewBuilder
    private func renderedMarkdown(selectionEnabled: Bool) -> some View {
        let view = MarkdownView(markdown, processors: [LatexTransformer()])
        switch style {
        case .content:
            view.macrodexContentMarkdown(
                bodySize: bodySize, codeSize: codeSize,
                selectionEnabled: selectionEnabled
            )
        case .system:
            view.macrodexSystemMarkdown(
                bodySize: bodySize, codeSize: codeSize,
                selectionEnabled: selectionEnabled
            )
        }
    }
}

struct InlineSelectableMarkdownMessage<Content: View>: View {
    let markdown: String
    var style: MacrodexMarkdownStyleVariant = .content
    var bodySize: CGFloat = MacrodexFont.conversationBodyPointSize
    var codeSize: CGFloat = MacrodexFont.conversationBodyPointSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private extension MacrodexMarkdownStyleVariant {
    var cacheKey: String {
        switch self {
        case .content:
            return "content"
        case .system:
            return "system"
        }
    }
}

struct UserBubble: View {
    @Environment(\.textScale) private var textScale
    let text: String
    var images: [ChatImage] = []
    var compact: Bool = false
    private let contentFontSize = MacrodexFont.conversationBodyPointSize

    var body: some View {
        if hasVisibleContent {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: compact ? 30 : 60)
                VStack(alignment: .trailing, spacing: compact ? 6 : 8) {
                    ForEach(images) { img in
                        if let uiImage = UserBubble.decodeImage(img) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 240)
                                .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous)
                                        .stroke(.white.opacity(0.16), lineWidth: 0.5)
                                )
                        }
                    }

                    if hasText {
                        FormattedText(text: text)
                            .font(.system(size: contentFontSize * textScale, weight: .regular))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .padding(.horizontal, compact ? 12 : 16)
                            .padding(.vertical, compact ? 8 : 12)
                            .background(
                                UnevenRoundedRectangle(
                                    cornerRadii: .init(
                                        topLeading: compact ? 16 : 20,
                                        bottomLeading: compact ? 16 : 20,
                                        bottomTrailing: compact ? 6 : 8,
                                        topTrailing: compact ? 16 : 20
                                    ),
                                    style: .continuous
                                )
                                .fill(Color(uiColor: .systemBlue))
                            )
                    }
                }
            }
            .padding(.bottom, compact ? 4 : 8)
        }
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasVisibleContent: Bool {
        hasText || !images.isEmpty
    }

    private static let imageCache = NSCache<NSString, UIImage>()

    private static func decodeImage(_ image: ChatImage) -> UIImage? {
        let key = image.cacheKey as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let data = imageData(for: image) else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static func imageData(for image: ChatImage) -> Data? {
        let source = image.source
        guard source.hasPrefix("data:") || source.hasPrefix("file://") else {
            return nil
        }

        if source.hasPrefix("file://") {
            let path = String(source.dropFirst("file://".count))
            return FileManager.default.contents(atPath: path)
        }

        guard let commaIndex = source.firstIndex(of: ",") else { return nil }
        let base64 = String(source[source.index(after: commaIndex)...])
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }
}

struct AssistantBubble: View, Equatable {
    let markdownString: String
    let markdownIdentity: Int
    var label: String? = nil
    var compact: Bool = false
    var themeVersion: Int = 0
    var allowsInlineSelection: Bool = true
    private let contentFontSize = MacrodexFont.conversationBodyPointSize

    init(
        text: String,
        label: String? = nil,
        compact: Bool = false,
        themeVersion: Int = 0,
        allowsInlineSelection: Bool = true
    ) {
        self.markdownString = text
        self.markdownIdentity = text.hashValue
        self.label = label
        self.compact = compact
        self.themeVersion = themeVersion
        self.allowsInlineSelection = allowsInlineSelection
    }

    init(
        markdownString: String,
        markdownIdentity: Int,
        label: String? = nil,
        compact: Bool = false,
        themeVersion: Int = 0,
        allowsInlineSelection: Bool = true
    ) {
        self.markdownString = markdownString
        self.markdownIdentity = markdownIdentity
        self.label = label
        self.compact = compact
        self.themeVersion = themeVersion
        self.allowsInlineSelection = allowsInlineSelection
    }

    static func == (lhs: AssistantBubble, rhs: AssistantBubble) -> Bool {
        lhs.markdownIdentity == rhs.markdownIdentity &&
        lhs.label == rhs.label &&
        lhs.compact == rhs.compact &&
        lhs.themeVersion == rhs.themeVersion &&
        lhs.allowsInlineSelection == rhs.allowsInlineSelection
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if allowsInlineSelection {
                InlineSelectableMarkdownMessage(
                    markdown: markdownString,
                    style: .content,
                    bodySize: contentFontSize,
                    codeSize: contentFontSize
                ) {
                    bubbleContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                bubbleContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: compact ? 8 : 20)
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            if let label {
                Text(label)
                    .macrodexFont(.caption2, weight: .semibold)
                    .foregroundColor(MacrodexTheme.textSecondary)
            }
            MacrodexMarkdownView(
                markdown: markdownString,
                style: .content,
                bodySize: contentFontSize,
                codeSize: contentFontSize
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AssistantBlocksBubble: View {
    let segments: [MessageRenderCache.AssistantSegment]
    var label: String? = nil
    var compact: Bool = false
    private let contentFontSize = MacrodexFont.conversationBodyPointSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                if let label {
                    Text(label)
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textSecondary)
                }

                ForEach(segments) { segment in
                    segmentView(segment)
                        .transition(.asymmetric(
                            insertion: .push(from: .top),
                            removal: .identity
                        ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: compact ? 8 : 20)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageRenderCache.AssistantSegment) -> some View {
        switch segment.kind {
        case .markdown(let content, let identity):
            MacrodexMarkdownView(
                markdown: content,
                style: .content,
                bodySize: contentFontSize,
                codeSize: contentFontSize
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(identity)
        case .codeBlock(let language, let code, let identity):
            if isMathCodeBlock(language) {
                MacrodexMarkdownView(
                    markdown: mathBlockMarkdown(code),
                    style: .content,
                    bodySize: contentFontSize,
                    codeSize: contentFontSize
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(identity)
            } else {
                CodeBlockView(
                    language: language ?? "",
                    code: code,
                    fontSize: contentFontSize
                )
                .id(identity)
            }
        case .image(let uiImage):
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func isMathCodeBlock(_ language: String?) -> Bool {
        guard let language else { return false }
        return language.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("math") == .orderedSame
    }

    private func mathBlockMarkdown(_ code: String) -> String {
        "```math\n\(code)\n```"
    }
}

struct StreamingAssistantBubble: View {
    @Environment(\.activeThreadKey) private var threadKey
    let itemId: String
    let text: String
    var isStreaming: Bool = false
    var label: String? = nil
    var themeVersion: Int = 0
    var onSnapshotRendered: (() -> Void)? = nil
    private let contentFontSize: CGFloat

    /// Renderer is resolved once during init. For streaming items, this
    /// creates the renderer eagerly (before deltas arrive) so the `if let`
    /// branch is taken on the very first body evaluation. The coordinator
    /// returns the same renderer when deltas later call `appendDelta`.
    private let resolvedRenderer: StreamingMarkdownRenderer?

    init(
        itemId: String,
        text: String,
        isStreaming: Bool = false,
        label: String? = nil,
        themeVersion: Int = 0,
        bodySize: CGFloat = MacrodexFont.conversationBodyPointSize,
        onSnapshotRendered: (() -> Void)? = nil
    ) {
        self.itemId = itemId
        self.text = text
        self.isStreaming = isStreaming
        self.label = label
        self.themeVersion = themeVersion
        self.contentFontSize = bodySize
        self.onSnapshotRendered = onSnapshotRendered

        let coord = StreamingRendererCoordinator.shared
        if isStreaming {
            self.resolvedRenderer = coord.renderer(for: itemId, currentText: text)
        } else {
            self.resolvedRenderer = nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let label {
                    Text(label)
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textSecondary)
                }
                if let resolvedRenderer {
                    StreamingMarkdownContentView(renderer: resolvedRenderer)
                        .macrodexContentMarkdown(
                            bodySize: contentFontSize,
                            codeSize: contentFontSize,
                            selectionEnabled: !isStreaming
                        )
                } else {
                    MacrodexMarkdownView(
                        markdown: text,
                        style: .content,
                        bodySize: contentFontSize,
                        codeSize: contentFontSize
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .tokenReveal(.disabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 20)
        }
        .onChange(of: text) {
            onSnapshotRendered?()
        }
    }
}

// MARK: - Full message bubble (used in conversation)

struct MessageBubbleView: View {
    private let renderCache = MessageRenderCache.shared
    let message: ChatMessage
    let serverId: String?
    let agentDirectoryVersion: UInt64
    let isStreamingMessage: Bool
    let actionsDisabled: Bool
    let onStreamingSnapshotRendered: (() -> Void)?
    let resolveTargetLabel: ((String) -> String?)?
    let onEditUserMessage: ((ChatMessage) -> Void)?
    let onForkFromUserMessage: ((ChatMessage) -> Void)?
    private let contentFontSize = MacrodexFont.conversationBodyPointSize

    init(
        message: ChatMessage,
        serverId: String? = nil,
        agentDirectoryVersion: UInt64 = 0,
        isStreamingMessage: Bool = false,
        actionsDisabled: Bool = false,
        onStreamingSnapshotRendered: (() -> Void)? = nil,
        resolveTargetLabel: ((String) -> String?)? = nil,
        onEditUserMessage: ((ChatMessage) -> Void)? = nil,
        onForkFromUserMessage: ((ChatMessage) -> Void)? = nil
    ) {
        self.message = message
        self.serverId = serverId
        self.agentDirectoryVersion = agentDirectoryVersion
        self.isStreamingMessage = isStreamingMessage
        self.actionsDisabled = actionsDisabled
        self.onStreamingSnapshotRendered = onStreamingSnapshotRendered
        self.resolveTargetLabel = resolveTargetLabel
        self.onEditUserMessage = onEditUserMessage
        self.onForkFromUserMessage = onForkFromUserMessage
    }

    var body: some View {
        Group {
            if message.role == .user {
                userBubbleWithActions
            } else if message.role == .assistant {
                assistantContent
            } else if isReasoning {
                HStack(alignment: .top, spacing: 0) {
                    reasoningContent
                    Spacer(minLength: 20)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    systemBubble
                    Spacer(minLength: 20)
                }
            }
        }
    }

    private var renderRevisionKey: MessageRenderCache.RevisionKey {
        MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: serverId,
            agentDirectoryVersion: agentDirectoryVersion,
            isStreaming: isStreamingMessage
        )
    }

    private var isReasoning: Bool {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return false }
        let firstLine = trimmed.prefix(while: { $0 != "\n" })
        return firstLine.lowercased().contains("reason")
    }

    private var supportsUserActions: Bool {
        message.role == .user &&
            message.isFromUserTurnBoundary &&
            message.sourceTurnIndex != nil
    }

    private var userBubbleWithActions: some View {
        UserBubble(text: message.text, images: message.images)
            .contextMenu {
                if supportsUserActions {
                    Button("Edit Message") {
                        onEditUserMessage?(message)
                    }
                    .disabled(actionsDisabled || onEditUserMessage == nil)

                    Button("Fork From Here") {
                        onForkFromUserMessage?(message)
                    }
                    .disabled(actionsDisabled || onForkFromUserMessage == nil)
                }
            }
    }

    @ViewBuilder
    private var assistantContent: some View {
        if isStreamingMessage {
            StreamingAssistantBubble(
                itemId: message.id.uuidString,
                text: message.text,
                isStreaming: true,
                label: assistantAgentLabel,
                onSnapshotRendered: onStreamingSnapshotRendered
            )
        } else {
            AssistantBlocksBubble(
                segments: assistantSegmentsForRendering,
                label: assistantAgentLabel
            )
        }
    }

    private var assistantAgentLabel: String? {
        AgentLabelFormatter.format(
            nickname: message.agentNickname,
            role: message.agentRole
        )
    }

    private var reasoningContent: some View {
        let (_, body) = extractSystemTitleAndBody(message.text)
        return Text(normalizedReasoningText(body))
            .macrodexFont(size: contentFontSize)
            .italic()
            .foregroundColor(MacrodexTheme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var systemBubble: some View {
        let parsed = systemParseResultForRendering
        switch parsed {
        case .recognized(let model):
            ToolCallCardView(model: model, serverId: serverId)
        case .unrecognized:
            genericSystemBubble
        }
    }

    private var genericSystemBubble: some View {
        let (title, body) = extractSystemTitleAndBody(message.text)
        let markdown = title == nil ? message.text : body
        let displayTitle = title ?? "System"

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .macrodexFont(size: 11, weight: .semibold)
                    .foregroundColor(MacrodexTheme.accent)
                Text(displayTitle.uppercased())
                    .macrodexFont(.caption2, weight: .bold)
                    .foregroundColor(MacrodexTheme.accent)
                Spacer()
            }

            if !markdown.isEmpty {
                MacrodexMarkdownView(
                    markdown: markdown,
                    style: .system,
                    bodySize: contentFontSize,
                    codeSize: contentFontSize
                )
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(GlassRectModifier(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(MacrodexTheme.accent.opacity(0.9))
                .frame(width: 3)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func extractSystemTitleAndBody(_ text: String) -> (String?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return (nil, trimmed) }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return (nil, trimmed) }
        let title = first.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : title, body)
    }

    private func normalizedReasoningText(_ body: String) -> String {
        body
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 {
                    return String(trimmed.dropFirst(2).dropLast(2))
                }
                return line
            }
            .joined(separator: "\n")
    }

    private var assistantSegmentsForRendering: [MessageRenderCache.AssistantSegment] {
        renderCache.assistantSegments(
            for: message,
            key: renderRevisionKey
        )
    }

    private var systemParseResultForRendering: ToolCallParseResult {
        renderCache.systemParseResult(
            for: message,
            key: renderRevisionKey,
            resolveTargetLabel: resolveTargetLabel
        )
    }
}

// MARK: - Macrodex Markdown Themes

private func macrodexContentTheme(bodySize: CGFloat, codeSize: CGFloat) -> MarkdownTheme {
    var theme = MarkdownTheme.default
    theme.bodyFont = .custom(MacrodexFont.markdownFontName, size: bodySize)
    theme.bodyFontSize = bodySize
    theme.foregroundColor = MacrodexTheme.textBody
    theme.paragraphSpacing = 8
    theme.blockSpacing = 8

    theme.headingStyleSet = HeadingStyleSet(
        h1: HeadingStyle(fontSize: bodySize * 1.43, weight: .bold,
                         topSpacing: 16, bottomSpacing: 8, color: MacrodexTheme.textPrimary),
        h2: HeadingStyle(fontSize: bodySize * 1.21, weight: .semibold,
                         topSpacing: 12, bottomSpacing: 6, color: MacrodexTheme.textPrimary),
        h3: HeadingStyle(fontSize: bodySize * 1.07, weight: .semibold,
                         topSpacing: 10, bottomSpacing: 4, color: MacrodexTheme.textPrimary),
        h4: HeadingStyle(fontSize: bodySize, weight: .semibold, color: MacrodexTheme.textPrimary),
        h5: HeadingStyle(fontSize: bodySize, weight: .semibold, color: MacrodexTheme.textPrimary),
        h6: HeadingStyle(fontSize: bodySize, weight: .semibold, color: MacrodexTheme.textPrimary)
    )

    theme.inlineCode = InlineCodeStyle(
        backgroundColor: MacrodexTheme.surfaceLight,
        textColor: MacrodexTheme.textPrimary,
        font: .custom(MacrodexFont.markdownFontName, size: codeSize),
        fontSize: codeSize
    )

    theme.codeBlock = CodeBlockStyle(
        backgroundColor: MacrodexTheme.codeBackground.opacity(0.8),
        textColor: MacrodexTheme.textPrimary,
        font: .custom(MacrodexFont.markdownFontName, size: codeSize),
        fontSize: codeSize,
        cornerRadius: 8,
        showLanguageLabel: false,
        showCopyButton: false
    )

    theme.blockquote = BlockquoteStyle(
        borderColor: MacrodexTheme.border,
        borderWidth: 3,
        textColor: MacrodexTheme.textSecondary,
        padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 4)
    )

    theme.table = TableStyle(
        borderStyle: .solid(color: MacrodexTheme.border, width: 0.5),
        headerBackground: MacrodexTheme.surfaceLight,
        headerFontWeight: .semibold,
        backgroundStyle: .alternatingRows(
            even: MacrodexTheme.surface.opacity(0.5),
            odd: .clear
        ),
        cornerRadius: 8
    )

    theme.list = ListStyleConfiguration(
        bulletMarker: .bullet,
        itemSpacing: 4,
        tightItemSpacing: 4
    )

    theme.link = LinkStyle(color: MacrodexTheme.accent, underline: false)

    theme.thematicBreak = ThematicBreakStyle(
        color: MacrodexTheme.border,
        verticalPadding: 12
    )

    return theme
}

private func macrodexSystemTheme(bodySize: CGFloat, codeSize: CGFloat) -> MarkdownTheme {
    var theme = MarkdownTheme.default
    theme.bodyFont = .custom(MacrodexFont.markdownFontName, size: bodySize)
    theme.bodyFontSize = bodySize
    theme.foregroundColor = MacrodexTheme.textSystem
    theme.paragraphSpacing = 6
    theme.blockSpacing = 6

    theme.headingStyleSet = HeadingStyleSet(
        h1: HeadingStyle(fontSize: bodySize * 1.31, weight: .bold,
                         topSpacing: 12, bottomSpacing: 6, color: MacrodexTheme.textPrimary),
        h2: HeadingStyle(fontSize: bodySize * 1.15, weight: .semibold,
                         topSpacing: 10, bottomSpacing: 4, color: MacrodexTheme.textPrimary),
        h3: HeadingStyle(fontSize: bodySize * 1.08, weight: .semibold,
                         topSpacing: 8, bottomSpacing: 4, color: MacrodexTheme.textPrimary),
        h4: HeadingStyle(fontSize: bodySize, weight: .semibold, color: MacrodexTheme.textPrimary),
        h5: HeadingStyle(fontSize: bodySize, weight: .semibold, color: MacrodexTheme.textPrimary),
        h6: HeadingStyle(fontSize: bodySize, weight: .semibold, color: MacrodexTheme.textPrimary)
    )

    theme.inlineCode = InlineCodeStyle(
        backgroundColor: MacrodexTheme.surfaceLight,
        textColor: MacrodexTheme.textPrimary,
        font: .custom(MacrodexFont.markdownFontName, size: codeSize),
        fontSize: codeSize
    )

    theme.codeBlock = CodeBlockStyle(
        backgroundColor: MacrodexTheme.codeBackground.opacity(0.8),
        textColor: MacrodexTheme.textPrimary,
        font: .custom(MacrodexFont.markdownFontName, size: codeSize),
        fontSize: codeSize,
        cornerRadius: 8,
        showLanguageLabel: false,
        showCopyButton: false
    )

    theme.blockquote = BlockquoteStyle(
        borderColor: MacrodexTheme.border,
        borderWidth: 3,
        textColor: MacrodexTheme.textSecondary,
        padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 4)
    )

    theme.table = TableStyle(
        borderStyle: .solid(color: MacrodexTheme.border, width: 0.5),
        headerBackground: MacrodexTheme.surfaceLight,
        headerFontWeight: .semibold,
        backgroundStyle: .alternatingRows(
            even: MacrodexTheme.surface.opacity(0.5),
            odd: .clear
        ),
        cornerRadius: 8
    )

    theme.list = ListStyleConfiguration(
        bulletMarker: .bullet,
        itemSpacing: 3,
        tightItemSpacing: 3
    )

    theme.link = LinkStyle(color: MacrodexTheme.accent, underline: false)

    theme.thematicBreak = ThematicBreakStyle(
        color: MacrodexTheme.border,
        verticalPadding: 8
    )

    return theme
}

struct MacrodexCodeBlockRenderer: CodeBlockRenderer {
    func makeBody(configuration: CodeBlockConfiguration) -> some View {
        DefaultCodeBlockRenderer().makeBody(configuration: configuration)
            .modifier(GlassRectModifier(cornerRadius: 8))
    }
}

// MARK: - Syntax Highlighting Theme Mapping

/// Shared highlighter instance — theme is switched at runtime via `setTheme(_:)`.
private let sharedHighlighter = HighlightrCodeSyntaxHighlighter(theme: "atom-one-dark")

/// Maps a Macrodex theme slug to the closest Highlightr theme name.
/// Direct matches are checked first, then known family prefixes, then light/dark fallback.
private let highlightrDirectMap: [String: String] = [
    "codex-dark": "atom-one-dark",
    "codex-light": "atom-one-light",
    "dark-plus-B1yOZ-Hy": "vs2015",
    "light-plus": "vs",
    "one-dark-pro-D": "atom-one-dark",
    "material-theme": "material",
    "material-theme-darker-D": "material-darker",
    "material-theme-lighter": "material-lighter",
    "material-theme-ocean": "ocean",
    "material-theme-palenight": "material-palenight",
    "catppuccin-mocha-Ry8aD-5u": "mocha",
    "catppuccin-latte-Bd1wq-gC": "one-light",
    "catppuccin-frappe": "atom-one-dark",
    "catppuccin-macchiato": "atom-one-dark",
    "tokyo-night": "tokyo-night-dark",
    "kanagawa-wave": "atom-one-dark",
    "kanagawa-dragon-VscOyZL-": "atom-one-dark",
    "kanagawa-lotus": "atom-one-light",
    "houston": "atom-one-dark",
    "poimandres": "panda-syntax-dark",
    "vitesse-black": "atom-one-dark",
    "vitesse-dark": "atom-one-dark",
    "vitesse-light": "atom-one-light",
    "linear-dark": "atom-one-dark",
    "linear-light": "atom-one-light",
    "sentry-dark": "atom-one-dark",
    "notion-dark-BTRKJ-yg": "atom-one-dark",
    "notion-light": "atom-one-light",
    "temple-dark": "atom-one-dark",
    "lobster-dark-dxSKfHK-": "atom-one-dark",
    "matrix-dark": "green-screen",
    "absolutely-dark": "atom-one-dark",
    "absolutely-light": "atom-one-light",
    "proof-light": "atom-one-light",
    "pierre-dark": "atom-one-dark",
    "pierre-light": "atom-one-light",
    "slack-dark": "atom-one-dark",
    "slack-ochin-CRg": "atom-one-light",
    "oscurange-C": "atom-one-dark",
    "ayu-dark": "atom-one-dark",
    "laserwave": "shades-of-purple",
    "vesper": "atom-one-dark",
    "min-dark-": "atom-one-dark",
    "min-light": "atom-one-light",
    "snazzy-light": "snazzy",
    "rose-pine-x": "rose-pine",
]

private let highlightrFamilyPrefixes = [
    "dracula", "monokai", "nord", "solarized-dark", "solarized-light",
    "night-owl", "one-light", "github-dark", "github-light",
    "gruvbox-dark-hard", "gruvbox-dark-medium", "gruvbox-dark-soft",
    "gruvbox-light-hard", "gruvbox-light-medium", "gruvbox-light-soft",
    "everforest-dark", "everforest-light",
    "rose-pine-dawn", "rose-pine-moon",
]

private func highlightrThemeName(for slug: String, type: ThemeDefinition.ThemeType) -> String {
    if let mapped = highlightrDirectMap[slug] { return mapped }

    for prefix in highlightrFamilyPrefixes {
        if slug.hasPrefix(prefix) {
            // Highlightr uses the same names for these (ros-pine vs rose-pine handled)
            let hlName = slug
                .replacingOccurrences(of: "github-dark-default", with: "github-dark")
                .replacingOccurrences(of: "github-dark-dimmed", with: "github-dark-dimmed")
                .replacingOccurrences(of: "github-dark-high-contrast", with: "github-dark")
                .replacingOccurrences(of: "github-light-default", with: "github")
                .replacingOccurrences(of: "github-light-high-contrast", with: "github")
                .replacingOccurrences(of: "everforest-dark", with: "atom-one-dark")
                .replacingOccurrences(of: "everforest-light", with: "atom-one-light")
                .replacingOccurrences(of: "rose-pine-dawn", with: "ros-pine-dawn")
                .replacingOccurrences(of: "rose-pine-moon", with: "ros-pine-moon")
            if hlName != slug { return hlName }
            return prefix
        }
    }

    // Fallback: generic dark/light
    return type == .dark ? "atom-one-dark" : "atom-one-light"
}

/// Returns the current Highlightr theme name based on the active Macrodex theme.
private func currentHighlightrTheme(for colorScheme: ColorScheme) -> String {
    let resolved = colorScheme == .dark ? ThemeStore.shared.dark : ThemeStore.shared.light
    return highlightrThemeName(for: resolved.slug, type: resolved.type)
}

/// Syncs the shared highlighter to match the current Macrodex theme.
private func syncHighlighterTheme(for colorScheme: ColorScheme) {
    let desired = currentHighlightrTheme(for: colorScheme)
    if sharedHighlighter.themeName != desired {
        sharedHighlighter.setTheme(desired)
    }
}

// MARK: - Auto-Scaling Markdown Modifiers

private struct ScaledContentMarkdownModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    let baseBodySize: CGFloat
    let baseCodeSize: CGFloat
    let selectionEnabled: Bool

    func body(content: Content) -> some View {
        let scaledBody = baseBodySize * textScale
        let scaledCode = baseCodeSize * textScale
        let _ = syncHighlighterTheme(for: colorScheme)
        let themed = content
            .markdownTheme(macrodexContentTheme(bodySize: scaledBody, codeSize: scaledCode))
            .codeSyntaxHighlighter(sharedHighlighter)
            .codeBlockRenderer(MacrodexCodeBlockRenderer())
        if selectionEnabled {
            themed.textSelection(.enabled)
        } else {
            themed
        }
    }
}

private struct ScaledSystemMarkdownModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    let baseBodySize: CGFloat
    let baseCodeSize: CGFloat
    let selectionEnabled: Bool

    func body(content: Content) -> some View {
        let scaledBody = baseBodySize * textScale
        let scaledCode = baseCodeSize * textScale
        let _ = syncHighlighterTheme(for: colorScheme)
        let themed = content
            .markdownTheme(macrodexSystemTheme(bodySize: scaledBody, codeSize: scaledCode))
            .codeSyntaxHighlighter(sharedHighlighter)
            .codeBlockRenderer(MacrodexCodeBlockRenderer())
        if selectionEnabled {
            themed.textSelection(.enabled)
        } else {
            themed
        }
    }
}

extension View {
    func macrodexContentMarkdown(
        bodySize: CGFloat = MacrodexFont.conversationBodyPointSize,
        codeSize: CGFloat = MacrodexFont.conversationBodyPointSize,
        selectionEnabled: Bool = true
    ) -> some View {
        modifier(
            ScaledContentMarkdownModifier(
                baseBodySize: bodySize,
                baseCodeSize: codeSize,
                selectionEnabled: selectionEnabled
            )
        )
    }

    func macrodexSystemMarkdown(
        bodySize: CGFloat = MacrodexFont.conversationBodyPointSize,
        codeSize: CGFloat = MacrodexFont.conversationBodyPointSize,
        selectionEnabled: Bool = true
    ) -> some View {
        modifier(
            ScaledSystemMarkdownModifier(
                baseBodySize: bodySize,
                baseCodeSize: codeSize,
                selectionEnabled: selectionEnabled
            )
        )
    }
}

#if DEBUG
#Preview("Message Bubbles") {
    MacrodexPreviewScene {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(MacrodexPreviewData.sampleMessages) { message in
                    MessageBubbleView(
                        message: message,
                        serverId: MacrodexPreviewData.sampleServer.id
                    )
                }
            }
            .padding(16)
        }
    }
}
#endif
