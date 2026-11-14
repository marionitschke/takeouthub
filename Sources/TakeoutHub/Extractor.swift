import Foundation

/// Extracts Takeout archives (.zip and .tgz) with the system `tar` (libarchive: ZIP64, umlauts).
/// The top folder "Takeout/" is dropped and all parts merge into the destination, e.g.
/// `<destination>/Google Fotos/Fotos von 2019/IMG_1234.JPG`. Existing files are never touched.
///
/// tar writes into a hidden staging folder inside the destination, and only an archive read without any
/// error is moved over. A full disk, a damaged entry, quitting or a crash therefore never leave a
/// half-written file in the destination, which `-k` would keep forever on the next run.
enum Extractor {
    /// Staging folders in the destination, one per run; leftovers of an interrupted run go on the next one.
    static let stagingPrefix = ".TakeoutHub-entpacken-"

    private static let lock = NSLock()
    private static var running: Process?
    private static var stopped = false

    /// Ends a running extraction when quitting. tar would otherwise carry on without the app.
    static func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        running?.terminate()
    }

    /// Number of files in the archive, without folders; nil if it can't be read.
    static func count(_ archive: URL) -> Int? {
        let result = Shell.run("/usr/bin/tar", ["-tf", archive.path], includeErrors: false)
        guard result.ok else { return nil }
        return result.output.split(separator: "\n").filter { !$0.hasSuffix("/") }.count
    }

    /// `progress` receives the number of entries extracted so far (throttled).
    static func extract(_ archive: URL, to destination: URL, progress: (Int) -> Void) -> Shell.Result {
        let fileManager = FileManager.default
        let staging = destination.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
            where name.hasPrefix(stagingPrefix) {
                discard(destination.path + "/" + name)
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            return Shell.Result(status: -1, output: "Zielordner lässt sich nicht anlegen: \(error.localizedDescription)")
        }
        defer { discard(staging.path) }

        var done = 0
        var problems: [String] = []
        let arguments = ["-x", "-k", "-v", "-f", archive.path, "-C", staging.path,
                         "--strip-components", "1", "--exclude", "*/archive_browser.html"]
        let status = Shell.stream("/usr/bin/tar", arguments, environment: [:], started: { process in
            lock.lock()
            running = process
            if stopped { process.terminate() }
            lock.unlock()
        }) { line in
            // "x <name>" per entry, "x <name>: <error>" if that entry failed
            if line.hasPrefix("x ") {
                done += 1
                if done % 25 == 0 { progress(done) }
            }
            if (!line.hasPrefix("x ") || line.contains(": ")) && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append(line)
            }
        }
        lock.lock()
        running = nil
        lock.unlock()
        progress(done)
        guard status == 0 else {
            return Shell.Result(status: status, output: problems.suffix(5).joined(separator: "\n"))
        }
        let failures = merge(staging.path, into: destination.path)
        return Shell.Result(status: failures.isEmpty ? 0 : 1, output: failures.suffix(5).joined(separator: "\n"))
    }

    /// Moves the extracted files from `staging` into `destination`, creating folders as needed. Names
    /// already taken there stay untouched, like `tar -k`. Only real folders are entered, so a symlink can't
    /// redirect files elsewhere; links and special files from the archive are dropped. Returns the failures.
    private static func merge(_ staging: String, into destination: String) -> [String] {
        var failures: [String] = []
        func fail(_ path: String, _ reason: String) {
            failures.append("\(path.dropFirst()): \(reason)")
        }
        func walk(_ relative: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: staging + relative) else {
                return fail(relative + "/", "Ordner lässt sich nicht lesen")
            }
            for name in names {
                let path = relative + "/" + name
                let target = destination + path
                var info = stat()
                guard lstat(staging + path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    let code = mkdir(target, 0o755) == 0 ? 0 : errno
                    if code != 0 && code != EEXIST {
                        fail(path, String(cString: strerror(code)))
                    } else if lstat(target, &info) != 0 || info.st_mode & S_IFMT != S_IFDIR {
                        fail(path, "Name ist belegt, aber kein Ordner")
                    } else {
                        // tar sets folder modes from the archive last; read-only would block moving out.
                        chmod(staging + path, S_IRWXU)
                        walk(path)
                    }
                case S_IFREG:
                    let code = renamex_np(staging + path, target, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
                    if code != 0 && code != EEXIST { fail(path, String(cString: strerror(code))) }
                default:
                    break
                }
            }
        }
        walk("")
        return failures
    }

    /// Deletes a staging folder, also when the archive made folders in it read-only. Never follows links.
    private static func discard(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            chmod(path, S_IRWXU)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                discard(path + "/" + name)
            }
            rmdir(path)
        } else {
            unlink(path)
        }
    }
}

/// Google stores the capture date in sidecar files (`IMG_1234.JPG.supplemental-metadata.json`, older
/// exports `IMG_1234.JPG.json`, long names truncated, duplicates as `…(1).json`). Creation and
/// modification dates of photos and videos are set to `photoTakenTime`; file contents and the JSON
/// files stay unchanged.
///
/// Sidecars are matched within their folder. Once an album is sorted into month folders
/// (`MonthSorter`), the album and its month folders form one "family", so an edited version or a
/// Live Photo video that arrives with a later archive still finds its original.
enum TakeoutDates {
    /// A photo or video with everything that belongs to it and its capture date; sorting moves it as one.
    struct Unit: Sendable {
        /// Sidecar files, usually one. Paths as strings so names stay byte-exact.
        var jsons: [String]
        /// Photos and videos: the original first, then edited version and Live Photo video.
        let files: [String]
        let date: Date
        /// Folder that owns the month folders: the album or "Fotos von YYYY".
        let family: String
        /// Depth of `family` below the photos folder (`Google Fotos/<album>` = 2).
        let familyDepth: Int
    }

    struct Result: Sendable {
        var updated = 0
        var jsonFiles = 0
        var unmatched = 0
        var units: [Unit] = []

        var summary: String {
            if jsonFiles == 0 { return "Keine Takeout-Begleitdateien (.json) mit Aufnahmedatum gefunden." }
            var text = "Aufnahmedatum bei \(Fmt.count(updated)) \(updated == 1 ? "Datei" : "Dateien") gesetzt."
            if unmatched > 0 {
                text += " \(Fmt.count(unmatched)) \(unmatched == 1 ? "Begleitdatei" : "Begleitdateien") ohne passendes Foto."
            }
            return text
        }
    }

    static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "tif", "tiff", "bmp", "avif",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw",
        "mp4", "mov", "m4v", "3gp", "avi", "mkv", "mts", "m2ts", "mpg", "mpeg", "wmv", "webm",
    ]
    /// Video part of a Live Photo: same name, usually without its own sidecar.
    static let motionExtensions = ["mp4", "mov", "m4v"]
    /// Edited versions share the original's sidecar.
    static let editedSuffixes = ["-bearbeitet", "-edited"]
    private static let suffixWord = "supplemental-metadata"

    static func apply(in root: URL) -> Result {
        var result = Result()
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return result }
        // File names per folder and each folder's depth below `root`.
        var namesByFolder: [String: [String]] = [:]
        var depthOfFolder: [String: Int] = [:]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            let folder = url.deletingLastPathComponent().path
            namesByFolder[folder, default: []].append(url.lastPathComponent)
            depthOfFolder[folder] = enumerator.level - 1
        }
        var families: [String: (depth: Int, folders: [String])] = [:]
        for (folder, depth) in depthOfFolder {
            let family = familyRoot(of: folder, depth: depth)
            families[family.path, default: (family.depth, [])].folders.append(folder)
        }

        var dated: Set<String> = []
        // File path → index in `result.units`
        var owner: [String: Int] = [:]
        for (family, info) in families.sorted(by: { $0.key < $1.key }) {
            let folders = info.folders.sorted()
            let jsonFolders = folders.filter { (namesByFolder[$0] ?? []).contains { isJSON($0) } }
            guard !jsonFolders.isEmpty else { continue }
            // Media of the whole family. A name found in several folders only counts in the sidecar's own
            // folder.
            var shared: [String: (folder: String, name: String)] = [:]
            var ambiguous: Set<String> = []
            var jsonKeys: [String] = []
            for folder in folders {
                for name in namesByFolder[folder] ?? [] {
                    let nameKey = key(name)
                    if isJSON(name) {
                        jsonKeys.append(nameKey)
                    } else if shared[nameKey] != nil {
                        ambiguous.insert(nameKey)
                    } else {
                        shared[nameKey] = (folder, name)
                    }
                }
            }
            for nameKey in ambiguous { shared[nameKey] = nil }

            for folder in jsonFolders {
                let names = namesByFolder[folder] ?? []
                let media = names.filter { !isJSON($0) }
                var place = shared
                for name in media { place[key(name)] = (folder, name) }
                var lookup: [String: String] = [:]
                for (nameKey, entry) in place { lookup[nameKey] = entry.name }
                for json in names.filter(isJSON).sorted() {
                    let jsonPath = folder + "/" + json
                    guard let meta = read(URL(fileURLWithPath: jsonPath)) else { continue }
                    result.jsonFiles += 1
                    let matches = files(for: json, title: meta.title, lookup: lookup, media: media, jsonKeys: jsonKeys)
                    let paths = matches.compactMap { place[key($0)].map { $0.folder + "/" + $0.name } }
                    if paths.isEmpty {
                        result.unmatched += 1
                        continue
                    }
                    let free = paths.filter { owner[$0] == nil }
                    if free.isEmpty {
                        // A second sidecar for the same photo moves along with it.
                        if let index = owner[paths[0]] { result.units[index].jsons.append(jsonPath) }
                    } else {
                        for path in free { owner[path] = result.units.count }
                        result.units.append(Unit(jsons: [jsonPath], files: free, date: meta.date,
                                                 family: family, familyDepth: info.depth))
                    }
                    for path in paths where !dated.contains(path) {
                        if (try? FileManager.default.setAttributes([.creationDate: meta.date, .modificationDate: meta.date],
                                                                   ofItemAtPath: path)) != nil {
                            dated.insert(path)
                            result.updated += 1
                        }
                    }
                }
            }
        }
        return result
    }

    private static func isJSON(_ name: String) -> Bool { key(name).hasSuffix(".json") }

    /// The album or "Fotos von YYYY" a folder belongs to: month folders `01` … `12` (from depth 3,
    /// `Google Fotos/<album>/03`) and `YYYY/MM` (from depth 4) belong to the album, any other folder to itself.
    static func familyRoot(of folder: String, depth: Int) -> (path: String, depth: Int) {
        let name = (folder as NSString).lastPathComponent
        guard depth >= 3, MonthSorter.isMonthName(name) else { return (folder, depth) }
        let parent = (folder as NSString).deletingLastPathComponent
        if depth >= 4, MonthSorter.isYearName((parent as NSString).lastPathComponent) {
            return ((parent as NSString).deletingLastPathComponent, depth - 2)
        }
        return (parent, depth - 1)
    }

    /// Comparison key: Unicode-normalized (disk NFD, JSON NFC) and case-insensitive.
    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Only sidecars of photos and videos (with `photoTakenTime`), not those of albums.
    static func read(_ url: URL) -> (title: String, date: Date)? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taken = object["photoTakenTime"] as? [String: Any] else { return nil }
        let raw = taken["timestamp"]
        let seconds = (raw as? String).flatMap(Double.init) ?? (raw as? NSNumber)?.doubleValue ?? 0
        // Up to 2100: anything later is garbage (e.g. milliseconds) and would end up in „Fotos von 51308“.
        guard seconds > 0, seconds < 4_102_444_800 else { return nil }
        return (object["title"] as? String ?? "", Date(timeIntervalSince1970: seconds))
    }

    /// The files the sidecar `json` belongs to, found via `lookup` (name key → name).
    static func files(for json: String, title: String, lookup: [String: String], media: [String],
                      jsonKeys: [String]) -> [String] {
        var stem = String(json.dropLast(5))
        var counter = ""
        if let range = stem.range(of: #"\(\d+\)$"#, options: .regularExpression) {
            counter = String(stem[range])
            stem.removeSubrange(range)
        }
        // ".supplemental-metadata" and its truncated forms (".supplemental-me", ".su", …)
        if let dot = stem.lastIndex(of: ".") {
            let tail = stem[stem.index(after: dot)...].lowercased()
            if !tail.isEmpty, suffixWord.hasPrefix(tail), !mediaExtensions.contains(tail) {
                stem = String(stem[..<dot])
            }
        }

        func withCounter(_ name: String) -> String {
            guard !counter.isEmpty else { return name }
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            return ext.isEmpty ? base + counter : "\(base)\(counter).\(ext)"
        }

        var primary: String?
        for candidate in [title, stem] where !candidate.isEmpty {
            if let real = lookup[key(withCounter(candidate))] {
                primary = real
                break
            }
        }
        // Google truncates long names on disk; then match by the start of the title if unambiguous.
        if primary == nil, counter.isEmpty, !title.isEmpty {
            let titleBase = key((title as NSString).deletingPathExtension)
            let titleExt = key((title as NSString).pathExtension)
            let candidates = media.filter { name in
                let lower = key(name)
                let base = (lower as NSString).deletingPathExtension
                return (lower as NSString).pathExtension == titleExt && base.count >= 20
                    && base != titleBase && titleBase.hasPrefix(base)
            }
            if candidates.count == 1 { primary = candidates[0] }
        }
        guard let primary else { return [] }

        var result = [primary]
        let base = (primary as NSString).deletingPathExtension
        let ext = (primary as NSString).pathExtension
        for suffix in editedSuffixes {
            if let real = lookup[key("\(base)\(suffix).\(ext)")] { result.append(real) }
        }
        if !motionExtensions.contains(ext.lowercased()) {
            for motion in motionExtensions {
                guard let real = lookup[key("\(base).\(motion)")] else { continue }
                let own = key(real) + "."
                if !jsonKeys.contains(where: { $0.hasPrefix(own) }) { result.append(real) }
            }
        }
        return result
    }
}
