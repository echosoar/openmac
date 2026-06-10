#if os(macOS)
import AppKit
import Foundation
import ImageIO
import Network
import SwiftUI
import Vision
import WebKit

@MainActor
final class OpenMacAppModel: ObservableObject {
    @Published var portText = "8080"
    @Published var isEnabled = false
    @Published var statusMessage = ""

    private var server: OpenMacHTTPServer?

    func toggleServer(_ enabled: Bool) {
        if enabled {
            Task {
                await startServer()
            }
        } else {
            stopServer()
        }
    }

    func startServer() async {
        do {
            let port = try validatedPort()
            let server = try OpenMacHTTPServer(port: port)
            try server.start()
            self.server = server
            statusMessage = "Listening on :\(port)"
            isEnabled = true
        } catch {
            statusMessage = error.localizedDescription
            server?.stop()
            server = nil
            isEnabled = false
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        statusMessage = "Stopped"
        isEnabled = false
    }

    private func validatedPort() throws -> UInt16 {
        guard let port = UInt16(portText), port > 0 else {
            throw APIRequestError.badRequest("Port must be a number between 1 and 65535")
        }

        return port
    }
}

final class OpenMacHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "openmac.server")

    init(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw APIRequestError.badRequest("Invalid port")
        }

        listener = try NWListener(using: .tcp, on: nwPort)
    }

    func start() throws {
        listener.newConnectionHandler = { connection in
            ConnectionHandler(connection: connection).start()
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                NSLog("OpenMac server failed: %@", error.localizedDescription)
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }
}

private final class ConnectionHandler {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "openmac.connection")
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.start(queue: queue)
        receiveNextChunk()
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
                self.respond(with: HTTPResponseBuilder.json(statusCode: requestError.statusCode, body: APIResponseBody(error: requestError.message)))
                return
            } catch {
                self.respond(with: HTTPResponseBuilder.json(statusCode: 500, body: APIResponseBody(error: error.localizedDescription)))
                return
            }

            if let error {
                self.respond(with: HTTPResponseBuilder.json(statusCode: 500, body: APIResponseBody(error: error.localizedDescription)))
                return
            }

            if isComplete {
                self.connection.cancel()
                return
            }

            self.receiveNextChunk()
        }
    }

    private func handle(_ request: HTTPRequestMessage) {
        Task {
            let responseData = await OpenMacRequestRouter().response(for: request)
            self.respond(with: responseData)
        }
    }

    private func respond(with data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}

private struct OCRResult {
    let lines: [String]

    var text: String {
        lines.joined(separator: "\n")
    }
}

private struct OpenMacRequestRouter {
    func response(for request: HTTPRequestMessage) async -> Data {
        do {
            switch request.path {
            case "/api/ocr":
                return try await handleOCR(request)
            case "/api/web-content":
                return try await handleWebContent(request)
            default:
                throw APIRequestError.notFound("Unknown path: \(request.path)")
            }
        } catch let error as APIRequestError {
            return HTTPResponseBuilder.json(statusCode: error.statusCode, body: APIResponseBody(error: error.message))
        } catch {
            return HTTPResponseBuilder.json(statusCode: 500, body: APIResponseBody(error: error.localizedDescription))
        }
    }

    private func handleOCR(_ request: HTTPRequestMessage) async throws -> Data {
        let payload = try APIRequestDecoder.decodeOCRRequest(from: request)
        let imageData = try await ImageDataLoader().load(from: try payload.source())
        let result = try OCRService().recognizeText(in: imageData)
        return HTTPResponseBuilder.json(body: APIResponseBody(text: result.text, lines: result.lines))
    }

    private func handleWebContent(_ request: HTTPRequestMessage) async throws -> Data {
        let payload = try APIRequestDecoder.decodeWebContentRequest(from: request)
        guard let url = URL(string: payload.url) else {
            throw APIRequestError.badRequest("url must be a valid absolute URL")
        }

        let html = try await WebContentRenderer().renderHTML(from: url, options: try payload.resolvedOptions())
        return HTTPResponseBuilder.json(body: APIResponseBody(html: html))
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
            let cleaned = string.contains(",") ? String(string.split(separator: ",", maxSplits: 1).last ?? "") : string
            guard let data = Data(base64Encoded: cleaned) else {
                throw APIRequestError.badRequest("base64 must be valid base64-encoded image data")
            }
            return data
        case let .file(path):
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
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
                    if Date().timeIntervalSince(idleStart) >= 0.5 {
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
        let result = try await webView.evaluateJavaScript(script)
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
        let result = try await webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''")
        return result as? String ?? ""
    }

    private func finish(with result: Result<String, Error>) {
        timer?.invalidate()
        timer = nil
        webView?.navigationDelegate = nil
        webView = nil

        guard let continuation else {
            return
        }

        self.continuation = nil
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
                function TrackedXHR() {
                    const xhr = new OriginalXHR();
                    const originalSend = xhr.send;
                    xhr.send = function (...args) {
                        increment();
                        xhr.addEventListener('loadend', decrement, { once: true });
                        return originalSend.apply(xhr, args);
                    };
                    return xhr;
                }
                TrackedXHR.prototype = OriginalXHR.prototype;
                window.XMLHttpRequest = TrackedXHR;
            }
        })();
        """
    }
}

extension WKWebView {
    @MainActor
    fileprivate func evaluateJavaScript(_ javaScriptString: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            self.evaluateJavaScript(javaScriptString) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as Any)
                }
            }
        }
    }
}

struct OpenMacView: View {
    @StateObject private var model = OpenMacAppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Port", text: $model.portText)
                .textFieldStyle(.roundedBorder)
            Toggle("Enabled", isOn: Binding(
                get: { model.isEnabled },
                set: { model.toggleServer($0) }
            ))
            Text(model.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }
}
#endif
