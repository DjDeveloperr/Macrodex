import Foundation

enum ToolCallKind: String, Equatable {
    case commandExecution
    case commandOutput
    case fileChange
    case fileDiff
    case mcpToolCall
    case mcpToolProgress
    case webSearch
    case collaboration
    case imageView

    var title: String {
        switch self {
        case .commandExecution: return "Command Execution"
        case .commandOutput: return "Command Output"
        case .fileChange: return "File Change"
        case .fileDiff: return "File Diff"
        case .mcpToolCall: return "MCP Tool Call"
        case .mcpToolProgress: return "MCP Tool Progress"
        case .webSearch: return "Web Search"
        case .collaboration: return "Collaboration"
        case .imageView: return "Image View"
        }
    }

    var iconName: String {
        switch self {
        case .commandExecution, .commandOutput:
            return "terminal.fill"
        case .fileChange:
            return "doc.text.fill"
        case .fileDiff:
            return "arrow.left.arrow.right.square.fill"
        case .mcpToolCall:
            return "wrench.and.screwdriver.fill"
        case .mcpToolProgress:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .webSearch:
            return "globe"
        case .collaboration:
            return "person.2.fill"
        case .imageView:
            return "photo.fill"
        }
    }

    static func from(title: String) -> ToolCallKind? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("command output") { return .commandOutput }
        if normalized.contains("command execution") || normalized == "command" { return .commandExecution }
        if normalized.contains("file change") { return .fileChange }
        if normalized.contains("file diff") || normalized == "diff" { return .fileDiff }
        if normalized.contains("mcp tool progress") { return .mcpToolProgress }
        if normalized.contains("mcp tool call") || normalized == "mcp" { return .mcpToolCall }
        if normalized.contains("web search") { return .webSearch }
        if normalized.contains("collaboration") || normalized.contains("collab") { return .collaboration }
        if normalized.contains("image view") || normalized == "image" { return .imageView }
        if normalized.contains("dynamic tool call") { return .mcpToolCall }
        return nil
    }

    var isCommandLike: Bool {
        switch self {
        case .commandExecution, .commandOutput:
            return true
        default:
            return false
        }
    }
}

extension ToolCallStatus {
    var label: String {
        switch self {
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }
}

extension AppOperationStatus {
    var toolCallStatus: ToolCallStatus {
        switch self {
        case .pending, .inProgress:
            return .inProgress
        case .completed:
            return .completed
        case .failed, .declined:
            return .failed
        case .unknown:
            return .unknown
        }
    }

    var displayLabel: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .pending:
            return "Pending"
        case .inProgress:
            return "In Progress"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .declined:
            return "Declined"
        }
    }
}

struct ToolCallKeyValue: Equatable {
    let key: String
    let value: String
}

struct ToolCallCommandContext: Equatable {
    let command: String
    let directory: String?
}

enum ToolCallSection: Equatable {
    case kv(label: String, entries: [ToolCallKeyValue])
    case code(label: String, language: String, content: String)
    case json(label: String, content: String)
    case diff(label: String, content: String)
    case text(label: String, content: String)
    case list(label: String, items: [String])
    case progress(label: String, items: [String])
}

struct ToolCallCardModel: Equatable {
    let kind: ToolCallKind
    let title: String
    let summary: String
    let attributedSummary: AttributedString?
    let status: ToolCallStatus
    let duration: String?
    let sections: [ToolCallSection]
    let initiallyExpanded: Bool
    let commandContext: ToolCallCommandContext?

    init(
        kind: ToolCallKind,
        title: String,
        summary: String,
        attributedSummary: AttributedString? = nil,
        status: ToolCallStatus,
        duration: String?,
        sections: [ToolCallSection],
        initiallyExpanded: Bool = false,
        commandContext: ToolCallCommandContext? = nil
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.attributedSummary = attributedSummary
        self.status = status
        self.duration = duration
        self.sections = sections
        self.initiallyExpanded = initiallyExpanded
        self.commandContext = commandContext
    }

    var defaultExpanded: Bool { initiallyExpanded || status == .failed }

    var friendlyLabel: String {
        switch kind {
        case .webSearch:
            if let query = webSearchQuery, !query.isEmpty {
                return "Searching web \(query)"
            }
            return "Searching web"
        case .commandExecution, .commandOutput:
            return toolCallFriendlyCommandLabel(for: commandContext?.command ?? summary)
        case .mcpToolCall, .mcpToolProgress:
            return toolCallFriendlyDynamicLabel(summary: summary, sections: sections)
        case .imageView:
            return "Working"
        case .fileChange,
             .fileDiff,
             .collaboration:
            return "Working"
        }
    }

    private var webSearchQuery: String? {
        for section in sections {
            if case .text(let label, let content) = section,
               label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "query" {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }

        let summaryPrefix = "web search for "
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSummary.lowercased().hasPrefix(summaryPrefix) {
            let start = trimmedSummary.index(trimmedSummary.startIndex, offsetBy: summaryPrefix.count)
            let query = trimmedSummary[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : query
        }

        return nil
    }
}

func toolCallFriendlyCommandLabel(for command: String) -> String {
    if let label = parsedMacrodexSQLLabel(from: command) {
        return label
    }
    if let label = healthKitCommandLabel(for: command) {
        return label
    }
    return isLikelyDatabaseCommand(command) ? "Checking database" : "Working"
}

private func toolCallFriendlyDynamicLabel(summary: String, sections: [ToolCallSection]) -> String {
    let joinedSections = sections.map { section -> String in
        switch section {
        case .kv(let label, let entries):
            return "\(label) \(entries.map { "\($0.key) \($0.value)" }.joined(separator: " "))"
        case .code(let label, _, let content):
            return "\(label) \(content)"
        case .json(let label, let content):
            return "\(label) \(content)"
        case .diff(let label, let content):
            return "\(label) \(content)"
        case .text(let label, let content):
            return "\(label) \(content)"
        case .list(let label, let items):
            return "\(label) \(items.joined(separator: " "))"
        case .progress(let label, let items):
            return "\(label) \(items.joined(separator: " "))"
        }
    }.joined(separator: " ")
    let searchable = "\(summary) \(joinedSections)"
    if let purpose = parsedToolPurpose(from: searchable) {
        return purpose
    }
    if let label = parsedMacrodexSQLLabel(from: searchable) {
        return label
    }
    if searchable.localizedCaseInsensitiveContains("food_search") {
        return "Searching foods"
    }
    if let label = healthKitCommandLabel(for: searchable) {
        return label
    }
    let lowercased = searchable.lowercased()
    if lowercased.contains("\"tool\"") && lowercased.contains("\"sql\"")
        || lowercased.contains(" sql ")
        || summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "sql" {
        return "Checking database"
    }
    if summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "jsc" {
        return "Running script"
    }
    return "Working"
}

private func healthKitCommandLabel(for command: String) -> String? {
    let lowercased = command.lowercased()
    guard lowercased.contains("healthkit") || lowercased.contains("\"healthkit\"") || lowercased.contains("'healthkit'") else {
        return nil
    }
    if lowercased.contains("sync-nutrition") {
        return "Syncing nutrition to Apple Health"
    }
    if lowercased.contains("write-workout") {
        return "Writing Apple Health workout"
    }
    if lowercased.contains("write-category") || lowercased.contains("write-quantity") {
        return "Writing Apple Health data"
    }
    if lowercased.contains("stats") {
        return "Summarizing Apple Health"
    }
    if lowercased.contains("query") {
        return "Reading Apple Health samples"
    }
    if lowercased.contains("request") {
        return "Requesting Apple Health access"
    }
    if lowercased.contains("types") {
        return "Checking Apple Health fields"
    }
    if lowercased.contains("status") {
        return "Checking Apple Health"
    }
    return "Using Apple Health"
}

private func parsedMacrodexSQLLabel(from command: String) -> String? {
    let patterns = [
        #"--\s*macrodex(?:[-_ ]sql)?(?:[-_ ]label)?\s*:\s*([^\r\n]+)"#,
        #"/\*\s*macrodex(?:[-_ ]sql)?(?:[-_ ]label)?\s*:\s*(.*?)\s*\*/"#
    ]
    let fullRange = NSRange(command.startIndex..<command.endIndex, in: command)

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            continue
        }
        guard let match = regex.firstMatch(in: command, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let labelRange = Range(match.range(at: 1), in: command) else {
            continue
        }
        if let label = sanitizedMacrodexSQLLabel(String(command[labelRange])) {
            return label
        }
    }

    return nil
}

private func parsedToolPurpose(from text: String) -> String? {
    guard let data = text.data(using: .utf8) else { return nil }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let purpose = object["purpose"] as? String {
        return sanitizedToolPurpose(purpose)
    }
    let patterns = [
        #""purpose"\s*:\s*"((?:\\.|[^"\\])*)""#,
        #"'purpose'\s*:\s*'((?:\\.|[^'\\])*)'"#
    ]
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            continue
        }
        let matches = regex.matches(in: text, range: fullRange)
        for match in matches.reversed() where match.numberOfRanges > 1 {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[range])
                .replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\'"#, with: "'")
                .replacingOccurrences(of: #"\\n"#, with: " ")
            if let purpose = sanitizedToolPurpose(raw) {
                return purpose
            }
        }
    }
    return nil
}

private func sanitizedToolPurpose(_ raw: String) -> String? {
    var label = raw
        .replacingOccurrences(of: "\\n", with: " ")
        .replacingOccurrences(of: "\\r", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return nil }
    if let newlineRange = label.rangeOfCharacter(from: .newlines) {
        label = String(label[..<newlineRange.lowerBound])
    }
    if label.count > 56 {
        label = String(label.prefix(56)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return label.isEmpty ? nil : label
}

private func sanitizedMacrodexSQLLabel(_ rawLabel: String) -> String? {
    var label = rawLabel
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return nil }

    let stopMarkers = ["*/", #"*\/"#, "\n", "\r"]
    for marker in stopMarkers {
        if let range = label.range(of: marker) {
            label = String(label[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    let sqlStarts = [" SELECT ", " WITH ", " PRAGMA ", " INSERT ", " UPDATE ", " DELETE ", " CREATE ", " ALTER ", " DROP "]
    let paddedUpper = " " + label.uppercased() + " "
    for sqlStart in sqlStarts {
        if let range = paddedUpper.range(of: sqlStart) {
            let end = label.index(label.startIndex, offsetBy: max(paddedUpper.distance(from: paddedUpper.startIndex, to: range.lowerBound) - 1, 0))
            label = String(label[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    if label.count > 56 {
        label = String(label.prefix(56)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return label.isEmpty ? nil : label
}

private func isLikelyDatabaseCommand(_ command: String) -> Bool {
    let normalized = command
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !normalized.isEmpty else { return false }

    let databaseCommandPatterns = [
        #"(^|\s)(sqlite3|psql|mysql|mariadb|duckdb|sqlcmd|createdb|dropdb|pg_dump|pg_restore)(\s|$)"#,
        #"(^|\s)(prisma|drizzle|sequelize)\s+(db|migrate|studio|generate|push|pull)"#,
        #"(^|\s)(supabase)\s+(db|migration|gen|link|start|status)"#,
        #"\b(select|insert|update|delete|create|alter|drop|truncate)\b.+\b(from|into|table|database|schema|where|values|set)\b"#,
        #"\b(with|explain)\b.+\bselect\b"#
    ]

    return databaseCommandPatterns.contains { pattern in
        normalized.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ToolCallParseResult: Equatable {
    case recognized(ToolCallCardModel)
    case unrecognized
}
