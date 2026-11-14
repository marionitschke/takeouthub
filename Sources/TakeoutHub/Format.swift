import Foundation

/// Sizes, times and rates for the UI (German, local time).
enum Fmt {
    private static let german = Locale(identifier: "de_DE")

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let weekdayDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = german
        formatter.dateFormat = "EE, dd.MM.yyyy"
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = german
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        "\(size(Int64(bytesPerSecond.rounded())))/s"
    }

    /// "45 s", "12 Min.", "3 Std. 5 Min.", "2 Tage 4 Std."
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 1)) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) Min." }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours) Std." : "\(hours) Std. \(minutes % 60) Min." }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days) Tage" : "\(days) Tage \(hours % 24) Std."
    }

    /// "heute 8:00", "gestern 16:20" or "Mo, 03.11.2026 8:00".
    static func moment(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = clock.string(from: date)
        if calendar.isDateInToday(date) { return "heute \(time)" }
        if calendar.isDateInYesterday(date) { return "gestern \(time)" }
        return "\(weekdayDate.string(from: date)) \(time)"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(german))
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down))) %"
    }

    /// Path with "~" for the home folder.
    static func path(_ url: URL) -> String {
        let home = AppPaths.testHome?.path ?? NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
