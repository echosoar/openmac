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

@Test func decodesGetOCRRequestFromQuery() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/ocr?url=https://example.com/image.png",
        path: "/api/ocr",
        queryItems: [URLQueryItem(name: "url", value: "https://example.com/image.png")],
        headers: [:],
        body: Data()
    )

    let payload = try APIRequestDecoder.decodeOCRRequest(from: request)

    #expect(payload == OCRRequestPayload(url: "https://example.com/image.png", base64: nil, file: nil))
    #expect(try payload.source() == .url("https://example.com/image.png"))
}

@Test func rejectsMultipleOCRSources() throws {
    let payload = OCRRequestPayload(url: "https://example.com/a.png", base64: "abc", file: nil)

    #expect(throws: APIRequestError.self) {
        _ = try payload.source()
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
    #expect(payload.resolvedOptions.resolvedWaitUntil == .domcontentloaded)
    #expect(payload.resolvedOptions.resolvedTimeout == 30_000)
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
    #expect(payload.resolvedOptions.resolvedWaitUntil == .networkidle2)
    #expect(payload.resolvedOptions.resolvedTimeout == 1234)
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
