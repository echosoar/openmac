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

struct HTTPRequestMessage: Equatable {
    var method: HTTPMethod
    var target: String
    var path: String
    var queryItems: [URLQueryItem]
    var headers: [String: String]
    var body: Data
}

struct APIResponseBody: Encodable, Equatable {
    let text: String?
    let lines: [String]?
    let html: String?
    let error: String?

    init(text: String? = nil, lines: [String]? = nil, html: String? = nil, error: String? = nil) {
        self.text = text
        self.lines = lines
        self.html = html
        self.error = error
    }
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

    private static func queryItem(named name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HTTPResponseBuilder {
    static func json(statusCode: Int = 200, body: APIResponseBody) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData = (try? encoder.encode(body)) ?? Data("{\"error\":\"Encoding error\"}".utf8)
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
