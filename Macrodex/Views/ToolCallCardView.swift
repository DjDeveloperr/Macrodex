import SwiftUI
import UIKit

struct ToolCallCardView: View {
    @Environment(DrawerController.self) private var drawerController
    let model: ToolCallCardModel
    let serverId: String?
    @State private var isDetailPresented = false
    @State private var collapsedDiffSections: Set<String> = []
    @State private var expandedDetailSectionIDs: Set<String> = []
    private let contentFontSize = MacrodexFont.conversationBodyPointSize
    private let terminalFontSize: CGFloat = 12

    init(
        model: ToolCallCardModel,
        serverId: String? = nil,
        externalExpanded: Bool? = nil,
        onExpandedChange: ((Bool) -> Void)? = nil
    ) {
        self.model = model
        self.serverId = serverId
    }

    var body: some View {
        Button {
            guard !drawerController.shouldSuppressContentInteractions else { return }
            isDetailPresented = true
        } label: {
            summaryRow
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isDetailPresented) {
            detailSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            Text(model.friendlyLabel)
                .macrodexFont(size: contentFontSize)
                .foregroundColor(MacrodexTheme.textSystem)
                .lineLimit(1)
                .truncationMode(.tail)
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
                        Text(model.friendlyLabel)
                            .macrodexFont(.headline, weight: .semibold)
                            .foregroundColor(MacrodexTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !model.summary.isEmpty && model.summary != model.friendlyLabel {
                            Text(model.summary)
                                .macrodexFont(.callout)
                                .foregroundColor(MacrodexTheme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let imageDescriptor {
                        ToolCallImagePreview(
                            descriptor: imageDescriptor,
                            serverId: serverId
                        )
                    }

                    ForEach(identifiedSections) { section in
                        sectionView(section)
                    }

                    if !hasDetailContent {
                        Text("No details available")
                            .macrodexFont(.callout)
                            .foregroundColor(MacrodexTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(model.friendlyLabel)
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

    private var hasDetailContent: Bool {
        imageDescriptor != nil || !identifiedSections.isEmpty
    }

    private var kindAccent: Color {
        switch model.kind {
        case .commandExecution, .commandOutput:
            return MacrodexTheme.warning
        case .fileChange, .fileDiff, .webSearch:
            return MacrodexTheme.accent
        case .mcpToolCall:
            return MacrodexTheme.accentStrong
        case .mcpToolProgress, .imageView:
            return MacrodexTheme.warning
        case .collaboration:
            return MacrodexTheme.success
        }
    }

    @ViewBuilder
    private func sectionView(_ section: IndexedValue<ToolCallSection>) -> some View {
        switch section.value {
        case .kv(let label, let entries):
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(label)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(identifiedKeyValueEntries(entries)) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.value.key + ":")
                                    .macrodexFont(size: contentFontSize, weight: .semibold)
                                    .foregroundColor(MacrodexTheme.textSecondary)
                                Text(entry.value.value)
                                    .macrodexFont(size: contentFontSize)
                                    .foregroundColor(MacrodexTheme.textSystem)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(8)
                    .background(MacrodexTheme.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        case .code(let label, let language, let content):
            codeLikeSection(id: section.id, label: label, language: language, content: content)
        case .json(let label, let content):
            codeLikeSection(id: section.id, label: label, language: "json", content: content)
        case .diff(let label, let content):
            diffSection(id: section.id, label: label, content: content)
        case .text(let label, let content):
            inlineTextSection(id: section.id, label: label, content: content)
        case .list(let label, let items):
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(label)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(identifiedTextItems(items, prefix: "list")) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .macrodexFont(size: contentFontSize)
                                    .foregroundColor(MacrodexTheme.textSecondary)
                                Text(item.value)
                                    .macrodexFont(size: contentFontSize)
                                    .foregroundColor(MacrodexTheme.textSystem)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                    .background(MacrodexTheme.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        case .progress(let label, let items):
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(label)
                    VStack(alignment: .leading, spacing: 6) {
                        let identifiedItems = identifiedTextItems(items, prefix: "progress")
                        ForEach(identifiedItems) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(item.index == identifiedItems.count - 1 ? kindAccent : MacrodexTheme.textMuted)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                Text(item.value)
                                    .macrodexFont(size: contentFontSize)
                                    .foregroundColor(MacrodexTheme.textSystem)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(8)
                    .background(MacrodexTheme.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .macrodexFont(.caption2, weight: .bold)
            .foregroundColor(MacrodexTheme.textSecondary)
    }

    @ViewBuilder
    private func codeLikeSection(id: String, label: String, language: String, content: String) -> some View {
        if isCollapsedDetailLabel(label) {
            collapsibleDetailSection(id: id, label: label) {
                CodeBlockView(language: language, code: content, fontSize: contentFontSize)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(label)
                CodeBlockView(language: language, code: content, fontSize: contentFontSize)
            }
        }
    }

    @ViewBuilder
    private func inlineTextSection(id: String, label: String, content: String) -> some View {
        let contentView = Text(verbatim: content)
            .macrodexMonoFont(size: contentFontSize)
            .foregroundColor(MacrodexTheme.textBody)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

        if isCollapsedDetailLabel(label) {
            collapsibleDetailSection(id: id, label: label) {
                contentView
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(label)
                contentView
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(MacrodexTheme.codeBackground.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func collapsibleDetailSection<Content: View>(
        id: String,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isExpanded = expandedDetailSectionIDs.contains(id)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    toggleDetailSection(id)
                }
            } label: {
                HStack(spacing: 8) {
                    sectionLabel(label)
                    Spacer(minLength: 0)
                    Text(isExpanded ? "Hide" : "Show")
                        .macrodexFont(.caption2, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.vertical, 6)
            }
        }
    }

    private func isCollapsedDetailLabel(_ label: String) -> Bool {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "command"
            || normalized == "output"
            || normalized == "command output"
            || normalized == "arguments"
            || normalized == "result"
    }

    private func toggleDetailSection(_ id: String) {
        if expandedDetailSectionIDs.contains(id) {
            expandedDetailSectionIDs.remove(id)
        } else {
            expandedDetailSectionIDs.insert(id)
        }
    }

    private func diffSection(id: String, label: String, content: String) -> some View {
        let isCollapsible = model.kind == .fileDiff && !label.isEmpty
        let isExpanded = !collapsedDiffSections.contains(id)

        return VStack(alignment: .leading, spacing: 6) {
            if isCollapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        toggleDiffSection(id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        sectionLabel(label)
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .macrodexFont(size: 10, weight: .medium)
                            .foregroundColor(MacrodexTheme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if !label.isEmpty {
                sectionLabel(label)
            }

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: true) {
                    SyntaxHighlightedDiffText(
                        diff: content,
                        titleHint: label.isEmpty ? nil : label,
                        fontSize: terminalFontSize
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .background(MacrodexTheme.codeBackground.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func toggleDiffSection(_ id: String) {
        if collapsedDiffSections.contains(id) {
            collapsedDiffSections.remove(id)
        } else {
            collapsedDiffSections.insert(id)
        }
    }

    private var identifiedSections: [IndexedValue<ToolCallSection>] {
        let visibleSections = model.sections.filter { section in
            guard model.kind == .imageView else { return true }
            return !sectionContainsInlineImagePayload(section)
        }

        return identifiedValues(visibleSections, prefix: "section") { section in
            switch section {
            case .kv(let label, let entries):
                return "\(label)|kv|\(entries.map { "\($0.key)=\($0.value)" }.joined(separator: "|"))"
            case .code(let label, let language, let content):
                return "\(label)|code|\(language)|\(content)"
            case .json(let label, let content):
                return "\(label)|json|\(content)"
            case .diff(let label, let content):
                return "\(label)|diff|\(content)"
            case .text(let label, let content):
                return "\(label)|text|\(content)"
            case .list(let label, let items):
                return "\(label)|list|\(items.joined(separator: "|"))"
            case .progress(let label, let items):
                return "\(label)|progress|\(items.joined(separator: "|"))"
            }
        }
    }

    private var imageDescriptor: ToolCallImageDescriptor? {
        guard model.kind == .imageView else { return nil }

        for section in model.sections {
            switch section {
            case .kv(_, let entries):
                for entry in entries {
                    if let descriptor = imageDescriptor(from: entry.value) {
                        return descriptor
                    }
                }
            case .code(_, _, let content),
                 .json(_, let content),
                 .text(_, let content):
                if let descriptor = imageDescriptor(from: content) {
                    return descriptor
                }
            default:
                continue
            }
        }

        return nil
    }

    private func sectionContainsInlineImagePayload(_ section: ToolCallSection) -> Bool {
        switch section {
        case .code(_, _, let content),
             .json(_, let content),
             .text(_, let content):
            return Self.inlineImageData(from: content) != nil
        default:
            return false
        }
    }

    private func imageDescriptor(from rawValue: String) -> ToolCallImageDescriptor? {
        if let data = Self.inlineImageData(from: rawValue) {
            return .inlineData(data)
        }
        if let path = Self.normalizedImagePath(from: rawValue) {
            return .filePath(path)
        }
        return nil
    }

    private static func normalizedImagePath(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://"),
           let url = URL(string: trimmed),
           url.isFileURL {
            return url.path(percentEncoded: false)
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.hasPrefix("\\\\") {
            return trimmed
        }
        if trimmed.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
            return trimmed
        }

        return nil
    }

    private static func inlineImageData(from rawValue: String) -> Data? {
        guard let match = rawValue.range(
            of: #"data:image/[^;]+;base64,[A-Za-z0-9+/=\s]+"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let source = String(rawValue[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commaIndex = source.firstIndex(of: ",") else { return nil }
        let base64 = String(source[source.index(after: commaIndex)...])
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    private func identifiedKeyValueEntries(_ entries: [ToolCallKeyValue]) -> [IndexedValue<ToolCallKeyValue>] {
        identifiedValues(entries, prefix: "kv") { entry in
            "\(entry.key)|\(entry.value)"
        }
    }

    private func identifiedTextItems(_ values: [String], prefix: String) -> [IndexedValue<String>] {
        identifiedValues(values, prefix: prefix) { $0 }
    }

    private func identifiedValues<Value>(
        _ values: [Value],
        prefix: String,
        key: (Value) -> String
    ) -> [IndexedValue<Value>] {
        var seen: [String: Int] = [:]
        return values.enumerated().map { index, value in
            let signature = key(value)
            let occurrence = seen[signature, default: 0]
            seen[signature] = occurrence + 1
            return IndexedValue(
                id: "\(prefix)-\(signature.hashValue)-\(occurrence)",
                index: index,
                value: value
            )
        }
    }
}

struct ToolCallGroupCardView: View {
    @Environment(DrawerController.self) private var drawerController
    let models: [ToolCallCardModel]
    let serverId: String?
    @State private var isDetailPresented = false
    @State private var expandedModelIDs: Set<String> = []
    private let contentFontSize = MacrodexFont.conversationBodyPointSize

    init(models: [ToolCallCardModel], serverId: String? = nil) {
        self.models = models
        self.serverId = serverId
    }

    var body: some View {
        Button {
            guard !drawerController.shouldSuppressContentInteractions else { return }
            isDetailPresented = true
        } label: {
            HStack(spacing: 8) {
                Text(summaryLabel)
                    .macrodexFont(size: contentFontSize)
                    .foregroundColor(MacrodexTheme.textSystem)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(summaryLabel)
            .accessibilityHint("Shows tool details")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isDetailPresented) {
            detailSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var summaryLabel: String {
        models.last?.friendlyLabel ?? "Working"
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summaryLabel)
                            .macrodexFont(.headline, weight: .semibold)
                            .foregroundColor(MacrodexTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("\(models.count) tool call\(models.count == 1 ? "" : "s")")
                            .macrodexFont(.callout)
                            .foregroundColor(MacrodexTheme.textSecondary)
                    }

                    ForEach(identifiedModels) { entry in
                        toolCallDisclosure(entry)
                    }
                }
                .padding(16)
            }
            .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(summaryLabel)
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

    private var identifiedModels: [IndexedValue<ToolCallCardModel>] {
        var seen: [String: Int] = [:]
        return models.enumerated().map { index, model in
            let signature = "\(model.kind.rawValue)|\(model.friendlyLabel)|\(model.summary)|\(model.sections)"
            let occurrence = seen[signature, default: 0]
            seen[signature] = occurrence + 1
            return IndexedValue(
                id: "tool-group-\(signature.hashValue)-\(occurrence)",
                index: index,
                value: model
            )
        }
    }

    private func toolCallDisclosure(_ entry: IndexedValue<ToolCallCardModel>) -> some View {
        let model = entry.value
        let isExpanded = expandedModelIDs.contains(entry.id)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    toggleModel(entry.id)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.friendlyLabel)
                        .macrodexFont(size: contentFontSize, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textSystem)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .macrodexFont(size: 11, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.summary.isEmpty && model.summary != model.friendlyLabel {
                        Text(model.summary)
                            .macrodexFont(.caption)
                            .foregroundColor(MacrodexTheme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(identifiedSections(for: model)) { section in
                        groupedSectionView(section.value)
                    }

                    if model.sections.isEmpty {
                        Text("No details available")
                            .macrodexFont(.callout)
                            .foregroundColor(MacrodexTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
                .transition(.toolCallDetailReveal)
            }
        }
        .padding(10)
        .background(MacrodexTheme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func groupedSectionView(_ section: ToolCallSection) -> some View {
        switch section {
        case .kv(let label, let entries):
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(label)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.key + ":")
                                    .macrodexFont(size: contentFontSize, weight: .semibold)
                                    .foregroundColor(MacrodexTheme.textSecondary)
                                Text(entry.value)
                                    .macrodexFont(size: contentFontSize)
                                    .foregroundColor(MacrodexTheme.textSystem)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        case .code(let label, let language, let content):
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(label)
                CodeBlockView(language: language, code: content, fontSize: contentFontSize)
            }
        case .json(let label, let content):
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(label)
                CodeBlockView(language: "json", code: content, fontSize: contentFontSize)
            }
        case .diff(let label, let content):
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(label)
                CodeBlockView(language: "diff", code: content, fontSize: contentFontSize)
            }
        case .text(let label, let content):
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(label)
                Text(verbatim: content)
                    .macrodexMonoFont(size: contentFontSize)
                    .foregroundColor(MacrodexTheme.textBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(MacrodexTheme.codeBackground.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .list(let label, let items):
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(label)
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(verbatim: item)
                            .macrodexFont(size: contentFontSize)
                            .foregroundColor(MacrodexTheme.textSystem)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .progress(let label, let items):
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(label)
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(verbatim: item)
                            .macrodexFont(size: contentFontSize)
                            .foregroundColor(MacrodexTheme.textSystem)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .macrodexFont(.caption2, weight: .bold)
            .foregroundColor(MacrodexTheme.textSecondary)
    }

    private func identifiedSections(for model: ToolCallCardModel) -> [IndexedValue<ToolCallSection>] {
        var seen: [String: Int] = [:]
        return model.sections.enumerated().map { index, section in
            let signature = "\(section)"
            let occurrence = seen[signature, default: 0]
            seen[signature] = occurrence + 1
            return IndexedValue(
                id: "section-\(signature.hashValue)-\(occurrence)",
                index: index,
                value: section
            )
        }
    }

    private func toggleModel(_ id: String) {
        if expandedModelIDs.contains(id) {
            expandedModelIDs.remove(id)
        } else {
            expandedModelIDs.insert(id)
        }
    }
}

private extension AnyTransition {
    static var toolCallDetailReveal: AnyTransition { .sectionReveal }
}

private struct IndexedValue<Value>: Identifiable {
    let id: String
    let index: Int
    let value: Value
}

private enum ToolCallImageDescriptor: Equatable {
    case inlineData(Data)
    case filePath(String)

    var cacheKey: String {
        switch self {
        case .inlineData(let data):
            return "inline-\(data.hashValue)"
        case .filePath(let path):
            return "path-\(path)"
        }
    }
}

private struct ToolCallImagePreview: View {
    @Environment(AppModel.self) private var appModel

    let descriptor: ToolCallImageDescriptor
    let serverId: String?

    @State private var renderedImage: UIImage?
    @State private var isLoading = false
    @State private var loadError: String?

    private static let imageCache = NSCache<NSString, UIImage>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("IMAGE")
                .macrodexFont(.caption2, weight: .bold)
                .foregroundColor(MacrodexTheme.textSecondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MacrodexTheme.codeBackground.opacity(0.82))

                if let renderedImage {
                    Image(uiImage: renderedImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if isLoading {
                    ProgressView()
                        .tint(MacrodexTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    Text(loadError ?? "Image unavailable")
                        .macrodexFont(.caption)
                        .foregroundColor(loadError == nil ? MacrodexTheme.textSecondary : MacrodexTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .task(id: taskKey) {
            await loadImage()
        }
    }

    private var taskKey: String {
        "\(descriptor.cacheKey)|\(serverId ?? "<none>")"
    }

    private func loadImage() async {
        if let cached = Self.imageCache.object(forKey: taskKey as NSString) {
            renderedImage = cached
            loadError = nil
            isLoading = false
            return
        }

        isLoading = true
        loadError = nil

        defer {
            isLoading = false
        }

        do {
            let image: UIImage
            switch descriptor {
            case .inlineData(let data):
                guard let decoded = UIImage(data: data) else {
                    throw ToolCallImageError.invalidImageData
                }
                image = decoded
            case .filePath(let path):
                let data = try await fetchImageData(path: path)
                guard let decoded = UIImage(data: data) else {
                    throw ToolCallImageError.invalidImageData
                }
                image = decoded
            }

            Self.imageCache.setObject(image, forKey: taskKey as NSString)
            renderedImage = image
            loadError = nil
        } catch {
            renderedImage = nil
            loadError = ToolCallImageError.message(for: error)
        }
    }

    private func fetchImageData(path: String) async throws -> Data {
        let resolved = try await appModel.client.resolveImageView(
            serverId: serverId ?? "",
            path: path
        )
        return Data(resolved.bytes)
    }
}

private enum ToolCallImageError: LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Could not decode the image."
        }
    }

    static func message(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Image unavailable" : message
    }
}

#if DEBUG
#Preview("Tool Call Card") {
    ZStack {
        MacrodexTheme.backgroundGradient.ignoresSafeArea()
        ToolCallCardView(model: MacrodexPreviewData.sampleToolCallModel)
            .padding(20)
    }
}
#endif
