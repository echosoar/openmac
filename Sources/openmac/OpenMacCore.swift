import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
}

enum WaitUntilMode: String, Codable, CaseIterable {
    case domcontentloaded
    case networkidle0
    case networkidle2

    init(value: String?) throws {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else {
            self = .domcontentloaded
            return
        }

        guard let mode = WaitUntilMode(rawValue: normalized) else {
            throw APIRequestError.badRequest("Unsupported waitUntil value: \(normalized)")
        }

        self = mode
    }
}

struct GotoOptions: Codable, Equatable {
    var waitUntil: WaitUntilMode?
    var timeout: Int?

    var resolvedWaitUntil: WaitUntilMode {
        waitUntil ?? .domcontentloaded
    }

    var resolvedTimeout: Int {
        timeout ?? 30_000
    }

    func validated() throws -> GotoOptions {
        guard resolvedTimeout >= 0 else {
            throw APIRequestError.badRequest("timeout must be a non-negative integer")
        }

        return GotoOptions(waitUntil: resolvedWaitUntil, timeout: resolvedTimeout)
    }
}

struct OCRRequestPayload: Codable, Equatable {
    var url: String?
    var base64: String?
    var file: String?

    func source() throws -> OCRSource {
        let candidates: [OCRSource] = [
            normalized(url).map(OCRSource.url),
            normalized(base64).map(OCRSource.base64),
            normalized(file).map(OCRSource.file)
        ].compactMap { $0 }

        guard candidates.count == 1, let source = candidates.first else {
            throw APIRequestError.badRequest("Provide exactly one of url, base64, or file")
        }

        return source
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}

enum OCRSource: Equatable {
    case url(String)
    case base64(String)
    case file(String)
}

struct WebContentRequestPayload: Codable, Equatable {
    var url: String
    var gotoOptions: GotoOptions?

    func resolvedOptions() throws -> GotoOptions {
        try gotoOptions?.validated() ?? GotoOptions(waitUntil: .domcontentloaded, timeout: 30_000).validated()
    }
}

struct SearchRequestPayload: Codable, Equatable {
    var text: String
    var engines: [String]?
    var count: Int?
    var excludeDomains: [String]?

    /// Engines queried when the caller does not specify `engines`.
    static let defaultEngines = ["bing", "baidu", "brave"]
    /// Search engines that can be scraped via the headless WebView.
    static let supportedEngines = [
        "baidu", "bing", "brave", "duckduckgo", "google", "sogou", "wikipedia", "arxiv"
    ]
    static let defaultCount = 3
    /// Upper bound on results requested per engine, mirroring RACT's behaviour.
    static let maxCount = 6

    var resolvedEngines: [String] {
        let normalized = (engines ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let candidates = normalized.isEmpty ? Self.defaultEngines : normalized
        // Preserve order while removing duplicates.
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    var resolvedCount: Int {
        let requested = count ?? Self.defaultCount
        return max(1, min(requested, Self.maxCount))
    }

    var resolvedExcludeDomains: [String] {
        (excludeDomains ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func validated() throws -> SearchRequestPayload {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw APIRequestError.badRequest("text must not be empty")
        }

        if let count, count <= 0 {
            throw APIRequestError.badRequest("count must be a positive integer")
        }

        let resolved = resolvedEngines
        let unsupported = resolved.filter { !Self.supportedEngines.contains($0) }
        guard unsupported.isEmpty else {
            throw APIRequestError.badRequest("Unsupported engines: \(unsupported.joined(separator: ", ")). Supported: \(Self.supportedEngines.joined(separator: ", "))")
        }

        return SearchRequestPayload(
            text: trimmedText,
            engines: resolved,
            count: resolvedCount,
            excludeDomains: resolvedExcludeDomains
        )
    }
}

struct HTTPRequestMessage: Equatable {
    var method: HTTPMethod
    var target: String
    var path: String
    var queryItems: [URLQueryItem]
    var headers: [String: String]
    var body: Data
}

/// A single search hit extracted from a search engine results page.
struct SearchResultItem: Encodable, Equatable {
    let title: String
    let description: String
    let url: String
}

/// The results returned by one search engine, plus how long that engine took.
struct SearchEngineResult: Encodable, Equatable {
    let engine: String
    let results: [SearchResultItem]
    /// Time spent on this engine, in milliseconds.
    let duration: Int
}

/// The payload-specific portion of a response (the `data` object). Unused
/// fields are omitted from the encoded JSON (synthesized Encodable skips nil
/// optionals), so an empty instance encodes to `{}`.
struct APIResponseData: Encodable, Equatable {
    let text: String?
    let lines: [String]?
    let html: String?
    let engines: [SearchEngineResult]?

    init(text: String? = nil, lines: [String]? = nil, html: String? = nil, engines: [SearchEngineResult]? = nil) {
        self.text = text
        self.lines = lines
        self.html = html
        self.engines = engines
    }
}

/// Uniform envelope returned by every endpoint:
/// `{ success, timeCost (ms), data, message }`.
struct APIResponse: Encodable, Equatable {
    let success: Bool
    let timeCost: Int
    let data: APIResponseData
    let message: String
}

struct TranslateRequestPayload: Codable, Equatable {
    var text: String
    var from: String?
    var to: String

    func validated() throws -> TranslateRequestPayload {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw APIRequestError.badRequest("text must not be empty")
        }
        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTo.isEmpty else {
            throw APIRequestError.badRequest("to language must not be empty")
        }
        return TranslateRequestPayload(
            text: trimmedText,
            from: from?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            to: trimmedTo
        )
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

/// Metadata describing a public API endpoint, used by the settings UI to list
/// supported features, show a sample request body, and build a copyable URL.
struct APIEndpoint: Identifiable, Equatable {
    let name: String
    let method: String
    let path: String
    let summary: String
    let requestDemo: String

    var id: String { "\(method) \(path)" }

    func address(host: String, port: String) -> String {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let portComponent = trimmedPort.isEmpty ? "" : ":\(trimmedPort)"
        return "http://\(host)\(portComponent)\(path)"
    }

    static let all: [APIEndpoint] = [
        APIEndpoint(
            name: "OCR / Text Recognition",
            method: "POST",
            path: "/api/ocr",
            summary: "Recognize text in an image. Provide exactly one of url / base64 / file. GET supported via ?url=",
            requestDemo: """
            {
              "url": "https://example.com/image.png"
            }
            """
        ),
        APIEndpoint(
            name: "Translate",
            method: "POST",
            path: "/api/translate",
            summary: "Translate text with the native macOS Translation framework (macOS 15+). \"from\" is optional. GET supported via ?text=&to=&from=",
            requestDemo: """
            {
              "text": "Hello, world",
              "from": "en",
              "to": "zh"
            }
            """
        ),
        APIEndpoint(
            name: "Web Content",
            method: "POST",
            path: "/api/web-content",
            summary: "Load a page in a headless WebView and return its rendered HTML. GET supported via ?url=&waitUntil=&timeout=",
            requestDemo: """
            {
              "url": "https://example.com",
              "gotoOptions": {
                "waitUntil": "networkidle0",
                "timeout": 30000
              }
            }
            """
        ),
        APIEndpoint(
            name: "Web Search",
            method: "POST",
            path: "/api/search",
            summary: "Search the web through headless WebViews across multiple engines. Only \"text\" is required. GET supported via ?text=&engines=bing,brave&count=3&excludeDomains=baidu.com",
            requestDemo: """
            {
              "text": "swift concurrency",
              "engines": ["bing", "brave"],
              "count": 3,
              "excludeDomains": ["baidu.com"]
            }
            """
        )
    ]
}

enum APIRequestError: Error, Equatable, LocalizedError {
    case badRequest(String)
    case notFound(String)
    case methodNotAllowed(String)
    case internalError(String)

    var statusCode: Int {
        switch self {
        case .badRequest:
            return 400
        case .notFound:
            return 404
        case .methodNotAllowed:
            return 405
        case .internalError:
            return 500
        }
    }

    var message: String {
        switch self {
        case let .badRequest(message),
            let .notFound(message),
            let .methodNotAllowed(message),
            let .internalError(message):
            return message
        }
    }

    var errorDescription: String? {
        message
    }
}

enum HTTPRequestParser {
    static func parse(buffer: Data) throws -> (request: HTTPRequestMessage, consumedLength: Int)? {
        guard let separatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) ?? buffer.range(of: Data("\n\n".utf8)) else {
            return nil
        }

        let headerData = buffer[..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw APIRequestError.badRequest("Invalid HTTP header encoding")
        }

        let headerLines = headerText.split(whereSeparator: \.isNewline).map(String.init)
        guard let requestLine = headerLines.first else {
            throw APIRequestError.badRequest("Missing HTTP request line")
        }

        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2,
              let method = HTTPMethod(rawValue: String(requestLineParts[0])) else {
            throw APIRequestError.badRequest("Unsupported HTTP request line")
        }

        let target = String(requestLineParts[1])
        let headers = parseHeaders(from: Array(headerLines.dropFirst()))
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0

        let totalLength = separatorRange.upperBound + contentLength
        guard buffer.count >= totalLength else {
            return nil
        }

        let body = buffer[separatorRange.upperBound..<totalLength]
        let urlComponents = URLComponents(string: target)
        let path: String
        if let parsedPath = urlComponents?.path, !parsedPath.isEmpty {
            path = parsedPath
        } else {
            path = target
        }

        return (
            request: HTTPRequestMessage(
                method: method,
                target: target,
                path: path,
                queryItems: urlComponents?.queryItems ?? [],
                headers: headers,
                body: Data(body)
            ),
            consumedLength: totalLength
        )
    }

    private static func parseHeaders(from headerLines: [String]) -> [String: String] {
        headerLines.reduce(into: [String: String]()) { partialResult, line in
            guard let separator = line.firstIndex(of: ":") else {
                return
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            partialResult[key] = value
        }
    }
}

enum APIRequestDecoder {
    static func decodeOCRRequest(from request: HTTPRequestMessage) throws -> OCRRequestPayload {
        switch request.method {
        case .get:
            guard let url = queryItem(named: "url", in: request.queryItems), !url.isEmpty else {
                throw APIRequestError.badRequest("GET /api/ocr requires ?url=")
            }

            return OCRRequestPayload(url: url, base64: nil, file: nil)
        case .post:
            let payload = try decodeJSON(OCRRequestPayload.self, from: request.body)
            _ = try payload.source()
            return payload
        }
    }

    static func decodeTranslateRequest(from request: HTTPRequestMessage) throws -> TranslateRequestPayload {
        switch request.method {
        case .get:
            guard let text = queryItem(named: "text", in: request.queryItems), !text.isEmpty else {
                throw APIRequestError.badRequest("GET /api/translate requires ?text=")
            }
            guard let to = queryItem(named: "to", in: request.queryItems), !to.isEmpty else {
                throw APIRequestError.badRequest("GET /api/translate requires ?to=")
            }
            let from = queryItem(named: "from", in: request.queryItems)
            return try TranslateRequestPayload(text: text, from: from, to: to).validated()
        case .post:
            let payload = try decodeJSON(TranslateRequestPayload.self, from: request.body)
            return try payload.validated()
        }
    }

    static func decodeSearchRequest(from request: HTTPRequestMessage) throws -> SearchRequestPayload {
        switch request.method {
        case .get:
            guard let text = queryItem(named: "text", in: request.queryItems), !text.isEmpty else {
                throw APIRequestError.badRequest("GET /api/search requires ?text=")
            }

            let engines = parseList(queryItem(named: "engines", in: request.queryItems))
            let excludeDomains = parseList(queryItem(named: "excludeDomains", in: request.queryItems))
            let count = try parseCount(queryItem(named: "count", in: request.queryItems))

            return try SearchRequestPayload(
                text: text,
                engines: engines,
                count: count,
                excludeDomains: excludeDomains
            ).validated()
        case .post:
            let payload = try decodeJSON(SearchRequestPayload.self, from: request.body)
            return try payload.validated()
        }
    }

    static func decodeWebContentRequest(from request: HTTPRequestMessage) throws -> WebContentRequestPayload {
        switch request.method {
        case .get:
            guard let url = queryItem(named: "url", in: request.queryItems), !url.isEmpty else {
                throw APIRequestError.badRequest("GET /api/web-content requires ?url=")
            }

            let waitUntilQuery = queryItem(named: "waitUntil", in: request.queryItems)
            let timeout = try parseTimeout(queryItem(named: "timeout", in: request.queryItems))
            let gotoOptions: GotoOptions?
            if waitUntilQuery != nil || timeout != nil {
                gotoOptions = GotoOptions(waitUntil: try WaitUntilMode(value: waitUntilQuery), timeout: timeout)
            } else {
                gotoOptions = nil
            }
            return WebContentRequestPayload(
                url: url,
                gotoOptions: gotoOptions
            )
        case .post:
            let payload = try decodeJSON(WebContentRequestPayload.self, from: request.body)
            guard !payload.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIRequestError.badRequest("url is required")
            }

            if let gotoOptions = payload.gotoOptions {
                _ = try gotoOptions.validated()
            }

            return payload
        }
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        guard !body.isEmpty else {
            throw APIRequestError.badRequest("Request body must be valid JSON")
        }

        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw APIRequestError.badRequest("Request body must be valid JSON")
        }
    }

    private static func parseTimeout(_ value: String?) throws -> Int? {
        guard let value, !value.isEmpty else {
            return nil
        }

        guard let timeout = Int(value), timeout >= 0 else {
            throw APIRequestError.badRequest("timeout must be a non-negative integer")
        }

        return timeout
    }

    /// Parses a comma-separated query value (e.g. `engines=bing,brave`) into a
    /// trimmed, non-empty list, or `nil` when the parameter is absent/blank.
    private static func parseList(_ value: String?) -> [String]? {
        guard let value, !value.isEmpty else {
            return nil
        }

        let items = value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    private static func parseCount(_ value: String?) throws -> Int? {
        guard let value, !value.isEmpty else {
            return nil
        }

        guard let count = Int(value), count > 0 else {
            throw APIRequestError.badRequest("count must be a positive integer")
        }

        return count
    }

    private static func queryItem(named name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Generates a Markdown "skill" document that explains every public endpoint
/// and how to call it, with the user-configured port baked into all example
/// URLs. Served at `GET /SKILL.md` so an AI agent (or human) can discover the
/// full capability set of a running OpenMac instance.
enum SkillDocument {
    static let contentType = "text/markdown; charset=utf-8"

    /// Builds the Markdown document for a server reachable at `host:port`.
    static func markdown(host: String = "127.0.0.1", port: String) -> String {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let portComponent = trimmedPort.isEmpty ? "" : ":\(trimmedPort)"
        let baseURL = "http://\(host)\(portComponent)"

        var lines: [String] = []
        lines.append("# OpenMac Skill")
        lines.append("")
        lines.append("OpenMac runs a local HTTP server on this Mac that exposes native macOS capabilities — OCR, translation, headless web-page rendering, and multi-engine web search — over a simple JSON API.")
        lines.append("")
        lines.append("- Base URL: `\(baseURL)`")
        lines.append("- Configured port: `\(trimmedPort.isEmpty ? "(default)" : trimmedPort)`")
        lines.append("- Every endpoint accepts `POST` with a JSON body. Most also accept `GET` with query parameters.")
        lines.append("- All JSON endpoints share the response envelope described below.")
        lines.append("")
        lines.append("## Response envelope")
        lines.append("")
        lines.append("```json")
        lines.append("""
        {
          "success": true,
          "timeCost": 123,
          "data": {},
          "message": ""
        }
        """)
        lines.append("```")
        lines.append("")
        lines.append("- `success`: whether the request succeeded.")
        lines.append("- `timeCost`: server processing time in milliseconds.")
        lines.append("- `data`: endpoint-specific payload (described per endpoint below).")
        lines.append("- `message`: human-readable error description when `success` is `false`.")
        lines.append("")
        lines.append("## Endpoints")
        lines.append("")

        for endpoint in APIEndpoint.all {
            let url = endpoint.address(host: host, port: port)
            let methods = endpoint.summary.contains("GET") ? "\(endpoint.method), GET" : endpoint.method

            lines.append("### \(endpoint.name)")
            lines.append("")
            lines.append("- Methods: `\(methods)`")
            lines.append("- URL: `\(url)`")
            lines.append("- \(endpoint.summary)")
            lines.append("")
            lines.append("Example request body:")
            lines.append("")
            lines.append("```json")
            lines.append(endpoint.requestDemo)
            lines.append("```")
            lines.append("")
            lines.append("Example call:")
            lines.append("")
            lines.append("```bash")
            lines.append("curl -X \(endpoint.method) '\(url)' \\")
            lines.append("  -H 'Content-Type: application/json' \\")
            lines.append("  -d '\(compactJSON(endpoint.requestDemo))'")
            lines.append("```")
            lines.append("")
        }

        lines.append("### Skill document")
        lines.append("")
        lines.append("- Methods: `GET`")
        lines.append("- URL: `\(baseURL)/SKILL.md`")
        lines.append("- Returns this Markdown document describing every available capability, with this instance's configured port already filled in.")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// Collapses a pretty-printed JSON sample into a single line suitable for an
    /// inline `curl -d` argument. Falls back to a whitespace-stripped version if
    /// the sample is not valid JSON.
    private static func compactJSON(_ json: String) -> String {
        if let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let string = String(data: compact, encoding: .utf8) {
            // JSONSerialization escapes forward slashes (`\/`); unescape them for
            // more readable example URLs (both forms are valid JSON).
            return string.replacingOccurrences(of: "\\/", with: "/")
        }

        return json
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
    }
}

enum HTTPResponseBuilder {
    /// Build a success response: `success=true`, the given `data`, empty message.
    static func success(statusCode: Int = 200, timeCost: Int, data: APIResponseData) -> Data {
        encode(statusCode: statusCode, response: APIResponse(success: true, timeCost: timeCost, data: data, message: ""))
    }

    /// Build an error response: `success=false`, empty `data` object, `message`.
    static func failure(statusCode: Int, timeCost: Int, message: String) -> Data {
        encode(statusCode: statusCode, response: APIResponse(success: false, timeCost: timeCost, data: APIResponseData(), message: message))
    }

    static func encode(statusCode: Int, response: APIResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fallback = "{\"data\":{},\"message\":\"Encoding error\",\"success\":false,\"timeCost\":0}"
        let bodyData = (try? encoder.encode(response)) ?? Data(fallback.utf8)
        return build(statusCode: statusCode, contentType: "application/json; charset=utf-8", body: bodyData)
    }

    static func build(statusCode: Int, contentType: String, body: Data) -> Data {
        let response = [
            "HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        case 405:
            return "Method Not Allowed"
        default:
            return "Internal Server Error"
        }
    }
}
