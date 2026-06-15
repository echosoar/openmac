#if os(macOS)
import AppKit
import Foundation
import ImageIO
import Network
import SwiftUI
import Translation
import Vision
import WebKit

/// Lightweight logger so server activity is visible in Console / Xcode output.
func openmacLog(_ message: String) {
    NSLog("[OpenMac] %@", message)
}

@MainActor
final class OpenMacAppModel: ObservableObject {
    @Published var portText = "8080"
    @Published var isEnabled = false
    @Published var isPresentingError = false
    @Published private(set) var errorMessage = ""

    private var server: OpenMacHTTPServer?

    func toggleServer(_ enabled: Bool) {
        if enabled {
            startServer()
        } else {
            stopServer()
        }
    }

    func startServer() {
        do {
            let port = try validatedPort()
            let server = try OpenMacHTTPServer(port: port)
            server.stateHandler = { [weak self] state in
                // Listener state changes arrive on the listener queue; hop to the
                // main actor before touching published UI state.
                Task { @MainActor in
                    self?.handleServerStateChange(state)
                }
            }
            try server.start()
            self.server = server
            // Optimistically reflect the toggle; the listener reports .ready or
            // .failed asynchronously (e.g. "Address already in use" arrives via
            // stateHandler, not as a throw here).
            isEnabled = true
            openmacLog("Server enabling on port \(port)")
        } catch {
            presentFailure(error.localizedDescription)
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        isEnabled = false
    }

    private func handleServerStateChange(_ state: ServerLifecycleState) {
        switch state {
        case .ready:
            isEnabled = true
        case let .failed(message):
            presentFailure(message)
        }
    }

    /// Tears down the server, flips the toggle back off, and surfaces an alert.
    private func presentFailure(_ message: String) {
        server?.stop()
        server = nil
        isEnabled = false
        errorMessage = message
        isPresentingError = true
        openmacLog("Failed to start server: \(message)")
    }

    private func validatedPort() throws -> UInt16 {
        guard let port = UInt16(portText), port > 0 else {
            throw APIRequestError.badRequest("Port must be a number between 1 and 65535")
        }

        return port
    }
}

/// Asynchronous lifecycle of the HTTP listener, reported via `stateHandler`.
enum ServerLifecycleState: Sendable {
    case ready
    case failed(String)
}

final class OpenMacHTTPServer {
    /// Reports asynchronous listener state: `.ready` when listening, `.failed`
    /// with a message when the listener fails (e.g. port already in use).
    /// Invoked on the listener queue.
    var stateHandler: ((ServerLifecycleState) -> Void)?

    private let listener: NWListener
    private let port: UInt16
    private let queue = DispatchQueue(label: "openmac.server")
    private let connectionsQueue = DispatchQueue(label: "openmac.server.connections")
    private var connections = [ObjectIdentifier: ConnectionHandler]()

    init(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw APIRequestError.badRequest("Invalid port")
        }

        self.port = port
        listener = try NWListener(using: .tcp, on: nwPort)
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }

            // Retain the handler for the lifetime of the connection. Without this
            // strong reference the handler is deallocated as soon as this closure
            // returns, its `[weak self]` receive callback sees a nil self, and no
            // response is ever sent — which looks like "requests hang / no reply".
            let handler = ConnectionHandler(connection: connection, port: self.port) { [weak self] finished in
                self?.removeConnection(finished)
            }
            self.addConnection(handler)
            openmacLog("New connection accepted (active: \(self.connectionCount()))")
            handler.start()
        }
        listener.stateUpdateHandler = { [port, weak self] state in
            switch state {
            case .ready:
                openmacLog("Server ready, listening on :\(port)")
                self?.stateHandler?(.ready)
            case let .failed(error):
                openmacLog("Server failed: \(error.localizedDescription)")
                self?.stateHandler?(.failed(error.localizedDescription))
            case .cancelled:
                openmacLog("Server cancelled")
            default:
                break
            }
        }
        openmacLog("Starting server on :\(port)")
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        // Snapshot and clear under the lock, then cancel outside it. Cancelling
        // triggers each handler's completion -> removeConnection, which also locks
        // connectionsQueue; doing it inside the lock would deadlock the serial queue.
        let active = connectionsQueue.sync { () -> [ConnectionHandler] in
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        active.forEach { $0.cancel() }
        openmacLog("Server stopped")
    }

    private func addConnection(_ handler: ConnectionHandler) {
        connectionsQueue.sync {
            connections[ObjectIdentifier(handler)] = handler
        }
    }

    private func removeConnection(_ handler: ConnectionHandler) {
        connectionsQueue.sync {
            connections[ObjectIdentifier(handler)] = nil
        }
    }

    private func connectionCount() -> Int {
        connectionsQueue.sync { connections.count }
    }
}

private final class ConnectionHandler {
    private let connection: NWConnection
    private let port: UInt16
    private let queue = DispatchQueue(label: "openmac.connection")
    private var buffer = Data()
    private let onComplete: (ConnectionHandler) -> Void
    private var didComplete = false

    init(connection: NWConnection, port: UInt16, onComplete: @escaping (ConnectionHandler) -> Void) {
        self.connection = connection
        self.port = port
        self.onComplete = onComplete
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                openmacLog("Connection failed: \(error.localizedDescription)")
                self?.complete()
            }
        }
        connection.start(queue: queue)
        receiveNextChunk()
    }

    func cancel() {
        connection.cancel()
        complete()
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.buffer.append(data)
            }

            do {
                if let parsed = try HTTPRequestParser.parse(buffer: self.buffer) {
                    self.buffer.removeFirst(parsed.consumedLength)
                    self.handle(parsed.request)
                    return
                }
            } catch let requestError as APIRequestError {
                openmacLog("Parse error \(requestError.statusCode): \(requestError.message)")
                self.respond(with: HTTPResponseBuilder.failure(statusCode: requestError.statusCode, timeCost: 0, message: requestError.message))
                return
            } catch {
                openmacLog("Parse error 500: \(error.localizedDescription)")
                self.respond(with: HTTPResponseBuilder.failure(statusCode: 500, timeCost: 0, message: error.localizedDescription))
                return
            }

            if let error {
                openmacLog("Receive error: \(error.localizedDescription)")
                self.respond(with: HTTPResponseBuilder.failure(statusCode: 500, timeCost: 0, message: error.localizedDescription))
                return
            }

            if isComplete {
                openmacLog("Connection closed by peer before a full request was received")
                self.cancel()
                return
            }

            self.receiveNextChunk()
        }
    }

    private func handle(_ request: HTTPRequestMessage) {
        Task {
            let responseData = await OpenMacRequestRouter(port: port).response(for: request)
            self.respond(with: responseData)
        }
    }

    private func respond(with data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                openmacLog("Send error: \(error.localizedDescription)")
            }
            self?.cancel()
        })
    }

    private func complete() {
        guard !didComplete else {
            return
        }
        didComplete = true
        onComplete(self)
    }
}

private struct OCRResult {
    let lines: [String]

    var text: String {
        lines.joined(separator: "\n")
    }
}

private struct OpenMacRequestRouter {
    /// The port the server is listening on, used to fill in `/SKILL.md` URLs.
    let port: UInt16

    func response(for request: HTTPRequestMessage) async -> Data {
        let start = Date()
        openmacLog("--> \(request.method.rawValue) \(request.target)")

        // `/SKILL.md` returns a Markdown document instead of the JSON envelope.
        if request.path == "/SKILL.md" || request.path == "/skill.md" {
            return skillDocumentResponse(for: request, start: start)
        }

        do {
            let data: APIResponseData
            switch request.path {
            case "/api/ocr":
                data = try await handleOCR(request)
            case "/api/translate":
                data = try await handleTranslate(request)
            case "/api/web-content":
                data = try await handleWebContent(request)
            case "/api/search":
                data = try await handleSearch(request)
            default:
                throw APIRequestError.notFound("Unknown path: \(request.path)")
            }
            let timeCost = Self.elapsedMilliseconds(since: start)
            let response = HTTPResponseBuilder.success(timeCost: timeCost, data: data)
            openmacLog("<-- \(request.method.rawValue) \(request.path) 200 (\(response.count) bytes, \(timeCost)ms)")
            return response
        } catch let error as APIRequestError {
            let timeCost = Self.elapsedMilliseconds(since: start)
            openmacLog("<-- \(request.method.rawValue) \(request.path) \(error.statusCode): \(error.message) (\(timeCost)ms)")
            return HTTPResponseBuilder.failure(statusCode: error.statusCode, timeCost: timeCost, message: error.message)
        } catch {
            let timeCost = Self.elapsedMilliseconds(since: start)
            openmacLog("<-- \(request.method.rawValue) \(request.path) 500: \(error.localizedDescription) (\(timeCost)ms)")
            return HTTPResponseBuilder.failure(statusCode: 500, timeCost: timeCost, message: error.localizedDescription)
        }
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    private func skillDocumentResponse(for request: HTTPRequestMessage, start: Date) -> Data {
        guard request.method == .get else {
            let timeCost = Self.elapsedMilliseconds(since: start)
            openmacLog("<-- \(request.method.rawValue) \(request.path) 405 (\(timeCost)ms)")
            return HTTPResponseBuilder.failure(statusCode: 405, timeCost: timeCost, message: "\(request.path) only supports GET")
        }

        let markdown = SkillDocument.markdown(port: String(port))
        let body = Data(markdown.utf8)
        let response = HTTPResponseBuilder.build(statusCode: 200, contentType: SkillDocument.contentType, body: body)
        let timeCost = Self.elapsedMilliseconds(since: start)
        openmacLog("<-- GET \(request.path) 200 (\(response.count) bytes, \(timeCost)ms)")
        return response
    }

    private func handleOCR(_ request: HTTPRequestMessage) async throws -> APIResponseData {
        let payload = try APIRequestDecoder.decodeOCRRequest(from: request)
        let imageData = try await ImageDataLoader().load(from: try payload.source())
        let result = try OCRService().recognizeText(in: imageData)
        return APIResponseData(text: result.text, lines: result.lines)
    }

    private func handleTranslate(_ request: HTTPRequestMessage) async throws -> APIResponseData {
        guard #available(macOS 15, *) else {
            throw APIRequestError.internalError("Translation requires macOS 15 or later")
        }
        let payload = try APIRequestDecoder.decodeTranslateRequest(from: request)
        let translated = try await TranslationService().translate(payload)
        return APIResponseData(text: translated)
    }

    private func handleWebContent(_ request: HTTPRequestMessage) async throws -> APIResponseData {
        let payload = try APIRequestDecoder.decodeWebContentRequest(from: request)
        guard let url = URL(string: payload.url) else {
            throw APIRequestError.badRequest("url must be a valid absolute URL")
        }

        let html = try await WebContentRenderer().renderHTML(from: url, options: try payload.resolvedOptions())
        return APIResponseData(html: html)
    }

    private func handleSearch(_ request: HTTPRequestMessage) async throws -> APIResponseData {
        let payload = try APIRequestDecoder.decodeSearchRequest(from: request)
        let engines = try await WebSearchService().search(
            query: payload.text,
            engines: payload.resolvedEngines,
            count: payload.resolvedCount,
            excludeDomains: payload.resolvedExcludeDomains
        )
        return APIResponseData(engines: engines)
    }
}

private struct ImageDataLoader {
    func load(from source: OCRSource) async throws -> Data {
        switch source {
        case let .url(string):
            guard let url = URL(string: string) else {
                throw APIRequestError.badRequest("url must be a valid absolute URL")
            }

            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        case let .base64(string):
            let cleaned = stripDataURIPrefix(from: string)
            guard let data = Data(base64Encoded: cleaned) else {
                throw APIRequestError.badRequest("base64 must be valid base64-encoded image data")
            }
            return data
        case let .file(path):
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    private func stripDataURIPrefix(from string: String) -> String {
        guard string.contains(",") else {
            return string
        }

        return String(string.split(separator: ",", maxSplits: 1).last ?? "")
    }
}

private struct OCRService {
    func recognizeText(in imageData: Data) throws -> OCRResult {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw APIRequestError.badRequest("Unable to decode image data")
        }

        var lines = [String]()
        var recognitionError: Error?
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                recognitionError = error
                return
            }

            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            lines = observations.compactMap { $0.topCandidates(1).first?.string }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        if let recognitionError {
            throw recognitionError
        }
        return OCRResult(lines: lines)
    }
}

@MainActor
private final class WebContentRenderer: NSObject, WKNavigationDelegate {
    private let networkIdleThreshold: TimeInterval = 0.5
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var timer: Timer?
    private var deadline = Date()
    private var waitUntil = WaitUntilMode.domcontentloaded
    private var idleStart: Date?

    func renderHTML(from url: URL, options: GotoOptions) async throws -> String {
        waitUntil = options.resolvedWaitUntil
        deadline = Date().addingTimeInterval(Double(options.resolvedTimeout) / 1000.0)
        idleStart = nil

        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: requestTrackerScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
            startPolling()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: .failure(error))
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollPageState()
            }
        }
    }

    private func pollPageState() async {
        guard let webView else {
            return
        }

        if Date() >= deadline {
            let html = (try? await currentPageHTML(from: webView)) ?? ""
            finish(with: .success(html))
            return
        }

        guard let state = try? await currentPageState(from: webView) else {
            return
        }

        switch waitUntil {
        case .domcontentloaded:
            if state.readyState != "loading" {
                finish(with: .success(state.html))
            }
        case .networkidle0, .networkidle2:
            let threshold = waitUntil == .networkidle0 ? 0 : 2
            if state.readyState == "complete" && state.inflight <= threshold {
                if let idleStart {
                    if Date().timeIntervalSince(idleStart) >= networkIdleThreshold {
                        finish(with: .success(state.html))
                    }
                } else {
                    idleStart = Date()
                }
            } else {
                idleStart = nil
            }
        }
    }

    private func currentPageState(from webView: WKWebView) async throws -> (readyState: String, inflight: Int, html: String) {
        let script = """
        (() => ({
            readyState: document.readyState,
            inflight: window.__openmacInflightRequests || 0,
            html: document.documentElement ? document.documentElement.outerHTML : ''
        }))();
        """
        let result = try await Self.runJavaScript(script, on: webView)
        guard let dictionary = result as? [String: Any] else {
            throw APIRequestError.internalError("Unable to inspect page state")
        }

        return (
            readyState: dictionary["readyState"] as? String ?? "loading",
            inflight: dictionary["inflight"] as? Int ?? 0,
            html: dictionary["html"] as? String ?? ""
        )
    }

    private func currentPageHTML(from webView: WKWebView) async throws -> String {
        let result = try await Self.runJavaScript("document.documentElement ? document.documentElement.outerHTML : ''", on: webView)
        return result as? String ?? ""
    }

    /// Evaluates JavaScript using the completion-handler API wrapped in a
    /// continuation.
    ///
    /// Calling `webView.evaluateJavaScript(_:)` directly with `try await` is
    /// ambiguous: the SDK exposes both an `async` overload and a
    /// completion-handler overload (whose handler defaults to `nil`), and both
    /// are valid candidates in an async context. Routing through the
    /// completion-handler variant with an explicit trailing closure removes the
    /// ambiguity.
    private static func runJavaScript(_ script: String, on webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func finish(with result: Result<String, Error>) {
        guard let continuation else {
            return
        }

        self.continuation = nil
        timer?.invalidate()
        timer = nil
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }

    private var requestTrackerScript: String {
        """
        (() => {
            if (window.__openmacTrackerInstalled) return;
            window.__openmacTrackerInstalled = true;
            window.__openmacInflightRequests = 0;

            const increment = () => { window.__openmacInflightRequests += 1; };
            const decrement = () => { window.__openmacInflightRequests = Math.max(0, window.__openmacInflightRequests - 1); };

            const originalFetch = window.fetch;
            if (originalFetch) {
                window.fetch = (...args) => {
                    increment();
                    return originalFetch(...args).finally(decrement);
                };
            }

            const OriginalXHR = window.XMLHttpRequest;
            if (OriginalXHR) {
                const originalSend = OriginalXHR.prototype.send;
                OriginalXHR.prototype.send = function (...args) {
                    increment();
                    this.addEventListener('loadend', decrement, { once: true });
                    return originalSend.apply(this, args);
                };
            }
        })();
        """
    }
}

/// Headless multi-engine web search. For each engine we load its public results
/// page in an off-screen `WKWebView`, wait for the page to settle, then extract
/// hits with an engine-specific JavaScript scraper. Engines run concurrently; an
/// engine that fails or times out is simply omitted from the response.
@MainActor
private final class WebSearchService {
    private let perEngineTimeout: TimeInterval = 12.0
    private let extractionDelay: TimeInterval = 1.5

    func search(query: String, engines: [String], count: Int, excludeDomains: [String]) async throws -> [SearchEngineResult] {
        guard !engines.isEmpty else {
            throw APIRequestError.badRequest("No search engines specified")
        }

        let timeout = perEngineTimeout
        let delay = extractionDelay

        // Run engines concurrently; remember each engine's index so the response
        // preserves the order the caller requested rather than completion order.
        let collected = await withTaskGroup(of: (Int, SearchEngineResult?).self) { group in
            for (index, engine) in engines.enumerated() {
                group.addTask { @MainActor in
                    let start = Date()
                    let runner = SearchEngineRunner(
                        engineId: engine,
                        query: query,
                        count: count,
                        excludeDomains: excludeDomains,
                        timeout: timeout,
                        extractionDelay: delay
                    )
                    do {
                        let items = try await runner.run()
                        let duration = Int((Date().timeIntervalSince(start) * 1000).rounded())
                        return (index, SearchEngineResult(engine: engine, results: items, duration: duration))
                    } catch {
                        openmacLog("Search engine \(engine) failed: \(error.localizedDescription)")
                        return (index, nil)
                    }
                }
            }

            var results = [(Int, SearchEngineResult)]()
            for await (index, result) in group {
                if let result {
                    results.append((index, result))
                }
            }
            return results
        }

        guard !collected.isEmpty else {
            throw APIRequestError.internalError("All search engines failed to return results")
        }

        return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}

/// Performs a single-engine search in an off-screen WebView and resolves to the
/// extracted hits (or throws on navigation failure / timeout).
@MainActor
private final class SearchEngineRunner: NSObject, WKNavigationDelegate {
    private let engineId: String
    private let query: String
    private let count: Int
    private let excludeDomains: [String]
    private let timeout: TimeInterval
    private let extractionDelay: TimeInterval

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[SearchResultItem], Error>?
    private var timeoutTask: Task<Void, Never>?
    private var settled = false

    init(engineId: String, query: String, count: Int, excludeDomains: [String], timeout: TimeInterval, extractionDelay: TimeInterval) {
        self.engineId = engineId
        self.query = query
        self.count = count
        self.excludeDomains = excludeDomains
        self.timeout = timeout
        self.extractionDelay = extractionDelay
        super.init()
    }

    func run() async throws -> [SearchResultItem] {
        guard let url = Self.buildSearchURL(query: query, engineId: engineId) else {
            throw APIRequestError.badRequest("Unsupported search engine: \(engineId)")
        }

        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Present as a recent desktop Safari so engines serve their standard markup.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
        webView.navigationDelegate = self
        self.webView = webView

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                guard !self.settled else { return }
                self.finish(with: .failure(APIRequestError.internalError("Search timed out for engine \(self.engineId)")))
            }
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: self.timeout))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give client-side rendering a moment before scraping the DOM.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.extractionDelay * 1_000_000_000))
            guard !self.settled else { return }
            await self.extractResults(from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: .failure(error))
    }

    private func extractResults(from webView: WKWebView) async {
        guard !settled else { return }

        let script = Self.extractionScript(engineId: engineId, count: count, excludeDomains: excludeDomains)
        do {
            let value = try await Self.runJavaScript(script, on: webView)
            // A `null` return means the scraper found no matching elements.
            guard let array = value as? [[String: Any]] else {
                finish(with: .success([]))
                return
            }
            let items = array.compactMap { dict -> SearchResultItem? in
                guard let title = dict["title"] as? String,
                      let url = dict["url"] as? String,
                      !url.isEmpty else {
                    return nil
                }
                let description = dict["description"] as? String ?? ""
                return SearchResultItem(title: title, description: description, url: url)
            }
            finish(with: .success(items))
        } catch {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<[SearchResultItem], Error>) {
        guard !settled, let continuation else {
            return
        }
        settled = true
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation.resume(with: result)
    }

    /// Evaluates JavaScript via the completion-handler API wrapped in a
    /// continuation (mirrors `WebContentRenderer.runJavaScript`, which avoids the
    /// async/completion-handler overload ambiguity).
    private static func runJavaScript(_ script: String, on webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private static func buildSearchURL(query: String, engineId: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString: String
        switch engineId {
        case "baidu":
            urlString = "https://www.baidu.com/s?wd=\(encoded)"
        case "bing":
            urlString = "https://www.bing.com/search?q=\(encoded)&from=HDRSC1"
        case "brave":
            urlString = "https://search.brave.com/search?q=\(encoded)&source=web"
        case "duckduckgo":
            urlString = "https://duckduckgo.com/?q=\(encoded)"
        case "google":
            urlString = "https://www.google.com/search?q=\(encoded)"
        case "sogou":
            urlString = "https://www.sogou.com/web?query=\(encoded)"
        case "wikipedia":
            urlString = "https://zh.wikipedia.org/w/index.php?search=\(encoded)&profile=advanced&fulltext=1&ns0=1"
        case "arxiv":
            urlString = "https://arxiv.org/search/?query=\(encoded)&searchtype=all&source=header"
        default:
            return nil
        }
        return URL(string: urlString)
    }

    /// Builds the engine-specific DOM scraper. The scraper returns an array of
    /// `{title, description, url}` objects, or `null` when no results are found.
    private static func extractionScript(engineId: String, count: Int, excludeDomains: [String]) -> String {
        let maxResults = max(1, min(count, 6))
        let excludedJSON = (try? JSONEncoder().encode(excludeDomains)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        switch engineId {
        case "baidu":
            return scraper(selector: ".result", titleSelector: "h3 a", descSelector: ".cos-row", maxResults: maxResults, excludedJSON: excludedJSON, urlFrom: "elem.getAttribute('mu') || titleElem.href || ''")
        case "bing":
            return scraper(selector: ".b_algo", titleSelector: "h2 a", descSelector: ".b_caption p", maxResults: maxResults, excludedJSON: excludedJSON, urlFrom: "titleElem.href || ''")
        case "brave":
            return """
            (function() {
                var results = [];
                var elements = document.querySelectorAll('.result-wrapper, .snippet[data-type="web"]');
                if (elements.length === 0) { return null; }
                var excludedHosts = \(excludedJSON);
                var maxResults = \(maxResults);
                for (var i = 0; i < elements.length; i++) {
                    var elem = elements[i];
                    var titleElem = elem.querySelector('.search-snippet-title, .title');
                    var linkElem = elem.querySelector('.result-content > a, a.heading-serpresult, a');
                    var descElem = elem.querySelector('.content, .snippet-description');
                    if (titleElem) {
                        var url = linkElem ? linkElem.href : '';
                        var include = true;
                        for (var j = 0; j < excludedHosts.length; j++) {
                            if (url.indexOf(excludedHosts[j]) !== -1) { include = false; break; }
                        }
                        if (include) {
                            results.push({ title: titleElem.textContent.trim(), description: descElem ? descElem.textContent.trim() : '', url: url });
                            if (results.length >= maxResults) { break; }
                        }
                    }
                }
                return results;
            })();
            """
        case "duckduckgo":
            return scraper(selector: "article[data-testid=\"result\"]", titleSelector: "h2 a", descSelector: "[data-result=\"snippet\"]", maxResults: maxResults, excludedJSON: excludedJSON, urlFrom: "titleElem.href || ''")
        case "google":
            return """
            (function() {
                var results = [];
                var elements = document.querySelectorAll('[data-hveid]');
                if (elements.length === 0) { return null; }
                var excludedHosts = \(excludedJSON);
                var maxResults = \(maxResults);
                for (var i = 0; i < elements.length; i++) {
                    var elem = elements[i];
                    var titleElem = elem.querySelector('h3');
                    var linkElem = elem.querySelector('a');
                    var descElem = elem.querySelector('[data-sncf]');
                    if (titleElem && linkElem) {
                        var url = linkElem.href || '';
                        var include = true;
                        for (var j = 0; j < excludedHosts.length; j++) {
                            if (url.indexOf(excludedHosts[j]) !== -1) { include = false; break; }
                        }
                        if (include) {
                            results.push({ title: titleElem.textContent.trim(), description: descElem ? descElem.textContent.trim() : '', url: url });
                            if (results.length >= maxResults) { break; }
                        }
                    }
                }
                return results;
            })();
            """
        case "sogou":
            return """
            (function() {
                var results = [];
                var elements = document.querySelectorAll('.vrwrap, .rb');
                if (elements.length === 0) { return null; }
                var excludedHosts = \(excludedJSON);
                var maxResults = \(maxResults);
                for (var i = 0; i < elements.length; i++) {
                    var elem = elements[i];
                    var titleElem = elem.querySelector('h3 a, .pt a');
                    var descElem = elem.querySelector('.str-text, .str_text');
                    if (titleElem) {
                        var originUrlEle = elem.querySelector('[data-docid][data-url]');
                        var url = originUrlEle ? originUrlEle.getAttribute('data-url') : (titleElem.href || '');
                        var include = true;
                        for (var j = 0; j < excludedHosts.length; j++) {
                            if (url.indexOf(excludedHosts[j]) !== -1) { include = false; break; }
                        }
                        if (include) {
                            results.push({ title: titleElem.textContent.trim(), description: descElem ? descElem.textContent.trim() : '', url: url });
                            if (results.length >= maxResults) { break; }
                        }
                    }
                }
                return results;
            })();
            """
        case "wikipedia":
            return """
            (function() {
                var results = [];
                var elements = document.querySelectorAll('.mw-search-result');
                if (elements.length === 0) { return null; }
                var maxResults = \(maxResults);
                for (var i = 0; i < elements.length; i++) {
                    var elem = elements[i];
                    var titleElem = elem.querySelector('.mw-search-result-heading a');
                    var descElem = elem.querySelector('.searchresult');
                    if (titleElem) {
                        var url = titleElem.getAttribute('href') ? 'https://zh.wikipedia.org' + titleElem.getAttribute('href') : '';
                        results.push({ title: titleElem.textContent.trim(), description: descElem ? descElem.textContent.trim() : '', url: url });
                        if (results.length >= maxResults) { break; }
                    }
                }
                return results;
            })();
            """
        case "arxiv":
            return """
            (function() {
                var results = [];
                var elements = document.querySelectorAll('.arxiv-result');
                if (elements.length === 0) { return null; }
                var maxResults = \(maxResults);
                for (var i = 0; i < elements.length; i++) {
                    var elem = elements[i];
                    var titleElem = elem.querySelector('.title');
                    var linkElem = elem.querySelector('.list-title > a');
                    var authorsElem = elem.querySelector('.authors');
                    var abstractElem = elem.querySelector('.abstract-full');
                    if (titleElem && linkElem) {
                        var url = linkElem.href || '';
                        var description = [];
                        if (authorsElem) { description.push(authorsElem.textContent.trim()); }
                        if (abstractElem) { description.push(abstractElem.textContent.trim()); }
                        results.push({ title: titleElem.textContent.trim(), description: description.join(' '), url: url });
                        if (results.length >= maxResults) { break; }
                    }
                }
                return results;
            })();
            """
        default:
            return "null;"
        }
    }

    /// Shared scraper template for engines whose results follow a simple
    /// "container -> title link + description" shape.
    private static func scraper(selector: String, titleSelector: String, descSelector: String, maxResults: Int, excludedJSON: String, urlFrom: String) -> String {
        return """
        (function() {
            var results = [];
            var elements = document.querySelectorAll('\(selector)');
            if (elements.length === 0) { return null; }
            var excludedHosts = \(excludedJSON);
            var maxResults = \(maxResults);
            for (var i = 0; i < elements.length; i++) {
                var elem = elements[i];
                var titleElem = elem.querySelector('\(titleSelector)');
                var descElem = elem.querySelector('\(descSelector)');
                if (titleElem) {
                    var url = \(urlFrom);
                    var include = true;
                    for (var j = 0; j < excludedHosts.length; j++) {
                        if (url.indexOf(excludedHosts[j]) !== -1) { include = false; break; }
                    }
                    if (include) {
                        results.push({ title: titleElem.textContent.trim(), description: descElem ? descElem.textContent.trim() : '', url: url });
                        if (results.length >= maxResults) { break; }
                    }
                }
            }
            return results;
        })();
        """
    }
}

@available(macOS 15, *)
private struct TranslationService {
    func translate(_ payload: TranslateRequestPayload) async throws -> String {
        let sourceLanguage = payload.from.flatMap { Locale.Language(identifier: $0) }
        let targetLanguage = Locale.Language(identifier: payload.to)

        let config = TranslationSession.Configuration(
            source: sourceLanguage,
            target: targetLanguage
        )

        return try await TranslationBridge.shared.translate(text: payload.text, configuration: config)
    }
}

/// Bridges the SwiftUI-hosted Translation session to an async/await call site.
///
/// `Translation.framework` only exposes a `TranslationSession` through the
/// `.translationTask` SwiftUI modifier, which must be attached to a live view.
/// Since the HTTP handler runs outside any view hierarchy, we host a 1x1
/// off-screen window, run the translation, and resume a continuation when the
/// session reports its result.
@available(macOS 15, *)
@MainActor
private final class TranslationBridge {
    static let shared = TranslationBridge()

    func translate(text: String, configuration: TranslationSession.Configuration) async throws -> String {
        var window: NSWindow?
        defer { window?.close() }

        return try await withCheckedThrowingContinuation { continuation in
            let view = TranslationBridgeView(text: text, configuration: configuration) { result in
                continuation.resume(with: result)
            }
            let hosting = NSHostingController(rootView: view)
            let hostWindow = NSWindow(contentViewController: hosting)
            hostWindow.setFrame(NSRect(x: -9999, y: -9999, width: 1, height: 1), display: false)
            hostWindow.orderFront(nil)
            window = hostWindow
        }
    }
}

@available(macOS 15, *)
private struct TranslationBridgeView: View {
    let text: String
    let configuration: TranslationSession.Configuration
    let completion: (Result<String, Error>) -> Void

    @State private var triggered = false

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                guard !triggered else { return }
                triggered = true
                do {
                    let response = try await session.translate(text)
                    completion(.success(response.targetText))
                } catch {
                    completion(.failure(APIRequestError.internalError("Translation failed: \(error.localizedDescription)")))
                }
            }
    }
}

struct OpenMacView: View {
    @StateObject private var model = OpenMacAppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Supported APIs")
                    .font(.headline)
                Spacer()
                TextField("Port", text: $model.portText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 64)
                Toggle("", isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.toggleServer($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(APIEndpoint.all) { endpoint in
                        APIEndpointRow(endpoint: endpoint, port: model.portText)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(minHeight: 260)
        }
        .padding(16)
        .frame(width: 440)
        .frame(minHeight: 520)
        .alert("Server Error", isPresented: $model.isPresentingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.errorMessage)
        }
    }
}

private struct APIEndpointRow: View {
    let endpoint: APIEndpoint
    let port: String

    @State private var isExpanded = false
    @State private var didCopy = false

    private var address: String {
        endpoint.address(host: "localhost", port: port)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(endpoint.method)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(methodColor.opacity(0.18))
                    .foregroundStyle(methodColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(endpoint.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            Text(endpoint.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(address)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button(action: copyAddress) {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("Copy API address")
            }

            DisclosureGroup(isExpanded: $isExpanded) {
                Text(endpoint.requestDemo)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
            } label: {
                Text("Request body demo")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var methodColor: Color {
        switch endpoint.method.uppercased() {
        case "GET":
            return .blue
        case "POST":
            return .green
        default:
            return .orange
        }
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }
}
#endif
