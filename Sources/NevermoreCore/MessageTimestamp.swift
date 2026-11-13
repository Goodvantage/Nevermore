import Foundation

/// Frappe's Gregorian site-local datetime, with absent or 1...6 fractional
/// digits. The wire value has no UTC offset, so a repeated DST hour cannot
/// identify which occurrence the server intended; Calendar chooses one.
public struct ServerTimestampParser: Sendable {
    private let calendar: Calendar

    public init(siteTimeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = siteTimeZone
        self.calendar = calendar
    }

    public func date(from raw: String) -> Date? {
        let bytes = Array(raw.utf8.prefix(27))
        guard (19...26).contains(bytes.count), bytes[4] == 45, bytes[7] == 45,
              bytes[10] == 32, bytes[13] == 58, bytes[16] == 58 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                guard (48...57).contains(bytes[index]) else { return nil }
                result = result * 10 + Int(bytes[index] - 48)
            }
            return result
        }
        guard let year = number(0..<4), year > 0,
              let month = number(5..<7), (1...12).contains(month),
              let day = number(8..<10), (1...31).contains(day),
              let hour = number(11..<13), hour < 24,
              let minute = number(14..<16), minute < 60,
              let second = number(17..<19), second < 60 else { return nil }
        var fraction = 0.0
        if bytes.count > 19 {
            guard bytes.count >= 21, bytes[19] == 46, let digits = number(20..<bytes.count) else { return nil }
            let divisors = [1.0, 10, 100, 1000, 10_000, 100_000, 1_000_000]
            fraction = Double(digits) / divisors[bytes.count - 20]
        }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // Calendar normalizes invalid dates and nonexistent DST wall times.
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second else { return nil }
        return date.addingTimeInterval(fraction)
    }
}

/// One display formatter per account, reused for transcript and accessibility
/// timestamps. Mutable Foundation formatter state stays on the main actor.
@MainActor public final class MessageTimestampFormatter {
    private let parser: ServerTimestampParser
    private let display = DateFormatter()
    private let timeOnly = DateFormatter()
    private let compactTimeOnly = DateFormatter()
    private let relativeDay = DateFormatter()
    private let weekday = DateFormatter()
    private let dayInYear = DateFormatter()
    private let dayWithYear = DateFormatter()
    /// The reader's calendar in the display time zone; day dividers and
    /// grouping use it so "Today" matches the reader's clock.
    public private(set) var calendar = Calendar.current

    public init(siteTimeZone: TimeZone, locale: Locale = .current, displayTimeZone: TimeZone = .current) {
        parser = ServerTimestampParser(siteTimeZone: siteTimeZone)
        updateDisplay(locale: locale, timeZone: displayTimeZone)
    }

    public func updateDisplay(locale: Locale, timeZone: TimeZone) {
        var calendar = locale.calendar; calendar.locale = locale; calendar.timeZone = timeZone
        self.calendar = calendar
        for formatter in [display, timeOnly, compactTimeOnly, relativeDay, weekday, dayInYear, dayWithYear] {
            formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = timeZone
        }
        display.dateStyle = .short; display.timeStyle = .short
        timeOnly.dateStyle = .none; timeOnly.timeStyle = .short
        // "J": the locale's hour cycle without an AM/PM marker.
        compactTimeOnly.setLocalizedDateFormatFromTemplate("Jmm")
        // Day labels stand alone, so locales that lower-case weekday or
        // relative names mid-sentence capitalize them here.
        relativeDay.dateStyle = .medium; relativeDay.timeStyle = .none; relativeDay.doesRelativeDateFormatting = true
        weekday.setLocalizedDateFormatFromTemplate("EEEE")
        dayInYear.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        dayWithYear.setLocalizedDateFormatFromTemplate("EEEEdMMMMy")
        for formatter in [relativeDay, weekday, dayInYear, dayWithYear] { formatter.formattingContext = .standalone }
    }

    public func date(from raw: String) -> Date? { parser.date(from: raw) }

    /// Date and time, for tooltips, copies and accessibility labels.
    public func string(from raw: String) -> String {
        if let date = parser.date(from: raw) { return display.string(from: date) }
        return fallback(raw)
    }

    /// Time of day alone, for headers below a day divider.
    public func time(from raw: String) -> String {
        if let date = parser.date(from: raw) { return timeOnly.string(from: date) }
        return fallback(raw)
    }

    /// "11:34" even where headers say "11:34 AM": for the narrow column
    /// beside messages that continue a header's group.
    public func compactTime(from raw: String) -> String {
        if let date = parser.date(from: raw) { return compactTimeOnly.string(from: date) }
        return fallback(raw)
    }

    /// "Today", "Yesterday", "Thursday", "Thursday, 5 November" or, in
    /// another year, "Thursday, 5 November 2025", in the reader's locale.
    /// Always relative to the real clock, as Foundation's relative names
    /// are; `TranscriptDay.classify` takes an explicit time for tests.
    public func dayLabel(for date: Date) -> String {
        switch TranscriptDay.classify(date, now: Date(), calendar: calendar) {
        case .today, .yesterday: return relativeDay.string(from: date)
        case .recent: return weekday.string(from: date)
        case .thisYear: return dayInYear.string(from: date)
        case .otherYear: return dayWithYear.string(from: date)
        }
    }

    // A scalar bound also limits pathological combining-character input.
    private func fallback(_ raw: String) -> String { String(String.UnicodeScalarView(raw.unicodeScalars.prefix(16))) }
}
