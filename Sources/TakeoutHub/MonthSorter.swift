import Foundation

/// Sorts extracted photos and videos into month folders `01` … `12` by capture date, each album and each
/// "Fotos von YYYY" on its own, like "In Monatsordner sortieren" in PhotoHub with subfolders:
/// `Google Fotos/Fotos von 2019/03`, `Google Fotos/Urlaub/07`.
/// - Date: `photoTakenTime` from the sidecar (`TakeoutDates.Unit`), month in the Mac's local time. Files
///   without a sidecar stay put: Takeout sets their file date to the export, not the capture.
/// - What belongs together moves together: original, edited version, Live Photo video and sidecar.
///   Album metadata (`metadata.json`) stays in the album.
/// - Albums spanning several years get a year level (`Urlaub/2019/12`, `Urlaub/2020/01`), also when a later
///   run brings a year the existing month folders don't have (those stay as they are). "Fotos von YYYY" never
///   gets one: photos from another year (New Year's Eve, time zones) go to the matching sibling folder,
///   e.g. `Fotos von 2020/01`.
/// - Nothing is overwritten: if a name is taken in the month folder, the photo and its parts stay put.
/// - Sorted files never move again; parts arriving with a later archive join their original.
/// - Moves use `rename` within the same tree, so dates survive and names stay byte-exact.
enum MonthSorter {
    struct Result: Sendable {
        /// Photos and videos moved, sidecars not counted.
        var moved = 0
        /// Month folders that received files.
        var folders = 0
        /// Photos and videos left in place because no sidecar matched.
        var undated = 0
        /// Photos and videos left in place because their name was taken in the month folder.
        var conflicts = 0
        var failures: [String] = []

        var summary: String {
            func files(_ count: Int) -> String { "\(Fmt.count(count)) \(count == 1 ? "Datei" : "Dateien")" }
            var parts: [String] = []
            if moved > 0 {
                parts.append("\(files(moved)) in \(Fmt.count(folders)) Monatsordner einsortiert.")
            } else {
                parts.append("Nichts neu in Monatsordner einzusortieren.")
            }
            if undated > 0 {
                parts.append("\(files(undated)) ohne Aufnahmedatum \(undated == 1 ? "blieb" : "blieben") liegen.")
            }
            if conflicts > 0 {
                parts.append("\(files(conflicts)) \(conflicts == 1 ? "blieb" : "blieben") liegen, weil im Monatsordner "
                             + "schon eine Datei gleichen Namens liegt.")
            }
            if !failures.isEmpty {
                parts.append("\(files(failures.count)) \(failures.count == 1 ? "ließ" : "ließen") sich nicht verschieben "
                             + "(siehe Protokoll).")
            }
            return parts.joined(separator: " ")
        }
    }

    /// Sorts the `units` from `TakeoutDates.apply(in: root)`. Only albums directly inside a product folder
    /// (`<root>/Google Fotos/<album>`) get month folders; nothing else is touched.
    static func apply(_ units: [TakeoutDates.Unit], in root: URL) -> Result {
        var result = Result()
        let calendar = Calendar.current
        let fileManager = FileManager.default
        let albums = units.filter { $0.familyDepth == 2 }
        // Targets claimed by this run, case-insensitive like APFS.
        var claimed = Set<String>()
        var filled = Set<String>()

        // Media directly in an album without a sidecar stays there.
        let known = Set(albums.flatMap(\.files))
        for product in Set(albums.map { ($0.family as NSString).deletingLastPathComponent }) {
            for album in subfolderNames(of: product) {
                result.undated += fileNames(in: product + "/" + album).filter { name in
                    TakeoutDates.mediaExtensions.contains((name as NSString).pathExtension.lowercased())
                        && !known.contains(product + "/" + album + "/" + name)
                }.count
            }
        }

        /// Moves everything of `unit` that is not in `target` yet, all or nothing.
        func move(_ unit: TakeoutDates.Unit, to target: String) {
            let pending = (unit.files + unit.jsons).filter { ($0 as NSString).deletingLastPathComponent != target }
            guard !pending.isEmpty else { return }
            let media = Set(unit.files)
            let targets = pending.map { target + "/" + ($0 as NSString).lastPathComponent }
            let targetKeys = targets.map(TakeoutDates.key)
            if Set(targetKeys).count < targets.count
                || zip(targets, targetKeys).contains(where: { claimed.contains($1) || exists($0) }) {
                result.conflicts += pending.filter(media.contains).count
                return
            }
            do {
                try fileManager.createDirectory(atPath: target, withIntermediateDirectories: true)
            } catch {
                result.failures.append("\(name(unit)): Monatsordner \(relative(target, root)) lässt sich nicht anlegen")
                return
            }
            for (index, (source, destination)) in zip(pending, targets).enumerated() {
                claimed.insert(targetKeys[index])
                guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
                    result.failures.append("\((source as NSString).lastPathComponent): \(String(cString: strerror(errno)))")
                    // If the original can't move, the rest stays with it.
                    if index == 0 && source == unit.files.first { return }
                    continue
                }
                if media.contains(source) { result.moved += 1 }
                filled.insert(target)
            }
        }

        for (album, members) in Dictionary(grouping: albums, by: \.family).sorted(by: { $0.key < $1.key }) {
            let sorted = members.sorted { $0.files[0] < $1.files[0] }
            // A unit is sorted once its original lies in one of the album's month folders.
            let open = sorted.filter { folder(of: $0) == album }
            let placed = sorted.filter { folder(of: $0) != album }
            let googleYear = googleYear(of: (album as NSString).lastPathComponent)

            var usesYears = false
            if googleYear == nil, !open.isEmpty {
                // Like PhotoHub: a year level only when needed, never two years in one month folder.
                let years = Set(open.map { calendar.component(.year, from: $0.date) })
                let existingYears = Set(placed.filter { (folder(of: $0) as NSString).deletingLastPathComponent == album }
                    .map { calendar.component(.year, from: $0.date) })
                let subfolders = subfolderNames(of: album)
                let hasMonthFolders = subfolders.contains(where: isMonthName)
                let hasYearFolders = subfolders.contains { isYearName($0) && subfolderNames(of: album + "/" + $0).contains(where: isMonthName) }
                usesYears = years.count > 1 || !existingYears.isSubset(of: years) || (!hasMonthFolders && hasYearFolders)
            }

            for unit in open {
                let parts = calendar.dateComponents([.year, .month], from: unit.date)
                guard let year = parts.year, let month = parts.month else { continue }
                var base = album
                var folderName = String(format: "%02d", month)
                if let googleYear {
                    if year != googleYear.year {
                        base = (album as NSString).deletingLastPathComponent + "/" + googleYear.prefix + " " + String(year)
                    }
                } else if usesYears {
                    folderName = String(format: "%04d/%02d", year, month)
                }
                move(unit, to: base + "/" + folderName)
            }
            // Late parts (edited version, Live Photo video, sidecar) join their original.
            for unit in placed {
                move(unit, to: folder(of: unit))
            }
        }
        result.folders = filled.count
        return result
    }

    // MARK: - Helpers

    static func isMonthName(_ name: String) -> Bool {
        name.count == 2 && name.allSatisfy(\.isASCII) && Int(name).map { (1...12).contains($0) } == true
    }

    static func isYearName(_ name: String) -> Bool {
        name.count == 4 && name.allSatisfy(\.isASCII) && Int(name).map { (1900...2999).contains($0) } == true
    }

    /// Google's year folders: "Fotos von 2019" or "Photos from 2019" → ("Fotos von", 2019).
    static func googleYear(of name: String) -> (prefix: String, year: Int)? {
        for prefix in ["Fotos von", "Photos from"] where name.hasPrefix(prefix + " ") {
            let rest = String(name.dropFirst(prefix.count + 1))
            if isYearName(rest), let year = Int(rest) { return (prefix, year) }
        }
        return nil
    }

    private static func folder(of unit: TakeoutDates.Unit) -> String {
        (unit.files[0] as NSString).deletingLastPathComponent
    }

    private static func name(_ unit: TakeoutDates.Unit) -> String {
        (unit.files[0] as NSString).lastPathComponent
    }

    private static func relative(_ path: String, _ root: URL) -> String {
        path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
    }

    /// Broken symlinks count as taken, too.
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Visible subfolders without packages; empty if the folder doesn't exist.
    private static func subfolderNames(of path: String) -> [String] {
        entries(in: path) { $0.isDirectory == true && $0.isPackage != true }
    }

    private static func fileNames(in path: String) -> [String] {
        entries(in: path) { $0.isRegularFile == true }
    }

    private static func entries(in path: String, where include: (URLResourceValues) -> Bool) -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path, isDirectory: true),
                                                                 includingPropertiesForKeys: Array(keys),
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), include(values) else { return nil }
            return url.lastPathComponent
        }
    }
}
