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

/// Image input shared by every endpoint that consumes an image
/// (OCR, face detection, barcode/QR detection). Callers provide exactly one of
/// `url`, `base64`, or `file`.
struct ImageRequestPayload: Codable, Equatable {
    var url: String?
    var base64: String?
    var file: String?

    func source() throws -> ImageSource {
        let candidates: [ImageSource] = [
            normalized(url).map(ImageSource.url),
            normalized(base64).map(ImageSource.base64),
            normalized(file).map(ImageSource.file)
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

enum ImageSource: Equatable {
    case url(String)
    case base64(String)
    case file(String)
}

/// Text-to-speech request. `text` is required; the rest tune voice selection
/// and delivery and fall back to system defaults when omitted.
struct TTSRequestPayload: Codable, Equatable {
    var text: String
    var voice: String?
    var language: String?
    var rate: Float?
    var pitch: Float?
    var volume: Float?

    func validated() throws -> TTSRequestPayload {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw APIRequestError.badRequest("text must not be empty")
        }

        return TTSRequestPayload(
            text: trimmedText,
            voice: voice?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            language: language?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            rate: rate,
            pitch: pitch,
            volume: volume
        )
    }
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

/// A normalized rectangle (origin bottom-left, values in 0...1) describing where
/// something was detected within the image, matching Vision's coordinate space.
struct BoundingBox: Encodable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// A normalized 2D point in 0...1, used for facial landmark coordinates.
struct NormalizedPoint: Encodable, Equatable {
    let x: Double
    let y: Double
}

/// A single detected face: where it is, its facial landmark groups (eyes, nose,
/// lips, ...), optional pose angles, and a feature-print vector that can be used
/// to compare/identify faces.
struct FaceObservation: Encodable, Equatable {
    let boundingBox: BoundingBox
    let roll: Double?
    let yaw: Double?
    let pitch: Double?
    let landmarks: [String: [NormalizedPoint]]
    let featureVector: [Float]?
}

/// A single detected barcode or QR code: its decoded payload and symbology
/// (e.g. "VNBarcodeSymbologyQR", "VNBarcodeSymbologyEAN13").
struct BarcodeObservation: Encodable, Equatable {
    let payload: String?
    let symbology: String
    let boundingBox: BoundingBox
}

/// The payload-specific portion of a response (the `data` object). Unused
/// fields are omitted from the encoded JSON (synthesized Encodable skips nil
/// optionals), so an empty instance encodes to `{}`.
struct APIResponseData: Encodable, Equatable {
    let text: String?
    let lines: [String]?
    let html: String?
    let faces: [FaceObservation]?
    let barcodes: [BarcodeObservation]?
    let audio: String?

    init(
        text: String? = nil,
        lines: [String]? = nil,
        html: String? = nil,
        faces: [FaceObservation]? = nil,
        barcodes: [BarcodeObservation]? = nil,
        audio: String? = nil
    ) {
        self.text = text
        self.lines = lines
        self.html = html
        self.faces = faces
        self.barcodes = barcodes
        self.audio = audio
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
/// supported features, show a sample request body, build a copyable URL, and
/// render the `GET /SKILL.md` documentation.
struct APIEndpoint: Identifiable, Equatable {
    let name: String
    /// Primary method shown as the UI badge.
    let method: String
    let path: String
    /// Short one-line description for the settings UI.
    let summary: String
    /// Sample JSON request body shown in the UI and used as the POST example.
    let requestDemo: String
    /// Longer description used by the SKILL.md documentation.
    let details: String
    /// Prose/markdown describing GET query parameters. `nil` means GET is not
    /// supported by this endpoint.
    let getParameters: String?
    /// Example query string (without leading `?`) used to build a GET example.
    let getExampleQuery: String?
    /// Prose/markdown describing the POST JSON body. `nil` means POST is not
    /// supported by this endpoint.
    let postParameters: String?
    /// Markdown describing the response format.
    let responseFormat: String

    init(
        name: String,
        method: String,
        path: String,
        summary: String,
        requestDemo: String,
        details: String = "",
        getParameters: String? = nil,
        getExampleQuery: String? = nil,
        postParameters: String? = nil,
        responseFormat: String = ""
    ) {
        self.name = name
        self.method = method
        self.path = path
        self.summary = summary
        self.requestDemo = requestDemo
        self.details = details
        self.getParameters = getParameters
        self.getExampleQuery = getExampleQuery
        self.postParameters = postParameters
        self.responseFormat = responseFormat
    }

    var id: String { "\(method) \(path)" }

    /// Methods this endpoint accepts, derived from which parameter docs exist.
    var supportedMethods: [String] {
        var methods = [String]()
        if getParameters != nil { methods.append("GET") }
        if postParameters != nil { methods.append("POST") }
        return methods.isEmpty ? [method] : methods
    }

    func address(host: String, port: String) -> String {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let portComponent = trimmedPort.isEmpty ? "" : ":\(trimmedPort)"
        return "http://\(host)\(portComponent)\(path)"
    }

    /// Builds the full address from a base URL (e.g. `http://localhost:8080`),
    /// tolerating a trailing slash.
    func address(baseURL: String) -> String {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return "\(trimmed)\(path)"
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
            """,
            details: "Recognizes text in an image using the Vision framework (`VNRecognizeTextRequest`, accurate recognition level with language correction). Provide the image as a URL, a base64 string, or a local file path — exactly one source.",
            getParameters: """
            | Parameter | Required | Description |
            |---|---|---|
            | `url` | yes | Publicly reachable image URL to download and analyze. |
            """,
            getExampleQuery: "url=https://example.com/image.png",
            postParameters: """
            JSON body with **exactly one** of the following fields:

            | Field | Type | Description |
            |---|---|---|
            | `url` | string | Image URL to download. |
            | `base64` | string | Base64-encoded image data (a `data:` URI prefix is allowed). |
            | `file` | string | Absolute path to a local image file. |
            """,
            responseFormat: """
            `data.text` is all recognized text joined by newlines; `data.lines` is the per-line array.

            ```json
            {
              "success": true,
              "timeCost": 42,
              "data": {
                "text": "line 1\\nline 2",
                "lines": ["line 1", "line 2"]
              },
              "message": ""
            }
            ```
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
            """,
            details: "Translates text using the native macOS Translation framework. Requires macOS 15 or later (otherwise returns a 500 error). `from` is optional — when omitted the system detects the source language.",
            getParameters: """
            | Parameter | Required | Description |
            |---|---|---|
            | `text` | yes | Text to translate. |
            | `to` | yes | Target language code (e.g. `zh`, `ja`, `fr`). |
            | `from` | no | Source language code; auto-detected when omitted. |
            """,
            getExampleQuery: "text=Hello,%20world&from=en&to=zh",
            postParameters: """
            | Field | Type | Required | Description |
            |---|---|---|---|
            | `text` | string | yes | Text to translate. |
            | `to` | string | yes | Target language code. |
            | `from` | string | no | Source language code; auto-detected when omitted. |
            """,
            responseFormat: """
            `data.text` holds the translated text.

            ```json
            {
              "success": true,
              "timeCost": 88,
              "data": { "text": "你好，世界" },
              "message": ""
            }
            ```
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
            """,
            details: "Loads a URL in a headless WebKit `WKWebView` and returns the fully rendered HTML after the page settles. `waitUntil` selects the readiness signal; `timeout` (milliseconds) caps the wait and returns whatever HTML is available when reached (`0` returns immediately).",
            getParameters: """
            | Parameter | Required | Description |
            |---|---|---|
            | `url` | yes | Absolute URL to load. |
            | `waitUntil` | no | One of `domcontentloaded` (default), `networkidle0`, `networkidle2`. |
            | `timeout` | no | Non-negative milliseconds to wait. Default `30000`. |
            """,
            getExampleQuery: "url=https://example.com&waitUntil=networkidle0&timeout=30000",
            postParameters: """
            | Field | Type | Required | Description |
            |---|---|---|---|
            | `url` | string | yes | Absolute URL to load. |
            | `gotoOptions.waitUntil` | string | no | `domcontentloaded` / `networkidle0` / `networkidle2`. |
            | `gotoOptions.timeout` | number | no | Non-negative milliseconds. Default `30000`. |
            """,
            responseFormat: """
            `data.html` contains the rendered outer HTML of the document.

            ```json
            {
              "success": true,
              "timeCost": 1203,
              "data": { "html": "<!doctype html>..." },
              "message": ""
            }
            ```
            """
        ),
        APIEndpoint(
            name: "Face Detection",
            method: "POST",
            path: "/api/face",
            summary: "Detect faces with Vision and return bounding boxes, facial landmarks, and a feature vector per face. Provide exactly one of url / base64 / file. GET supported via ?url=",
            requestDemo: """
            {
              "url": "https://example.com/photo.jpg"
            }
            """,
            details: "Detects faces using Vision (`VNDetectFaceLandmarksRequest`). For each face it returns a normalized bounding box, pose angles (`roll` / `yaw` / `pitch` in radians, may be null), named facial-landmark point groups (coordinates normalized within the face bounding box), and a `featureVector` (a Vision feature print of the face region) suitable for comparing faces.",
            getParameters: """
            | Parameter | Required | Description |
            |---|---|---|
            | `url` | yes | Publicly reachable image URL to analyze. |
            """,
            getExampleQuery: "url=https://example.com/photo.jpg",
            postParameters: """
            JSON body with **exactly one** of `url`, `base64`, or `file` (same as OCR).
            """,
            responseFormat: """
            `data.faces` is an array. Coordinates are normalized to `0...1` with the origin at the bottom-left, matching Vision. `featureVector` may be `null` if the feature print could not be generated.

            ```json
            {
              "success": true,
              "timeCost": 130,
              "data": {
                "faces": [
                  {
                    "boundingBox": { "x": 0.31, "y": 0.42, "width": 0.2, "height": 0.27 },
                    "roll": 0.05,
                    "yaw": -0.12,
                    "pitch": 0.0,
                    "landmarks": {
                      "leftEye": [ { "x": 0.4, "y": 0.6 } ],
                      "nose": [ { "x": 0.5, "y": 0.5 } ]
                    },
                    "featureVector": [0.12, 0.98, ...]
                  }
                ]
              },
              "message": ""
            }
            ```
            """
        ),
        APIEndpoint(
            name: "QR / Barcode",
            method: "POST",
            path: "/api/qrcode",
            summary: "Detect QR codes and barcodes with Vision and return their decoded payloads and symbologies. Provide exactly one of url / base64 / file. GET supported via ?url=",
            requestDemo: """
            {
              "url": "https://example.com/qr.png"
            }
            """,
            details: "Detects QR codes and barcodes using Vision (`VNDetectBarcodesRequest`). Returns every detected code with its decoded payload, symbology identifier, and bounding box.",
            getParameters: """
            | Parameter | Required | Description |
            |---|---|---|
            | `url` | yes | Publicly reachable image URL to analyze. |
            """,
            getExampleQuery: "url=https://example.com/qr.png",
            postParameters: """
            JSON body with **exactly one** of `url`, `base64`, or `file` (same as OCR).
            """,
            responseFormat: """
            `data.barcodes` is an array. `payload` is the decoded string (may be `null` if undecodable); `symbology` identifies the code type (e.g. `VNBarcodeSymbologyQR`, `VNBarcodeSymbologyEAN13`).

            ```json
            {
              "success": true,
              "timeCost": 35,
              "data": {
                "barcodes": [
                  {
                    "payload": "https://example.com",
                    "symbology": "VNBarcodeSymbologyQR",
                    "boundingBox": { "x": 0.1, "y": 0.1, "width": 0.4, "height": 0.4 }
                  }
                ]
              },
              "message": ""
            }
            ```
            """
        ),
        APIEndpoint(
            name: "Text to Speech",
            method: "POST",
            path: "/api/tts",
            summary: "Synthesize speech from text and return base64-encoded audio. \"voice\", \"language\", \"rate\", \"pitch\", and \"volume\" are optional. GET supported via ?text=",
            requestDemo: """
            {
              "text": "Hello, world",
              "language": "en-US"
            }
            """,
            details: "Synthesizes speech from text using `AVSpeechSynthesizer` and returns base64-encoded WAV audio. Only `text` is required; the rest tune voice selection and delivery.",
            getParameters: """
            | Parameter | Required | Description |
            |---|---|---|
            | `text` | yes | Text to speak. |
            | `language` | no | BCP-47 language code (e.g. `en-US`, `zh-CN`). |
            | `voice` | no | Specific `AVSpeechSynthesisVoice` identifier. |
            | `rate` | no | Speech rate (`0.0`–`1.0`). |
            | `pitch` | no | Pitch multiplier (`0.5`–`2.0`). |
            | `volume` | no | Volume (`0.0`–`1.0`). |
            """,
            getExampleQuery: "text=Hello,%20world&language=en-US",
            postParameters: """
            | Field | Type | Required | Description |
            |---|---|---|---|
            | `text` | string | yes | Text to speak. |
            | `language` | string | no | BCP-47 language code. |
            | `voice` | string | no | `AVSpeechSynthesisVoice` identifier. |
            | `rate` | number | no | Speech rate (`0.0`–`1.0`). |
            | `pitch` | number | no | Pitch multiplier (`0.5`–`2.0`). |
            | `volume` | number | no | Volume (`0.0`–`1.0`). |
            """,
            responseFormat: """
            `data.audio` is a base64-encoded WAV file.

            ```json
            {
              "success": true,
              "timeCost": 210,
              "data": { "audio": "UklGRi...=" },
              "message": ""
            }
            ```
            """
        ),
        APIEndpoint(
            name: "Skill Documentation",
            method: "GET",
            path: "/SKILL.md",
            summary: "Return this Markdown describing every endpoint: address, parameters, and response format. Addresses reflect the current host and port.",
            requestDemo: "(no request body)",
            details: "Returns this Markdown document describing every available skill/endpoint. The addresses shown reflect the host and port you used to reach the server, so they stay correct when the port changes.",
            getParameters: "No parameters.",
            getExampleQuery: nil,
            postParameters: nil,
            responseFormat: "Returns `text/markdown` (this document) directly, not the JSON envelope used by the `/api/*` endpoints."
        )
    ]
}

/// Renders the `GET /SKILL.md` document from the endpoint catalog. Addresses are
/// built from a runtime `baseURL` so they reflect the current host and port.
enum SkillDocument {
    static func markdown(baseURL: String, endpoints: [APIEndpoint] = APIEndpoint.all) -> String {
        var sections = [String]()
        sections.append("""
        # OpenMac Skills

        OpenMac runs a local HTTP server that exposes native macOS capabilities (Vision, Translation, WebKit, AVFoundation) as simple HTTP APIs.

        - **Base URL:** `\(normalizedBaseURL(baseURL))`
        - Every `/api/*` endpoint returns a JSON envelope: `{ "success": boolean, "timeCost": number, "data": object, "message": string }`. On success `success` is `true` and the endpoint-specific payload is in `data`; on error `success` is `false`, `data` is `{}`, and `message` explains why.
        - `timeCost` is the server processing time in milliseconds.
        """)

        for endpoint in endpoints {
            sections.append(section(for: endpoint, baseURL: baseURL))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func section(for endpoint: APIEndpoint, baseURL: String) -> String {
        let address = endpoint.address(baseURL: baseURL)
        var lines = [String]()
        lines.append("## \(endpoint.name)")
        lines.append("")
        if !endpoint.details.isEmpty {
            lines.append(endpoint.details)
            lines.append("")
        }
        lines.append("- **Path:** `\(endpoint.path)`")
        lines.append("- **Address:** `\(address)`")
        lines.append("- **Methods:** \(endpoint.supportedMethods.joined(separator: ", "))")

        if let getParameters = endpoint.getParameters {
            lines.append("")
            lines.append("### GET")
            lines.append(getParameters)
            let exampleURL: String
            if let query = endpoint.getExampleQuery, !query.isEmpty {
                exampleURL = "\(address)?\(query)"
            } else {
                exampleURL = address
            }
            lines.append("")
            lines.append("Example:")
            lines.append("```bash")
            lines.append("curl \"\(exampleURL)\"")
            lines.append("```")
        }

        if let postParameters = endpoint.postParameters {
            lines.append("")
            lines.append("### POST")
            lines.append(postParameters)
            lines.append("")
            lines.append("Example:")
            lines.append("```bash")
            lines.append("curl -X POST \"\(address)\" \\")
            lines.append("  -H \"Content-Type: application/json\" \\")
            lines.append("  -d '\(compactJSON(endpoint.requestDemo))'")
            lines.append("```")
        }

        if !endpoint.responseFormat.isEmpty {
            lines.append("")
            lines.append("### Response")
            lines.append(endpoint.responseFormat)
        }

        return lines.joined(separator: "\n")
    }

    private static func normalizedBaseURL(_ baseURL: String) -> String {
        baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    /// Collapses a pretty-printed JSON sample into a single line for use in a
    /// shell `curl` example. Falls back to a newline-stripped version if the
    /// sample is not valid JSON.
    private static func compactJSON(_ string: String) -> String {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let result = String(data: compact, encoding: .utf8) else {
            return string.replacingOccurrences(of: "\n", with: " ")
        }

        // JSONSerialization escapes "/" as "\/"; unescape for a cleaner example.
        return result.replacingOccurrences(of: "\\/", with: "/")
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
    /// Decodes an image-input request (OCR, face, barcode). For GET, requires
    /// `?url=`; for POST, requires a JSON body with exactly one of
    /// url / base64 / file. `path` is used only to build helpful error messages.
    static func decodeImageRequest(from request: HTTPRequestMessage, path: String) throws -> ImageRequestPayload {
        switch request.method {
        case .get:
            guard let url = queryItem(named: "url", in: request.queryItems), !url.isEmpty else {
                throw APIRequestError.badRequest("GET \(path) requires ?url=")
            }

            return ImageRequestPayload(url: url, base64: nil, file: nil)
        case .post:
            let payload = try decodeJSON(ImageRequestPayload.self, from: request.body)
            _ = try payload.source()
            return payload
        }
    }

    static func decodeTTSRequest(from request: HTTPRequestMessage) throws -> TTSRequestPayload {
        switch request.method {
        case .get:
            guard let text = queryItem(named: "text", in: request.queryItems), !text.isEmpty else {
                throw APIRequestError.badRequest("GET /api/tts requires ?text=")
            }

            return try TTSRequestPayload(
                text: text,
                voice: queryItem(named: "voice", in: request.queryItems),
                language: queryItem(named: "language", in: request.queryItems),
                rate: queryItem(named: "rate", in: request.queryItems).flatMap(Float.init),
                pitch: queryItem(named: "pitch", in: request.queryItems).flatMap(Float.init),
                volume: queryItem(named: "volume", in: request.queryItems).flatMap(Float.init)
            ).validated()
        case .post:
            let payload = try decodeJSON(TTSRequestPayload.self, from: request.body)
            return try payload.validated()
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
