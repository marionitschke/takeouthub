// Test harness for Tests/run.sh: runs the real AppModel against Tests/testserver.py.
// Only runs with TAKEOUTHUB_HOME (own state, own log, non-persistent browser).
//
//   DownloadTest <port> full|login|quit|resume|extract|extract-sort [sha256]
//   DownloadTest <port> mismatch       → the file changes size on the server: stops, keeps the partial file
//   DownloadTest <port> extract-fail   → extraction must fail and leave the archive unextracted
//   DownloadTest <port> extract-quit   → quits in the middle of extracting
//   DownloadTest 0 sort    → apply capture dates and sort into month folders (no download)
//   DownloadTest 0 load    → load the saved state of an older version
//   DownloadTest 0 broken  → an unreadable state.json is set aside, not overwritten
//   DownloadTest 0 sizes   → a state.json with nonsense sizes loads without overflowing
import AppKit
import CryptoKit
import Foundation

@MainActor
func wait(timeout: Double, until condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
}

func sha256(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "-" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@MainActor
func run() -> Int32 {
    let arguments = CommandLine.arguments
    guard AppPaths.isTest, arguments.count >= 3 else {
        print("Nur mit TAKEOUTHUB_HOME und <port> <szenario> aufrufen")
        return 2
    }
    let port = arguments[1]
    let scenario = arguments[2]
    let expected = arguments.count > 3 ? arguments[3] : ""

    if scenario == "login" {
        AppModel.cookieProvider = { [] }
    } else {
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "SID", .value: "geheim"])!
        AppModel.cookieProvider = { [cookie] }
    }
    let model = AppModel.shared

    switch scenario {
    case "load":
        let settings = model.settings
        print("Geladen: \(model.items.count) Eintrag/Einträge, Papierkorb \(settings.trashAfterExtract), "
              + "Monatsordner \(settings.sortIntoMonths), Fotos \(settings.photosFolder)")
        return model.items.count == 1 && model.items.first?.extractedAt != nil && settings.trashAfterExtract
            && !settings.sortIntoMonths && settings.photosFolder.hasSuffix("/Eigene Fotos") ? 0 : 1
    case "broken":
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.support.path))?
            .filter { $0.hasPrefix("state-defekt-") } ?? []
        print("Geladen: \(model.items.count) Einträge, beiseitegelegt: \(kept)")
        return model.items.isEmpty && kept.count == 1 ? 0 : 1
    case "sizes":
        // The sums the views show must not overflow on nonsense sizes.
        print("Geladen: \(model.items.count) Einträge, \(model.receivedBytes) von \(model.totalBytes) Bytes, "
              + "offen \(model.remainingBytes)")
        return model.items.count == 2 && model.totalBytes >= 0 && model.totalBytes < 1 << 52 ? 0 : 1
    case "sort":
        model.settings.sortIntoMonths = true
        model.applyDates()
        let done = wait(timeout: 60) { model.extraction == nil }
        print("Einsortiert: \(done), \(model.lastDates ?? "-")")
        return done ? 0 : 1
    default:
        break
    }

    if scenario != "resume" {
        model.adopt(source: URL(string: "http://127.0.0.1:\(port)/takeout/download?i=1"), final: nil,
                    suggestedName: "takeout-001.zip", expected: nil)
    }

    func finished() -> Bool {
        guard let item = model.items.first else { return true }
        return [.done, .failed, .needsLogin].contains(item.state)
    }

    if scenario == "quit" {
        let reached = wait(timeout: 60) { (model.items.first?.receivedBytes ?? 0) > 3 << 20 }
        model.prepareForQuit()
        _ = wait(timeout: 1) { false }
        let item = model.items.first
        print("quit: \(reached ? "nach" : "OHNE") 3 MB unterbrochen, Stand \(item?.receivedBytes ?? -1), Zustand \(item?.state.rawValue ?? "-")")
        return reached && item?.state == .queued ? 0 : 1
    }

    let ok = wait(timeout: 180, until: finished)
    guard let item = model.items.first else {
        print("Kein Eintrag")
        return 1
    }
    let hash = item.state == .done ? sha256(item.fileURL) : "-"
    print("Zustand: \(item.state.rawValue), \(item.receivedBytes) von \(item.totalBytes ?? -1) Bytes, "
          + "Link-Anforderungen: \(item.linkRequests), Meldung: \(item.message ?? "-")")
    if !ok { print("ZEITÜBERSCHREITUNG") }

    switch scenario {
    case "login":
        return item.state == .needsLogin ? 0 : 1
    case "mismatch":
        let part = Store.fileSize(item.partURL) ?? -1
        print("Teildatei: \(part) Bytes")
        return item.state == .failed && part > 0 && part == item.receivedBytes ? 0 : 1
    case "extract-fail":
        guard item.state == .done else { return 1 }
        model.extractAll()
        let ended = wait(timeout: 60) { model.extraction == nil }
        print("Entpacken beendet: \(ended), Hinweis: \(model.notice?.message ?? "-")")
        return ended && model.items.first?.extractedAt == nil && model.notice?.title == "Entpacken abgebrochen" ? 0 : 1
    case "extract-quit":
        guard item.state == .done else { return 1 }
        model.extractAll()
        let started = wait(timeout: 30) { (model.extraction?.done ?? 0) >= 500 }
        model.prepareForQuit()
        let ended = wait(timeout: 30) { model.extraction == nil }
        print("Beim Entpacken beendet: \(started ? "nach" : "OHNE") 500 Dateien, abgebrochen: \(ended)")
        return started && ended && model.items.first?.extractedAt == nil ? 0 : 1
    case "extract", "extract-sort":
        guard item.state == .done else { return 1 }
        if scenario == "extract-sort" { model.settings.sortIntoMonths = true }
        model.extractAll()
        let extracted = wait(timeout: 60) { model.extraction == nil && model.items.first?.extractedAt != nil }
        print("Entpackt: \(extracted), \(model.lastDates ?? "-")")
        return extracted ? 0 : 1
    default:
        let match = hash == expected
        print("Prüfsumme: \(match ? "stimmt" : "FALSCH (\(hash))")")
        return item.state == .done && match ? 0 : 1
    }
}

let status = MainActor.assumeIsolated { run() }
for line in LogFile.tail(limit: 40) { print("  | \(line)") }
exit(status)
