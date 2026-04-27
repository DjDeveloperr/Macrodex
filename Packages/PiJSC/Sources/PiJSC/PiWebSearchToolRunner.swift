import Foundation

public struct PiWebSearchResult: Codable, Equatable, Sendable, Identifiable {
    public var id: String { url }
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String = "") {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public protocol PiWebSearchHTTPTransport {
    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse)
}

public enum PiWebSearchToolError: Error, Equatable, LocalizedError {
    case missingQuery
    case invalidURL
    case httpStatus(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingQuery:
            return "Web search requires a non-empty query."
        case .invalidURL:
            return "Failed to build web search URL."
        case .httpStatus(let status):
            return "Web search returned HTTP \(status)."
        case .invalidResponse:
            return "Web search returned an invalid response."
        }
    }
}

public final class PiWebSearchToolRunner: PiToolRunner {
    private let transport: any PiWebSearchHTTPTransport
    private let timeout: TimeInterval

    public init(
        transport: any PiWebSearchHTTPTransport = URLSessionPiWebSearchHTTPTransport(),
        timeout: TimeInterval = 20
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func runTool(_ call: PiToolCall) throws -> PiToolResult {
        let args = call.arguments.objectValue ?? [:]
        let query = (args["query"]?.stringValue ?? args["q"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Self.failureResult(callID: call.id, query: nil, error: PiWebSearchToolError.missingQuery)
        }
        let maxResults = max(3, min(args["maxResults"]?.intValue ?? 5, 10))
        let results: [PiWebSearchResult]
        do {
            results = try search(query: query, maxResults: maxResults)
        } catch {
            return Self.failureResult(callID: call.id, query: query, error: error)
        }
        return PiToolResult(
            callID: call.id,
            output: [
                "query": .string(query),
                "results": .array(results.map { result in
                    [
                        "title": .string(result.title),
                        "url": .string(result.url),
                        "snippet": .string(result.snippet)
                    ]
                })
            ]
        )
    }

    private static func failureResult(callID: String, query: String?, error: Error) -> PiToolResult {
        var output: [String: PiJSONValue] = [
            "ok": false,
            "error": .string(error.localizedDescription),
            "recoverable": true,
            "hint": "Use the failed search result as context, try one targeted alternate query if needed, or report what is missing."
        ]
        if let query {
            output["query"] = .string(query)
        }
        return PiToolResult(callID: callID, output: .object(output), isError: true)
    }

    public func search(query: String, maxResults: Int = 5) throws -> [PiWebSearchResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components?.url else {
            throw PiWebSearchToolError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("PiJSC/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try transport.perform(request)
        guard (200...299).contains(response.statusCode) else {
            throw PiWebSearchToolError.httpStatus(response.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw PiWebSearchToolError.invalidResponse
        }
        return Self.parseDuckDuckGoHTML(html, maxResults: maxResults)
    }

    public static func parseDuckDuckGoHTML(_ html: String, maxResults: Int) -> [PiWebSearchResult] {
        let blockPattern = #"<div[^>]*class="[^"]*result[^"]*"[^>]*>(.*?)</div>\s*</div>"#
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let blocks = blockRegex.matches(in: html, range: range).compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let blockRange = Range(match.range(at: 1), in: html) else {
                return nil
            }
            return String(html[blockRange])
        }
        var results: [PiWebSearchResult] = []

        if blocks.isEmpty {
            return parseDuckDuckGoResultLinks(html, maxResults: maxResults)
        }

        for block in blocks {
            guard results.count < maxResults else {
                break
            }
            guard let titleMatch = firstMatch(
                in: block,
                pattern: #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
            ) else {
                continue
            }
            let rawURL = decodeHTML(titleMatch[0])
            let title = cleanText(titleMatch[1])
            let url = normalizeDuckDuckGoURL(rawURL)
            guard !title.isEmpty, !url.isEmpty else {
                continue
            }
            let snippet = firstMatch(
                in: block,
                pattern: #"<(?:a|div)[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|div)>"#
            ).flatMap { $0.first }.map(cleanText) ?? ""
            results.append(PiWebSearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    private static func parseDuckDuckGoResultLinks(_ html: String, maxResults: Int) -> [PiWebSearchResult] {
        let pattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)
        var results: [PiWebSearchResult] = []

        for match in matches {
            guard results.count < maxResults,
                  match.numberOfRanges >= 3,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html)
            else {
                continue
            }
            let rawURL = decodeHTML(String(html[urlRange]))
            let title = cleanText(String(html[titleRange]))
            let url = normalizeDuckDuckGoURL(rawURL)
            guard !title.isEmpty, !url.isEmpty else {
                continue
            }
            results.append(PiWebSearchResult(title: title, url: url))
        }
        return results
    }

    private static func normalizeDuckDuckGoURL(_ rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL),
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
              !uddg.isEmpty
        else {
            return rawURL
        }
        return uddg
    }

    private static func stripHTML(_ value: String) -> String {
        value.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
    }

    private static func cleanText(_ value: String) -> String {
        decodeHTML(stripHTML(value))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(in value: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let captureRange = Range(match.range(at: index), in: value) else {
                return nil
            }
            return String(value[captureRange])
        }
    }

    private static func decodeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

public struct URLSessionPiWebSearchHTTPTransport: PiWebSearchHTTPTransport {
    public init() {}

    public func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        var result: Result<(Data, HTTPURLResponse), Error>?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(PiWebSearchToolError.invalidResponse)
                return
            }
            result = .success((data ?? Data(), httpResponse))
        }
        task.resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()
        guard let result else {
            throw PiWebSearchToolError.invalidResponse
        }
        return try result.get()
    }
}
