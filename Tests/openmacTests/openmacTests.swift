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


@Test func decodesGetSearchRequestWithDefaults() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/search?text=swift%20concurrency",
        path: "/api/search",
        queryItems: [URLQueryItem(name: "text", value: "swift concurrency")],
        headers: [:],
        body: Data()
    )

    let payload = try APIRequestDecoder.decodeSearchRequest(from: request)

    #expect(payload.text == "swift concurrency")
    #expect(payload.resolvedEngines == ["bing", "baidu", "brave"])
    #expect(payload.resolvedCount == 3)
    #expect(payload.resolvedExcludeDomains == [])
}

@Test func decodesGetSearchRequestWithCommaSeparatedLists() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/search?text=x&engines=bing,brave&count=5&excludeDomains=baidu.com,zhihu.com",
        path: "/api/search",
        queryItems: [
            URLQueryItem(name: "text", value: "x"),
            URLQueryItem(name: "engines", value: "bing,brave"),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "excludeDomains", value: "baidu.com,zhihu.com")
        ],
        headers: [:],
        body: Data()
    )

    let payload = try APIRequestDecoder.decodeSearchRequest(from: request)

    #expect(payload.resolvedEngines == ["bing", "brave"])
    #expect(payload.resolvedCount == 5)
    #expect(payload.resolvedExcludeDomains == ["baidu.com", "zhihu.com"])
}

@Test func decodesPostSearchRequest() throws {
    let request = HTTPRequestMessage(
        method: .post,
        target: "/api/search",
        path: "/api/search",
        queryItems: [],
        headers: ["content-type": "application/json"],
        body: Data("{\"text\":\"hello\",\"engines\":[\"bing\",\"brave\"],\"count\":2,\"excludeDomains\":[\"baidu.com\"]}".utf8)
    )

    let payload = try APIRequestDecoder.decodeSearchRequest(from: request)

    #expect(payload.text == "hello")
    #expect(payload.resolvedEngines == ["bing", "brave"])
    #expect(payload.resolvedCount == 2)
    #expect(payload.resolvedExcludeDomains == ["baidu.com"])
}

@Test func searchCountIsClampedToMaximum() throws {
    let payload = try SearchRequestPayload(text: "x", engines: nil, count: 99, excludeDomains: nil).validated()
    #expect(payload.resolvedCount == 6)
}

@Test func searchEnginesAreDeduplicatedPreservingOrder() throws {
    let payload = try SearchRequestPayload(text: "x", engines: ["brave", "bing", "brave"], count: nil, excludeDomains: nil).validated()
    #expect(payload.resolvedEngines == ["brave", "bing"])
}

@Test func rejectsEmptySearchText() throws {
    let request = HTTPRequestMessage(
        method: .post,
        target: "/api/search",
        path: "/api/search",
        queryItems: [],
        headers: ["content-type": "application/json"],
        body: Data("{\"text\":\"   \"}".utf8)
    )

    #expect(throws: APIRequestError.self) {
        _ = try APIRequestDecoder.decodeSearchRequest(from: request)
    }
}

@Test func rejectsMissingSearchTextInGet() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/search",
        path: "/api/search",
        queryItems: [],
        headers: [:],
        body: Data()
    )

    #expect(throws: APIRequestError.self) {
        _ = try APIRequestDecoder.decodeSearchRequest(from: request)
    }
}

@Test func rejectsUnsupportedSearchEngine() throws {
    #expect(throws: APIRequestError.self) {
        _ = try SearchRequestPayload(text: "x", engines: ["yahoo"], count: nil, excludeDomains: nil).validated()
    }
}

@Test func rejectsNonPositiveSearchCount() throws {
    let request = HTTPRequestMessage(
        method: .get,
        target: "/api/search?text=x&count=0",
        path: "/api/search",
        queryItems: [
            URLQueryItem(name: "text", value: "x"),
            URLQueryItem(name: "count", value: "0")
        ],
        headers: [:],
        body: Data()
    )

    #expect(throws: APIRequestError.self) {
        _ = try APIRequestDecoder.decodeSearchRequest(from: request)
    }
}

@Test func searchResponseDataEncodesEnginesAndOmitsEmptyFields() throws {
    let data = APIResponseData(engines: [
        SearchEngineResult(
            engine: "bing",
            results: [SearchResultItem(title: "T", description: "D", url: "https://example.com")],
            duration: 120
        )
    ])

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try #require(String(data: try encoder.encode(data), encoding: .utf8))

    #expect(json.contains("\"engines\""))
    #expect(json.contains("\"engine\":\"bing\""))
    #expect(json.contains("\"url\":\"https:\\/\\/example.com\""))
    #expect(!json.contains("\"text\""))
    #expect(!json.contains("\"html\""))
}
