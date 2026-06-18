import Foundation
import Testing
@testable import openmac

@Test func parsesCompleteHTTPRequestBuffer() throws {
    let raw = Data("POST /api/ocr HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\n{\"url\":\"x\"}".utf8)

    let parsed = try #require(try HTTPRequestParser.parse(buffer: raw))

    #expect(parsed.request.method == .post)
    #expect(parsed.request.path == "/api/ocr")
    #expect(String(data: parsed.request.body, encoding: .utf8) == "{\"url\":\"x\"}")
}

@Test func leavesIncompleteHTTPRequestPending() throws {
    let raw = Data("POST /api/ocr HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"url\":\"short\"}".utf8)
    #expect(try HTTPRequestParser.parse(buffer: raw) == nil)
}

@Test func decodesGetImageRequestFromQuery() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/ocr?url=https://example.com/image.png",
        path: "/api/ocr",
        queryItems: [URLQueryItem(name: "url", value: "https://example.com/image.png")],
        headers: [:],
        body: Data()
    )

    let payload = try APIRequestDecoder.decodeImageRequest(from: request, path: request.path)

    #expect(payload == ImageRequestPayload(url: "https://example.com/image.png", base64: nil, file: nil))
    #expect(try payload.source() == .url("https://example.com/image.png"))
}

@Test func rejectsMultipleImageSources() throws {
    let payload = ImageRequestPayload(url: "https://example.com/a.png", base64: "abc", file: nil)

    #expect(throws: APIRequestError.self) {
        _ = try payload.source()
    }
}

@Test func decodesGetFaceRequestFromQuery() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/face?url=https://example.com/photo.jpg",
        path: "/api/face",
        queryItems: [URLQueryItem(name: "url", value: "https://example.com/photo.jpg")],
        headers: [:],
        body: Data()
    )

    let payload = try APIRequestDecoder.decodeImageRequest(from: request, path: request.path)

    #expect(try payload.source() == .url("https://example.com/photo.jpg"))
}

@Test func rejectsGetImageRequestWithoutURL() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/qrcode",
        path: "/api/qrcode",
        queryItems: [],
        headers: [:],
        body: Data()
    )

    #expect(throws: APIRequestError.self) {
        _ = try APIRequestDecoder.decodeImageRequest(from: request, path: request.path)
    }
}

@Test func decodesGetTTSRequestFromQuery() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/tts?text=Hello&language=en-US&rate=0.5",
        path: "/api/tts",
        queryItems: [
            URLQueryItem(name: "text", value: "Hello"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "rate", value: "0.5")
        ],
        headers: [:],
        body: Data()
    )

    let payload = try APIRequestDecoder.decodeTTSRequest(from: request)

    #expect(payload.text == "Hello")
    #expect(payload.language == "en-US")
    #expect(payload.rate == 0.5)
}

@Test func decodesPostTTSRequestBody() throws {
    let request = HTTPRequestMessage(
        method: .post,
        target: "/api/tts",
        path: "/api/tts",
        queryItems: [],
        headers: ["content-type": "application/json"],
        body: Data("{\"text\":\"Hello, world\",\"language\":\"en-US\"}".utf8)
    )

    let payload = try APIRequestDecoder.decodeTTSRequest(from: request)

    #expect(payload.text == "Hello, world")
    #expect(payload.language == "en-US")
}

@Test func rejectsEmptyTTSText() throws {
    let request = HTTPRequestMessage(
        method: .post,
        target: "/api/tts",
        path: "/api/tts",
        queryItems: [],
        headers: ["content-type": "application/json"],
        body: Data("{\"text\":\"   \"}".utf8)
    )

    #expect(throws: APIRequestError.self) {
        _ = try APIRequestDecoder.decodeTTSRequest(from: request)
    }
}

@Test func decodesGetWebContentRequestWithDefaults() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/web-content?url=https://example.com",
        path: "/api/web-content",
        queryItems: [URLQueryItem(name: "url", value: "https://example.com")],
        headers: [:],
        body: Data()
    )

    let payload = try APIRequestDecoder.decodeWebContentRequest(from: request)

    #expect(payload.url == "https://example.com")
    #expect(payload.gotoOptions == nil)
    let options = try payload.resolvedOptions()
    #expect(options.waitUntil == .domcontentloaded)
    #expect(options.timeout == 30_000)
}

@Test func decodesPostWebContentRequestOptions() throws {
    let request = HTTPRequestMessage(
        method: .post,
        target: "/api/web-content",
        path: "/api/web-content",
        queryItems: [],
        headers: ["content-type": "application/json"],
        body: Data("{\"url\":\"https://example.com\",\"gotoOptions\":{\"waitUntil\":\"networkidle2\",\"timeout\":1234}}".utf8)
    )

    let payload = try APIRequestDecoder.decodeWebContentRequest(from: request)

    #expect(payload.url == "https://example.com")
    let options = try payload.resolvedOptions()
    #expect(options.waitUntil == .networkidle2)
    #expect(options.timeout == 1234)
}

@Test func rejectsInvalidWaitUntilValue() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/web-content?url=https://example.com&waitUntil=idle",
        path: "/api/web-content",
        queryItems: [
            URLQueryItem(name: "url", value: "https://example.com"),
            URLQueryItem(name: "waitUntil", value: "idle")
        ],
        headers: [:],
        body: Data()
    )

    #expect(throws: APIRequestError.self) {
        _ = try APIRequestDecoder.decodeWebContentRequest(from: request)
    }
}

@Test func rejectsNegativeTimeoutInPostWebContentRequest() throws {
    let request = HTTPRequestMessage(
        method: .post,
        target: "/api/web-content",
        path: "/api/web-content",
        queryItems: [],
        headers: ["content-type": "application/json"],
        body: Data("{\"url\":\"https://example.com\",\"gotoOptions\":{\"timeout\":-1}}".utf8)
    )

    #expect(throws: APIRequestError.self) {
        _ = try APIRequestDecoder.decodeWebContentRequest(from: request)
    }
}
