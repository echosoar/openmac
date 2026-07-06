#if os(macOS)
import AppKit
import Foundation
import WebKit

/// Browser automation service: opens a real `WKWebView` in an `NSWindow`,
/// injects `browser-use.js` (exposing `window.litePageAgent`), and exposes
/// per-session operations (snap / click / input / press / scroll / exec /
/// get-content / close). Sessions are tracked by `browserId` so the HTTP
/// router can address them across stateless requests.
@MainActor
final class BrowserAutomationService: NSObject {
    static let shared = BrowserAutomationService()

    struct OpenResult: Codable {
        let browserId: String
        let url: String
    }

    /// One open browser window, plus the cached page-snapshot used to map
    /// `elementId` -> CSS selector between requests.
    private final class BrowserSession {
        let browserId: String
        let webView: WKWebView
        let window: NSWindow
        var lastInjectedURL: String?
        var idleTimer: Timer?
        var autoCloseTimeout: TimeInterval = 0
        var isClosing = false
        var snap: Any?

        init(browserId: String, webView: WKWebView, window: NSWindow) {
            self.browserId = browserId
            self.webView = webView
            self.window = window
        }

        func cancelIdleTimer() {
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    private enum BrowserAutomationError: LocalizedError {
        case invalidURL
        case sessionNotFound
        case elementNotFound(Int)
        case scriptExecutionFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid URL"
            case .sessionNotFound:
                return "Browser session not found"
            case let .elementNotFound(elementId):
                return "Element not found for id \(elementId); call /api/browser/snap first"
            case .scriptExecutionFailed:
                return "Script execution failed"
            }
        }
    }

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
    private var sessions: [String: BrowserSession] = [:]
    private var scriptContentCache: String?

    private override init() {
        super.init()
    }

    // MARK: - Open

    /// Opens `url` in a new browser window with `browser-use.js` injected.
    /// - Parameters:
    ///   - urlString: Target URL (http/https prefixes are optional).
    ///   - showWindow: When `false`, the window is created off-screen for headless use.
    ///   - autoCloseSeconds: When `> 0`, the browser auto-closes after this many idle seconds.
    func open(
        urlString: String,
        showWindow: Bool = true,
        autoCloseSeconds: TimeInterval = 0
    ) async throws -> OpenResult {
        let normalized = Self.normalizeURL(urlString)
        guard let url = URL(string: normalized) else {
            throw BrowserAutomationError.invalidURL
        }

        let configuration = WKWebViewConfiguration()
        if let script = scriptContent() {
            let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            configuration.userContentController.addUserScript(userScript)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let browserId = UUID().uuidString
        window.title = "OpenMac Browser"
        window.identifier = NSUserInterfaceItemIdentifier(browserId)
        window.delegate = self
        window.contentView = webView
        window.isReleasedWhenClosed = false
        if showWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderOut(nil)
        }

        let session = BrowserSession(browserId: browserId, webView: webView, window: window)
        session.autoCloseTimeout = autoCloseSeconds
        sessions[browserId] = session

        webView.load(URLRequest(url: url))
        scheduleIdleTimer(for: browserId)
        return OpenResult(browserId: browserId, url: normalized)
    }

    // MARK: - Snap

    /// Snapshots the page, returning the array of `{id, type, content, attrs}`
    /// items from `window.litePageAgent.snap()`. The full snapshot (with
    /// selectors) is cached on the session so subsequent `click` / `input` /
    /// `press` calls can resolve `elementId` -> selector.
    func snap(browserId: String) async throws -> Any {
        let session = try session(for: browserId)
        scheduleIdleTimer(for: browserId)
        let raw = try await evaluate(browserId: browserId, script: "window.litePageAgent.snap()")
        session.snap = raw
        return strippedSnap(raw)
    }

    // MARK: - Click

    func click(browserId: String, elementId: Int) async throws {
        let selector = try selector(for: browserId, elementId: elementId)
        scheduleIdleTimer(for: browserId)
        let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
        _ = try await evaluate(browserId: browserId, script: "window.litePageAgent.click('\(escaped)')")
    }

    // MARK: - Input

    func input(browserId: String, elementId: Int, text: String) async throws {
        let selector = try selector(for: browserId, elementId: elementId)
        scheduleIdleTimer(for: browserId)
        let escapedSelector = selector.replacingOccurrences(of: "'", with: "\\'")
        let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
        _ = try await evaluate(browserId: browserId, script: "window.litePageAgent.input('\(escapedSelector)', '\(escapedText)')")
    }

    // MARK: - Press

    func press(browserId: String, elementId: Int, keys: [String]) async throws {
        let selector = try selector(for: browserId, elementId: elementId)
        scheduleIdleTimer(for: browserId)
        let escapedSelector = selector.replacingOccurrences(of: "'", with: "\\'")
        let keysString = keys.map { $0.replacingOccurrences(of: "'", with: "\\'") }
            .map { "'\($0)'" }
            .joined(separator: ",")
        _ = try await evaluate(browserId: browserId, script: "window.litePageAgent.press('\(escapedSelector)', [\(keysString)])")
    }

    // MARK: - Scroll

    func scroll(browserId: String, elementId: Int?, x: Int, y: Int) async throws {
        scheduleIdleTimer(for: browserId)
        let selectorQuery: String
        if let elementId {
            selectorQuery = try selector(for: browserId, elementId: elementId)
        } else {
            selectorQuery = "body"
        }
        let escaped = selectorQuery.replacingOccurrences(of: "'", with: "\\'")
        _ = try await evaluate(
            browserId: browserId,
            script: "window.litePageAgent.scroll(\(x), \(y), '\(escaped)')"
        )
    }

    // MARK: - Exec Script

    /// Runs an arbitrary JS string in the page and returns its stringified
    /// result. Useful for ad-hoc extraction that `snap` doesn't cover.
    @discardableResult
    func execScript(browserId: String, script: String) async throws -> String {
        let session = try session(for: browserId)
        scheduleIdleTimer(for: browserId)
        do {
            let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                session.webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: value)
                    }
                }
            }
            return Self.stringify(value)
        } catch {
            throw BrowserAutomationError.scriptExecutionFailed
        }
    }

    // MARK: - Get Content

    /// Returns the text content (or inner HTML when `html` is true) of the
    /// element identified by `elementId`. When `elementId` is nil, returns the
    /// content of `document.body`.
    func getContent(browserId: String, elementId: Int?, html: Bool) async throws -> String {
        let session = try session(for: browserId)
        scheduleIdleTimer(for: browserId)
        let script: String
        if let elementId {
            let selector = try selector(for: browserId, elementId: elementId)
            let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
            script = html
                ? "document.querySelector('\(escaped)')?.innerHTML || ''"
                : "document.querySelector('\(escaped)')?.textContent || ''"
        } else {
            script = html
                ? "document.body.innerHTML || ''"
                : "document.body.textContent || ''"
        }
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            session.webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
        return Self.stringify(value)
    }

    // MARK: - Close

    func close(browserId: String) async {
        guard let session = sessions[browserId], !session.isClosing else {
            return
        }
        cleanupSession(browserId: browserId, closeWindow: true)
    }

    // MARK: - Internals

    private func session(for browserId: String) throws -> BrowserSession {
        guard let session = sessions[browserId] else {
            throw BrowserAutomationError.sessionNotFound
        }
        return session
    }

    private func selector(for browserId: String, elementId: Int) throws -> String {
        guard let session = sessions[browserId] else {
            throw BrowserAutomationError.sessionNotFound
        }
        guard let snap = session.snap as? [[String: Any]] else {
            throw BrowserAutomationError.elementNotFound(elementId)
        }
        guard let selector = snap.first(where: { ($0["id"] as? Int) == elementId })?["selector"] as? String else {
            throw BrowserAutomationError.elementNotFound(elementId)
        }
        return selector
    }

    private func evaluate(browserId: String, script: String) async throws -> Any {
        let session = try session(for: browserId)
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                session.webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: value)
                    }
                }
            } ?? true
        } catch {
            throw BrowserAutomationError.scriptExecutionFailed
        }
    }

    /// Returns the snap array with `selector` stripped from each item (callers
    /// only need `id` / `type` / `content` / `attrs`).
    private func strippedSnap(_ raw: Any) -> Any {
        guard let array = raw as? [[String: Any]] else {
            return raw
        }
        return array.map { item -> [String: Any] in
            var copy = item
            copy.removeValue(forKey: "selector")
            return copy
        }
    }

    private func scheduleIdleTimer(for browserId: String) {
        guard let session = sessions[browserId], session.autoCloseTimeout > 0 else {
            return
        }
        session.cancelIdleTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: session.autoCloseTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      let active = self.sessions[browserId],
                      !active.isClosing else { return }
                openmacLog("Browser \(browserId) idle timeout, auto-closing")
                await self.close(browserId: browserId)
            }
        }
        timer.tolerance = min(1.0, session.autoCloseTimeout * 0.1)
        session.idleTimer = timer
    }

    private func cleanupSession(browserId: String, closeWindow: Bool) {
        guard let session = sessions.removeValue(forKey: browserId) else {
            return
        }
        session.isClosing = true
        session.cancelIdleTimer()
        session.webView.navigationDelegate = nil
        session.webView.stopLoading()
        session.window.delegate = nil
        session.window.contentView = nil
        if closeWindow {
            session.window.orderOut(nil)
            session.window.close()
        }
    }

    private static func normalizeURL(_ input: String) -> String {
        let lowercased = input.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return input
        }
        return "https://\(input)"
    }

    private func scriptContent() -> String? {
        if let scriptContentCache {
            return scriptContentCache
        }
        guard let scriptURL = Bundle.main.url(forResource: "browser-use", withExtension: "js"),
              let content = try? String(contentsOf: scriptURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        scriptContentCache = content
        return content
    }

    /// Stringifies a JS result the same way RACT's completion-handler path did
    /// (`"\(result ?? "")"`), while preserving richer types (arrays/objects are
    /// JSON-encoded) so `snap` returns structured data rather than `[object Object]`.
    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any], JSONSerialization.isValidJSONObject(array),
           let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(value)"
    }
}

extension BrowserAutomationService: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let browserId = window.identifier?.rawValue else {
            return
        }
        guard let session = sessions[browserId], !session.isClosing else {
            return
        }
        cleanupSession(browserId: browserId, closeWindow: false)
    }
}
#endif