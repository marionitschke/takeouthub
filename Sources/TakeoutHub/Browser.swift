import AppKit
import Observation
import SwiftUI
import WebKit

/// Built-in browser for the Google sign-in and Takeout. The session lives in WebKit's per-app data
/// store; the downloader takes its cookies for every attempt.
///
/// WebKit never loads a download itself: every download a page starts is handed to `AppModel.adopt`,
/// which resumes after interruptions.
@MainActor @Observable
final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let shared = Browser()

    static let createURL = URL(string: "https://takeout.google.com/settings/takeout/custom/photos")!
    static let manageURL = URL(string: "https://takeout.google.com/manage")!

    /// Google often refuses sign-in in embedded browsers and spots WKWebView by the missing Safari suffix
    /// ("Version/… Safari/…"). The downloader sends the same user agent.
    static let userAgent: String = {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = info?["CFBundleShortVersionString"] as? String ?? "18.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version) Safari/605.1.15"
    }()

    @ObservationIgnored let webView: WKWebView
    private(set) var address = ""
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override private init() {
        let config = WKWebViewConfiguration()
        // Test and snapshot runs (TAKEOUTHUB_HOME set) must not see the real sign-in.
        config.websiteDataStore = AppPaths.isTest ? .nonPersistent() : .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self

        observations = [
            webView.observe(\.url) { view, _ in
                let text = view.url?.absoluteString ?? ""
                Task { @MainActor in Browser.shared.address = text }
            },
            webView.observe(\.title) { view, _ in
                let text = view.title ?? ""
                Task { @MainActor in Browser.shared.title = text }
            },
            webView.observe(\.canGoBack) { view, _ in
                let value = view.canGoBack
                Task { @MainActor in Browser.shared.canGoBack = value }
            },
            webView.observe(\.canGoForward) { view, _ in
                let value = view.canGoForward
                Task { @MainActor in Browser.shared.canGoForward = value }
            },
            webView.observe(\.isLoading) { view, _ in
                let value = view.isLoading
                Task { @MainActor in Browser.shared.isLoading = value }
            },
        ]
        if !AppPaths.isTest { load(Self.manageURL) }
    }

    var host: String? { URL(string: address)?.host }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func open(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        if let url = URL(string: withScheme) { load(url) }
    }

    func cookies() async -> [HTTPCookie] {
        await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    }

    /// Removes cookies and website data of this browser only, not Safari's or Chrome's.
    func signOut() async {
        let store = webView.configuration.websiteDataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        load(Self.manageURL)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        (navigationAction.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: Downloads

    /// Returning `nil` cancels WebKit's download; `AppModel` takes it over.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let length = response.expectedContentLength
        AppModel.shared.adopt(source: download.originalRequest?.url, final: response.url,
                              suggestedName: suggestedFilename, expected: length > 0 ? DownloadItem.plausibleSize(length) : nil)
        return nil
    }

    // MARK: Windows and dialogs

    /// Pop-ups and target=_blank links open in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.request.url != nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Hinweis"
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Bestätigen"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Hosts the shared WKWebView so the page survives switching panes.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
