import Foundation

/// A single download attempt. Appends to the partial file from its current size (`Range: bytes=n-`)
/// and reports progress and outcome on the main thread. Each attempt gets its own URLSession so the
/// browser's cookies are fresh.
///
/// All mutable state is only touched on the serial `queue`.
final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Equatable {
        case finished
        case cancelled
        /// Google returns a web page instead of the file or redirects to the sign-in.
        case needsLogin(String)
        /// 401/403/404/410: link expired or not authorized.
        case expired(Int)
        /// `retry: false` when waiting won't help (e.g. disk full).
        case failed(String, retry: Bool)
    }

    struct Status {
        var received: Int64
        var total: Int64?
        /// The server ignored the range; the partial file starts over.
        var restarted = false
        /// Where the file actually comes from, after redirects.
        var finalURL: URL?
    }

    private let url: URL
    private let partURL: URL
    /// Size reported by an earlier attempt. A response announcing another size is a different file; it must
    /// neither be appended to the partial file nor replace it.
    private let knownTotal: Int64?
    private let cookies: [HTTPCookie]
    private let userAgent: String
    private let onUpdate: @Sendable (Status) -> Void
    private let onFinish: @Sendable (Status, Outcome) -> Void

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "TakeoutHub.Transfer"
        return queue
    }()
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var status: Status
    private var decided: Outcome?
    private var cancelledByUser = false
    private var unsynced: Int64 = 0
    private var lastUpdate = Date.distantPast

    /// Forces data to disk every 64 MB so a crash loses at most that much.
    private static let syncEvery: Int64 = 64 << 20

    init(url: URL, partURL: URL, knownTotal: Int64?, cookies: [HTTPCookie], userAgent: String,
         onUpdate: @escaping @Sendable (Status) -> Void,
         onFinish: @escaping @Sendable (Status, Outcome) -> Void) {
        self.url = url
        self.partURL = partURL
        self.knownTotal = knownTotal
        self.cookies = cookies
        self.userAgent = userAgent
        self.onUpdate = onUpdate
        self.onFinish = onFinish
        status = Status(received: Store.fileSize(partURL) ?? 0)
    }

    func start() {
        queue.addOperation { [self] in
            let config = URLSessionConfiguration.ephemeral
            // Time without a single byte before the attempt counts as dropped.
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 14 * 24 * 3600
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            for cookie in cookies { config.httpCookieStorage?.setCookie(cookie) }
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)

            var request = URLRequest(url: url)
            applyHeaders(&request)
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        queue.addOperation { [self] in
            cancelledByUser = true
            task?.cancel()
        }
    }

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // No compression, otherwise byte ranges no longer refer to the file.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if status.received > 0 {
            request.setValue("bytes=\(status.received)-", forHTTPHeaderField: "Range")
        } else {
            request.setValue(nil, forHTTPHeaderField: "Range")
        }
    }

    private static func isLoginPage(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.hasPrefix("accounts.google.") || host == "accounts.youtube.com"
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if Self.isLoginPage(request.url) {
            decided = .needsLogin("Google verlangt eine neue Anmeldung.")
            completionHandler(nil)
            task.cancel()
            return
        }
        var next = request
        applyHeaders(&next)
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // E.g. the redirect to the sign-in was refused; its response must not overwrite that outcome.
        guard decided == nil else { return completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else {
            decided = .failed("Keine HTTP-Antwort", retry: true)
            return completionHandler(.cancel)
        }
        let code = http.statusCode
        let mime = (http.mimeType ?? "").lowercased()
        if Self.isLoginPage(http.url) || ((200...299).contains(code) && mime == "text/html") {
            decided = .needsLogin("Google zeigt eine Webseite statt der Datei.")
            return completionHandler(.cancel)
        }
        let length = http.expectedContentLength > 0 ? DownloadItem.plausibleSize(http.expectedContentLength) : nil
        let announced: Int64? = switch code {
        case 206: Self.contentRange(http)?.total
        case 200: length
        case 416: Self.contentRange(http)?.total
        default: nil
        }
        if status.received > 0, let known = knownTotal, let announced, announced != known {
            decided = .failed("Die Datei auf dem Server ist anders groß (\(Fmt.size(announced)) statt \(Fmt.size(known))). "
                              + "Die Teildatei bleibt erhalten; für einen Neubeginn den Eintrag samt Teildatei entfernen.",
                              retry: false)
            return completionHandler(.cancel)
        }

        switch code {
        case 206:
            let range = Self.contentRange(http)
            let start = range?.start ?? -1
            if start != status.received {
                // Only a restart from zero can be taken over safely; anything else would be guesswork.
                guard start == 0 else {
                    decided = .failed("Server setzt bei Byte \(start) statt \(status.received) fort", retry: true)
                    return completionHandler(.cancel)
                }
                status.received = 0
                status.restarted = true
            }
            if let total = range?.total {
                status.total = total
            } else if let length {
                status.total = status.received + length
            }
        case 200:
            if status.received > 0 {
                status.received = 0
                status.restarted = true
            }
            status.total = length
        case 416:
            // Range beyond the end: if the partial file has exactly the full size, it is complete.
            if let total = announced ?? knownTotal, total == status.received, total > 0 {
                status.total = total
                decided = .finished
            } else {
                truncatePart()
                status.received = 0
                status.restarted = true
                decided = .failed("Teildatei passt nicht zur Datei auf dem Server, beginne von vorn", retry: true)
            }
            return completionHandler(.cancel)
        case 401, 403, 404, 410:
            decided = .expired(code)
            return completionHandler(.cancel)
        default:
            decided = .failed("Server antwortet mit HTTP \(code)", retry: true)
            return completionHandler(.cancel)
        }

        do {
            if !FileManager.default.fileExists(atPath: partURL.path) {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.truncate(atOffset: UInt64(status.received))
            try handle.seek(toOffset: UInt64(status.received))
            self.handle = handle
        } catch {
            decided = .failed("Teildatei lässt sich nicht schreiben: \(error.localizedDescription)", retry: false)
            return completionHandler(.cancel)
        }
        status.finalURL = http.url
        report()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, decided == nil else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            decided = .failed("Schreiben fehlgeschlagen: \(error.localizedDescription)", retry: false)
            dataTask.cancel()
            return
        }
        status.received += Int64(data.count)
        unsynced += Int64(data.count)
        if unsynced >= Self.syncEvery {
            try? handle.synchronize()
            unsynced = 0
        }
        if let total = status.total, status.received > total {
            decided = .failed("Server liefert mehr Daten als angekündigt", retry: true)
            dataTask.cancel()
            return
        }
        if Date().timeIntervalSince(lastUpdate) >= 0.25 { report() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let handle {
            try? handle.synchronize()
            try? handle.close()
            self.handle = nil
        }
        let outcome: Outcome
        if let decided {
            outcome = decided
        } else if cancelledByUser {
            outcome = .cancelled
        } else if let error {
            outcome = .failed(Self.describe(error), retry: true)
        } else if let total = status.total, status.received < total {
            outcome = .failed("Verbindung vorzeitig beendet", retry: true)
        } else if status.received == 0 {
            outcome = .failed("Server lieferte eine leere Datei", retry: true)
        } else {
            if status.total == nil { status.total = status.received }
            outcome = .finished
        }
        session.finishTasksAndInvalidate()
        let final = status
        let onFinish = onFinish
        DispatchQueue.main.async { onFinish(final, outcome) }
    }

    // MARK: Helpers

    private func report() {
        lastUpdate = Date()
        let current = status
        let onUpdate = onUpdate
        DispatchQueue.main.async { onUpdate(current) }
    }

    private func truncatePart() {
        guard let handle = try? FileHandle(forWritingTo: partURL) else { return }
        try? handle.truncate(atOffset: 0)
        try? handle.close()
    }

    /// "bytes 100-199/1000" or "bytes */1000".
    static func contentRange(_ response: HTTPURLResponse) -> (start: Int64?, total: Int64?)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range")?.lowercased(),
              value.hasPrefix("bytes") else { return nil }
        let spec = value.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let start = parts[0] == "*" ? nil : parts[0].split(separator: "-").first.flatMap { Int64($0) }
        return (start, DownloadItem.plausibleSize(Int64(parts[1])))
    }

    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet: return "Keine Internetverbindung"
        case .networkConnectionLost: return "Verbindung abgebrochen"
        case .timedOut: return "Keine Daten mehr empfangen (Zeitüberschreitung)"
        case .cannotFindHost, .dnsLookupFailed: return "Server nicht erreichbar"
        case .cannotConnectToHost: return "Verbindung zum Server fehlgeschlagen"
        case .secureConnectionFailed: return "Sichere Verbindung fehlgeschlagen"
        default: return urlError.localizedDescription
        }
    }
}
