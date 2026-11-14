import Foundation

/// Where TakeoutHub keeps its data. With `TAKEOUTHUB_HOME` (tests only), state, log and default
/// folders all go into that folder and the real data stays untouched.
enum AppPaths {
    static let testHome: URL? = ProcessInfo.processInfo.environment["TAKEOUTHUB_HOME"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    static var isTest: Bool { testHome != nil }

    private static var home: URL { testHome ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    static var support: URL {
        testHome?.appendingPathComponent("support", isDirectory: true)
            ?? home.appendingPathComponent("Library/Application Support/TakeoutHub", isDirectory: true)
    }

    static var stateFile: URL { support.appendingPathComponent("state.json") }

    static var logFile: URL {
        testHome?.appendingPathComponent("TakeoutHub.log")
            ?? home.appendingPathComponent("Library/Logs/TakeoutHub.log")
    }

    static var defaultArchives: URL { home.appendingPathComponent("TakeoutHub/Archive", isDirectory: true) }
    static var defaultPhotos: URL { home.appendingPathComponent("TakeoutHub/Fotos", isDirectory: true) }
}

/// A Takeout part, or any other file downloaded in the browser.
struct DownloadItem: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case queued
        case running
        case paused
        /// Connection error: retries after a delay or once the network is back.
        case waiting
        /// Google wants a new sign-in, or the link has expired.
        case needsLogin
        /// An error that waiting won't fix (e.g. disk full).
        case failed
        case done
    }

    var id = UUID()
    var fileName: String
    /// Download folder; stays even if the default folder changes later.
    var folder: String
    /// The link clicked in the browser (for Takeout: takeout.google.com/…/download?…).
    var sourceURL: URL
    /// Target after redirects; tried first when resuming, without requesting the Takeout link again.
    var directURL: URL?
    var totalBytes: Int64?
    var receivedBytes: Int64 = 0
    var state: State = .queued
    var message: String?
    var addedAt = Date()
    var finishedAt: Date?
    /// How often the Takeout link was requested (Google allows only a few downloads per part).
    var linkRequests = 0
    var extractedAt: Date?

    var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }
    var fileURL: URL { folderURL.appendingPathComponent(fileName) }
    var partURL: URL { folderURL.appendingPathComponent(fileName + ".part") }

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    /// nil for sizes outside 0 … 1 PiB: nonsense for a Takeout part (at most 50 GB), and taken over from a
    /// server or an edited `state.json` they would overflow the sums in the views on every launch.
    static func plausibleSize(_ bytes: Int64?) -> Int64? {
        bytes.flatMap { (0...(1 << 50)).contains($0) ? $0 : nil }
    }

    var isActive: Bool { state == .running || state == .queued || state == .waiting }

    var isArchive: Bool {
        let name = fileName.lowercased()
        return name.hasSuffix(".zip") || name.hasSuffix(".tgz") || name.hasSuffix(".tar.gz")
    }
}

struct Settings: Codable, Equatable {
    var archiveFolder = AppPaths.defaultArchives.path
    var photosFolder = AppPaths.defaultPhotos.path
    var keepAwake = true
    var trashAfterExtract = false
    /// Sort into month folders after extraction (`MonthSorter`).
    var sortIntoMonths = false

    var archiveURL: URL { URL(fileURLWithPath: archiveFolder, isDirectory: true) }
    var photosURL: URL { URL(fileURLWithPath: photosFolder, isDirectory: true) }

    init() {}

    /// Missing keys (older `state.json`) fall back to the defaults; otherwise loading would drop the whole
    /// state including the queue.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        archiveFolder = try container.decodeIfPresent(String.self, forKey: .archiveFolder) ?? defaults.archiveFolder
        photosFolder = try container.decodeIfPresent(String.self, forKey: .photosFolder) ?? defaults.photosFolder
        keepAwake = try container.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? defaults.keepAwake
        trashAfterExtract = try container.decodeIfPresent(Bool.self, forKey: .trashAfterExtract) ?? defaults.trashAfterExtract
        sortIntoMonths = try container.decodeIfPresent(Bool.self, forKey: .sortIntoMonths) ?? defaults.sortIntoMonths
    }
}

/// State on disk: one JSON file, written atomically.
enum Store {
    struct Snapshot: Codable {
        var items: [DownloadItem] = []
        var settings = Settings()
    }

    static func load() -> Snapshot {
        guard let data = try? Data(contentsOf: AppPaths.stateFile) else { return Snapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(Snapshot.self, from: data) { return snapshot }
        // The next save would replace it with an empty queue; keep it next to the new one instead.
        let stamp = Fmt.stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let backup = AppPaths.support.appendingPathComponent("state-defekt-\(stamp).json")
        let kept = (try? FileManager.default.moveItem(at: AppPaths.stateFile, to: backup)) != nil
        LogFile.append("\(Fmt.stamp.string(from: Date())) WARNUNG: state.json ließ sich nicht lesen"
                       + (kept ? " und liegt jetzt als \(backup.lastPathComponent) daneben" : "")
                       + ". Warteschlange und Einstellungen beginnen neu.")
        return Snapshot()
    }

    static func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? data.write(to: AppPaths.stateFile, options: .atomic)
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Free space on the folder's volume, or on that of the nearest existing parent.
    static func freeSpace(_ folder: URL) -> Int64? {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// "name.zip" → "name (2).zip" if taken.
    static func uniqueName(_ name: String, in folder: URL, taken: Set<String>) -> String {
        func free(_ candidate: String) -> Bool {
            !taken.contains(candidate)
                && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
                && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate + ".part").path)
        }
        if free(name) { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            if free(candidate) { return candidate }
            counter += 1
        }
    }

    /// File name from the browser without path components.
    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "download-\(Int(Date().timeIntervalSince1970))" : cleaned
    }
}

/// Log at `~/Library/Logs/TakeoutHub.log`, lines `YYYY-MM-DD hh:mm:ss text`.
enum LogFile {
    static func append(_ line: String) {
        let url = AppPaths.logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    static func tail(limit: Int = 300) -> [String] {
        guard let text = try? String(contentsOf: AppPaths.logFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit).map(String.init)
    }
}
