import AppKit
import Network
import Observation

enum Pane: String, CaseIterable, Identifiable {
    case browser, downloads, photos
    var id: String { rawValue }
}

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let until: Date
}

struct ExtractionStatus: Equatable {
    var archive: String
    var index: Int
    var count: Int
    var done = 0
    var total = 0
    var phase: String
}

/// Runs the download queue, one download at a time: Google allows a single connection per file, and
/// on a slow line parallel downloads only slow each other down.
///
/// An attempt first tries the last known direct URL (`directURL`) with `Range`; if the server refuses,
/// it goes once through the Takeout link (which Google counts as a new download). Connection errors
/// retry after 10 s, 30 s, 1 min, then every 2 min, and immediately once the network is back.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    /// Cookie source; tests replace it before `shared` is created.
    static var cookieProvider: @MainActor () async -> [HTTPCookie] = { await Browser.shared.cookies() }
    /// Delays between attempts; tests shorten them with TAKEOUTHUB_RETRY_SCALE.
    static let retryDelays: [Double] = {
        let scale = AppPaths.isTest
            ? Double(ProcessInfo.processInfo.environment["TAKEOUTHUB_RETRY_SCALE"] ?? "") ?? 1 : 1
        return [10, 30, 60, 120].map { $0 * scale }
    }()

    var pane: Pane? = .browser
    private(set) var items: [DownloadItem]
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            if settings.keepAwake != oldValue.keepAwake { activityToken = nil }
            save()
            updateActivity()
        }
    }
    var notice: Notice?
    var banner: Banner?
    /// Bytes per second of the running download, averaged over the last 20 s.
    private(set) var speed: Double?
    private(set) var retryAt: [UUID: Date] = [:]
    private(set) var online = true
    private(set) var logLines: [String]
    private(set) var extraction: ExtractionStatus?
    private(set) var lastDates: String?

    @ObservationIgnored private var transfer: Transfer?
    /// Set from the start of an attempt until it ends, including while the cookies are fetched.
    @ObservationIgnored private(set) var activeID: UUID?
    @ObservationIgnored private var attemptUsedDirect = false
    @ObservationIgnored private var attemptStartBytes: Int64 = 0
    @ObservationIgnored private var restartLogged = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var samples: [(time: Date, bytes: Int64)] = []
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var activityToken: NSObjectProtocol? {
        didSet { if let oldValue, oldValue !== activityToken { ProcessInfo.processInfo.endActivity(oldValue) } }
    }
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var ticker: Timer?
    /// After `prepareForQuit` the saved state must stay as it is.
    @ObservationIgnored private var quitting = false

    private init() {
        let snapshot = Store.load()
        settings = snapshot.settings
        logLines = LogFile.tail()
        items = snapshot.items.map { stored in
            var item = stored
            item.totalBytes = DownloadItem.plausibleSize(item.totalBytes)
            item.receivedBytes = DownloadItem.plausibleSize(item.receivedBytes) ?? 0
            if item.state != .done {
                // The partial file is the truth; interrupted downloads resume after launch.
                item.receivedBytes = Store.fileSize(item.partURL) ?? 0
                if item.state == .running || item.state == .waiting { item.state = .queued }
            }
            return item
        }

        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async { AppModel.shared.networkChanged(ok) }
        }
        monitor.start(queue: DispatchQueue(label: "TakeoutHub.Network"))
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.tick() }
        }
        if items.contains(where: { $0.state == .queued }) {
            log("Unterbrochene Downloads werden fortgesetzt")
        }
        DispatchQueue.main.async { AppModel.shared.pump() }
    }

    // MARK: UI queries

    var isDownloading: Bool { activeID != nil }

    var activeItem: DownloadItem? { activeID.flatMap(item) }

    func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    var pendingItems: [DownloadItem] { items.filter { $0.state != .done } }

    var totalBytes: Int64 { items.reduce(0) { $0 + ($1.totalBytes ?? $1.receivedBytes) } }
    var receivedBytes: Int64 { items.reduce(0) { $0 + ($1.state == .done ? ($1.totalBytes ?? $1.receivedBytes) : $1.receivedBytes) } }

    /// What is left to download, as far as the sizes are known.
    var remainingBytes: Int64 {
        pendingItems.reduce(0) { $0 + max(0, ($1.totalBytes ?? $1.receivedBytes) - $1.receivedBytes) }
    }

    var eta: Double? {
        guard let speed, speed > 0 else { return nil }
        return Double(remainingBytes) / speed
    }

    var extractable: [DownloadItem] {
        items.filter {
            $0.state == .done && $0.isArchive && $0.extractedAt == nil
                && FileManager.default.fileExists(atPath: $0.fileURL.path)
        }
    }

    // MARK: Downloads from the browser

    /// A click on "Download" in the browser. A known part (same name, same folder) gets the fresh links
    /// and resumes where it stopped.
    func adopt(source: URL?, final: URL?, suggestedName: String, expected: Int64?) {
        guard let link = source ?? final else { return }
        let name = Store.sanitize(suggestedName)
        let folder = settings.archiveURL.path
        let direct = final != link ? final : nil

        if let index = items.firstIndex(where: { $0.fileName == name && $0.folder == folder }) {
            var item = items[index]
            if item.state == .done {
                showBanner("\(name) ist schon vollständig geladen.")
                return
            }
            item.sourceURL = link
            item.directURL = direct
            // The browser just requested the link, and Google counts that as a download.
            item.linkRequests += 1
            if let expected, item.totalBytes == nil { item.totalBytes = expected }
            let running = activeID == item.id
            if !running {
                item.state = .queued
                item.message = nil
                retryAt[item.id] = nil
            }
            items[index] = item
            log("\(name): neuer Link aus dem Browser übernommen")
            showBanner(running ? "\(name) wird bereits geladen – der neue Link gilt ab dem nächsten Versuch."
                               : "\(name): neuer Link übernommen, der Download macht an derselben Stelle weiter.")
        } else {
            let unique = Store.uniqueName(name, in: settings.archiveURL,
                                          taken: Set(items.filter { $0.folder == folder }.map(\.fileName)))
            var item = DownloadItem(fileName: unique, folder: folder, sourceURL: link)
            item.directURL = direct
            item.totalBytes = expected
            item.linkRequests = 1
            items.append(item)
            log("\(unique): aus dem Browser übernommen\(expected.map { " (\(Fmt.size($0)))" } ?? "")")
            showBanner(isDownloading ? "\(unique) steht in der Warteschlange." : "\(unique) wird geladen.")
        }
        save()
        pump()
    }

    func showBanner(_ text: String) {
        banner = Banner(text: text, until: Date().addingTimeInterval(7))
    }

    // MARK: Controls

    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state != .done else { return }
        items[index].state = .paused
        retryAt[id] = nil
        if activeID == id { transfer?.cancel() }
        save()
        updateActivity()
    }

    func resume(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state != .done,
              activeID != id else { return }
        items[index].state = .queued
        items[index].message = nil
        retryAt[id] = nil
        failures = 0
        save()
        pump()
    }

    func pauseAll() {
        for item in items where item.isActive { pause(item.id) }
    }

    func resumeAll() {
        for item in items where [.paused, .failed, .needsLogin, .waiting].contains(item.state) { resume(item.id) }
    }

    var canPauseAll: Bool { items.contains { $0.isActive } }
    var canResumeAll: Bool { items.contains { [.paused, .failed, .needsLogin, .waiting].contains($0.state) } }

    /// `trash`: also moves the partial or finished file to the Trash.
    func remove(_ id: UUID, trash: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        retryAt[id] = nil
        if activeID == id { transfer?.cancel() }
        if trash {
            for url in [item.partURL, item.fileURL] where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        log("\(item.fileName): aus der Liste entfernt\(trash ? ", Datei im Papierkorb" : "")")
        save()
        pump()
    }

    // MARK: Queue

    private func pump() {
        defer { updateActivity() }
        guard !quitting, activeID == nil, online, let next = items.first(where: { $0.state == .queued }) else { return }
        start(next.id)
    }

    private func start(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        do {
            try FileManager.default.createDirectory(at: item.folderURL, withIntermediateDirectories: true)
        } catch {
            items[index].state = .failed
            items[index].message = "Ordner \(Fmt.path(item.folderURL)) lässt sich nicht anlegen: \(error.localizedDescription)"
            log("\(item.fileName): \(items[index].message ?? "")")
            save()
            return
        }
        item.receivedBytes = Store.fileSize(item.partURL) ?? 0
        let useDirect = item.directURL != nil
        let url = item.directURL ?? item.sourceURL
        if !useDirect { item.linkRequests += 1 }
        item.state = .running
        item.message = nil
        items[index] = item

        activeID = id
        attemptUsedDirect = useDirect
        attemptStartBytes = item.receivedBytes
        restartLogged = false
        samples = [(Date(), item.receivedBytes)]
        speed = nil
        log("\(item.fileName): \(item.receivedBytes > 0 ? "fortgesetzt bei \(Fmt.size(item.receivedBytes))" : "gestartet")"
            + (useDirect ? "" : " (über den Takeout-Link)"))
        save()

        let partURL = item.partURL
        let knownTotal = item.totalBytes
        Task {
            let cookies = await Self.cookieProvider()
            // Paused or removed in the meantime?
            guard activeID == id, self.item(id)?.state == .running else {
                if activeID == id { activeID = nil }
                pump()
                return
            }
            let transfer = Transfer(
                url: url, partURL: partURL, knownTotal: knownTotal, cookies: cookies, userAgent: Browser.userAgent,
                onUpdate: { status in MainActor.assumeIsolated { AppModel.shared.update(id, status) } },
                onFinish: { status, outcome in
                    MainActor.assumeIsolated { AppModel.shared.finish(id, status, outcome) }
                })
            self.transfer = transfer
            transfer.start()
        }
    }

    private func update(_ id: UUID, _ status: Transfer.Status) {
        guard activeID == id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        if status.restarted && !restartLogged {
            restartLogged = true
            log("\(items[index].fileName): Server setzt nicht fort, Download beginnt von vorn")
            samples = []
        }
        items[index].receivedBytes = status.received
        if let total = status.total { items[index].totalBytes = total }
        if let final = status.finalURL, final != items[index].sourceURL { items[index].directURL = final }

        let now = Date()
        samples.append((now, status.received))
        samples.removeAll { now.timeIntervalSince($0.time) > 20 }
        if let first = samples.first, now.timeIntervalSince(first.time) >= 2 {
            speed = max(0, Double(status.received - first.bytes) / now.timeIntervalSince(first.time))
        }
        if now.timeIntervalSince(lastSave) > 15 { save() }
        updateBadge()
    }

    private func finish(_ id: UUID, _ status: Transfer.Status, _ outcome: Transfer.Outcome) {
        guard activeID == id, !quitting else { return }
        transfer = nil
        activeID = nil
        speed = nil
        samples = []
        defer {
            save()
            updateBadge()
            pump()
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].receivedBytes = status.received
        if let total = status.total { items[index].totalBytes = total }
        let name = items[index].fileName
        if status.received > attemptStartBytes { failures = 0 }

        let viaLinkAgain: Bool
        switch outcome {
        case .expired, .needsLogin: viaLinkAgain = attemptUsedDirect
        default: viaLinkAgain = false
        }
        if viaLinkAgain {
            items[index].directURL = nil
            if items[index].state == .running { items[index].state = .queued }
            log("\(name): direkte Adresse nicht mehr gültig, fordere über den Takeout-Link neu an")
            return
        }

        switch outcome {
        case .finished:
            complete(index)
        case .cancelled:
            if items[index].state == .running { items[index].state = .paused }
            log("\(name): angehalten bei \(Fmt.size(status.received))")
        case .expired(let code):
            items[index].state = .needsLogin
            items[index].message = "Link abgelaufen (HTTP \(code)). In „Google Takeout“ unter „Exporte verwalten“ "
                + "noch einmal auf „Herunterladen“ klicken – es geht an derselben Stelle weiter."
            log("\(name): Link abgelaufen (HTTP \(code))")
        case .needsLogin(let text):
            items[index].state = .needsLogin
            items[index].message = text + " Unter „Google Takeout“ anmelden, dann „Erneut versuchen“."
            log("\(name): \(text)")
            notice = Notice(title: "Google verlangt eine Anmeldung",
                            message: "\(name): \(text) Bitte im Bereich „Google Takeout“ anmelden "
                                + "und den Download danach fortsetzen.")
        case .failed(let text, let retry):
            if retry && items[index].state == .running {
                let delay = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
                failures += 1
                items[index].state = .waiting
                items[index].message = text
                retryAt[id] = Date().addingTimeInterval(delay)
                log("\(name): \(text) bei \(Fmt.size(status.received)) – neuer Versuch in \(Fmt.duration(delay))")
            } else if !retry {
                items[index].state = .failed
                items[index].message = text
                log("\(name): WARNUNG: \(text)")
            }
        }
    }

    private func complete(_ index: Int) {
        let item = items[index]
        var target = item.fileURL
        if FileManager.default.fileExists(atPath: target.path) {
            let unique = Store.uniqueName(item.fileName, in: item.folderURL, taken: [])
            target = item.folderURL.appendingPathComponent(unique)
            items[index].fileName = unique
        }
        do {
            try FileManager.default.moveItem(at: item.partURL, to: target)
        } catch {
            items[index].state = .failed
            items[index].message = "Fertige Datei lässt sich nicht umbenennen: \(error.localizedDescription)"
            log("\(item.fileName): WARNUNG: \(items[index].message ?? "")")
            return
        }
        items[index].state = .done
        items[index].message = nil
        items[index].finishedAt = Date()
        items[index].directURL = nil
        log("\(items[index].fileName): fertig (\(Fmt.size(items[index].receivedBytes)))")
        if !items.contains(where: { $0.isActive }) {
            if let app = NSApp as NSApplication? { app.requestUserAttention(.informationalRequest) }
        }
    }

    private func tick() {
        let now = Date()
        if online {
            for (id, date) in retryAt where date <= now {
                retryAt[id] = nil
                if let index = items.firstIndex(where: { $0.id == id }), items[index].state == .waiting {
                    items[index].state = .queued
                }
            }
        }
        if let banner, banner.until <= now { self.banner = nil }
        // Without new data the shown rate falls towards zero instead of freezing.
        if activeID != nil, let last = samples.last, now.timeIntervalSince(last.time) > 5 {
            samples.append((now, last.bytes))
            samples.removeAll { now.timeIntervalSince($0.time) > 20 }
            if let first = samples.first, now.timeIntervalSince(first.time) > 0 {
                speed = max(0, Double(last.bytes - first.bytes) / now.timeIntervalSince(first.time))
            }
        }
        pump()
    }

    private func networkChanged(_ ok: Bool) {
        guard ok != online else { return }
        online = ok
        log(ok ? "Internetverbindung wieder da" : "Keine Internetverbindung")
        if ok {
            // Give the connection a moment, then retry everything that is waiting.
            let soon = Date().addingTimeInterval(3)
            for item in items where item.state == .waiting { retryAt[item.id] = soon }
            failures = 0
        }
    }

    /// Prevents idle sleep (or just App Nap) while there is work to do.
    private func updateActivity() {
        let busy = items.contains { $0.isActive } || extraction != nil
        if !busy {
            activityToken = nil
            return
        }
        guard activityToken == nil else { return }
        let options: ProcessInfo.ActivityOptions = settings.keepAwake
            ? [.userInitiated, .idleSystemSleepDisabled]
            : .userInitiatedAllowingIdleSystemSleep
        activityToken = ProcessInfo.processInfo.beginActivity(options: options, reason: "Google-Takeout-Download")
    }

    private func updateBadge() {
        guard let app = NSApp as NSApplication? else { return }
        let label = activeItem?.fraction.map { Fmt.percent($0) }
        if app.dockTile.badgeLabel != label { app.dockTile.badgeLabel = label }
    }

    /// Queues the running download again so it resumes on the next launch, and stops tar.
    func prepareForQuit() {
        quitting = true
        if let activeID, let index = items.firstIndex(where: { $0.id == activeID }) {
            items[index].state = .queued
            log("\(items[index].fileName): beim Beenden unterbrochen bei \(Fmt.size(items[index].receivedBytes))")
        }
        transfer?.cancel()
        Extractor.stop()
        save()
    }

    // MARK: Folders

    func chooseFolder(photos: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Wählen"
        panel.message = photos ? "Ordner für die entpackten Fotos" : "Ordner für die Takeout-Archive"
        panel.directoryURL = photos ? settings.photosURL : settings.archiveURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if photos { settings.photosFolder = url.path } else { settings.archiveFolder = url.path }
    }

    func reveal(_ item: DownloadItem) {
        let url = FileManager.default.fileExists(atPath: item.fileURL.path) ? item.fileURL : item.partURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(item.folderURL)
        }
    }

    func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openLog() {
        NSWorkspace.shared.open(AppPaths.logFile)
    }

    // MARK: Extraction

    /// Extracts all finished, not yet extracted archives one after another into the photos folder,
    /// then runs `finishPhotos`.
    func extractAll() {
        let list = extractable
        guard extraction == nil, !list.isEmpty else { return }
        let destination = settings.photosURL
        let trashAfter = settings.trashAfterExtract
        // Set right away, not only in the task, so a second click can't start a parallel run.
        extraction = ExtractionStatus(archive: list[0].fileName, index: 1, count: list.count, phase: "Inhalt wird gelesen …")
        Task {
            var extracted = 0
            var failure: String?
            for (number, item) in list.enumerated() {
                extraction = ExtractionStatus(archive: item.fileName, index: number + 1, count: list.count,
                                              phase: "Inhalt wird gelesen …")
                updateActivity()
                let archive = item.fileURL
                let total = await Self.background { Extractor.count(archive) }
                guard let total else {
                    failure = "\(item.fileName) lässt sich nicht lesen – ist die Datei beschädigt?"
                    break
                }
                extraction?.total = total
                extraction?.phase = "Wird entpackt …"
                log("\(item.fileName): wird nach \(Fmt.path(destination)) entpackt (\(Fmt.count(total)) Dateien)")
                let result = await Self.background {
                    Extractor.extract(archive, to: destination) { done in
                        DispatchQueue.main.async { AppModel.shared.extraction?.done = done }
                    }
                }
                guard result.ok else {
                    failure = "\(item.fileName): \(result.trimmed.isEmpty ? "tar endete mit Code \(result.status)" : result.trimmed)"
                    break
                }
                extracted += 1
                if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].extractedAt = Date() }
                log("\(item.fileName): entpackt")
                if trashAfter {
                    do {
                        try FileManager.default.trashItem(at: archive, resultingItemURL: nil)
                        log("\(item.fileName): Archiv in den Papierkorb gelegt")
                    } catch {
                        log("\(item.fileName): WARNUNG: Archiv ließ sich nicht in den Papierkorb legen")
                    }
                }
                save()
            }
            if let failure {
                extraction = nil
                log("WARNUNG: Entpacken abgebrochen – \(failure)")
                notice = Notice(title: "Entpacken abgebrochen", message: failure)
                updateActivity()
                return
            }
            extraction?.done = 0
            extraction?.total = 0
            let summary = await finishPhotos(in: destination)
            extraction = nil
            updateActivity()
            log("\(extracted) Archiv(e) entpackt. \(summary.joined(separator: " "))")
            notice = Notice(title: "\(extracted == 1 ? "Ein Archiv" : "\(extracted) Archive") entpackt",
                            message: "Die Fotos liegen in \(Fmt.path(destination)).\n\n\(summary.joined(separator: "\n\n"))")
        }
    }

    /// Runs `finishPhotos` alone, e.g. for folders extracted earlier.
    func applyDates() {
        guard extraction == nil else { return }
        let destination = settings.photosURL
        let sorts = settings.sortIntoMonths
        extraction = ExtractionStatus(archive: "", index: 0, count: 0, phase: "Aufnahmedatum wird übernommen …")
        updateActivity()
        Task {
            let summary = await finishPhotos(in: destination)
            extraction = nil
            updateActivity()
            log("Aufnahmedatum in \(Fmt.path(destination)): \(summary.joined(separator: " "))")
            notice = Notice(title: sorts ? "Aufnahmedatum übernommen und einsortiert" : "Aufnahmedatum übernommen",
                            message: summary.joined(separator: "\n\n"))
        }
    }

    /// Sets the capture dates from the JSON sidecars and, if enabled, sorts into month folders.
    /// Returns one summary per step.
    private func finishPhotos(in destination: URL) async -> [String] {
        extraction?.phase = "Aufnahmedatum wird übernommen …"
        let dates = await Self.background { TakeoutDates.apply(in: destination) }
        var summary = [dates.summary]
        if settings.sortIntoMonths {
            extraction?.phase = "Wird in Monatsordner sortiert …"
            let units = dates.units
            let sorted = await Self.background { MonthSorter.apply(units, in: destination) }
            for failure in sorted.failures.prefix(20) { log("WARNUNG: Einsortieren: \(failure)") }
            if sorted.failures.count > 20 { log("WARNUNG: Einsortieren: \(sorted.failures.count - 20) weitere Fehler") }
            summary.append(sorted.summary)
        }
        lastDates = summary.joined(separator: " ")
        return summary
    }

    // MARK: Helpers

    func log(_ message: String) {
        let line = "\(Fmt.stamp.string(from: Date())) \(message)"
        LogFile.append(line)
        logLines.append(line)
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }

    private func save() {
        lastSave = Date()
        Store.save(Store.Snapshot(items: items, settings: settings))
    }

    nonisolated static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
