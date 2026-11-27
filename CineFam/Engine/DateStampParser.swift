import Foundation

/// A camcorder date stamp read from a frame.
struct DateStamp: Hashable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int?
    var minute: Int?

    var dayKey: [Int] { [year, month, day] }

    var date: Date? {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day,
                                                   hour: hour ?? 12, minute: minute ?? 0))
    }
    var precision: DatePrecision { hour == nil ? .day : .exact }
}

/// Reads camcorder date stamps out of OCR text ("JUL 4 1996  PM 9:41", "12.25.94").
/// A port of prototype/datestamp.py — same patterns, same rules, same test cases
/// (prototype/test_datestamp.py).
enum DateStampParser {
    private static let months = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6, "JUL": 7,
                                 "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]
    private static let mon = #"(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEPT|SEP|OCT|NOV|DEC)[A-Z]*\.?"#
    private static let sep = #"[\s.,/\-]*"#
    private static let sep1 = #"[\s.,/\-]+"#

    private enum Kind { case mdyName, dmyName, ymdName, ymdNum, mdyNum }

    private static let datePatterns: [(Kind, NSRegularExpression)] = [
        (.mdyName, rx(#"\b\#(mon)\#(sep)(\d{1,2})\#(sep1)(\d{4}|\d{2})\b"#)),   // DEC 25 1994
        (.dmyName, rx(#"\b(\d{1,2})\#(sep)\#(mon)\#(sep)(\d{4}|\d{2})\b"#)),    // 25 DEC 1994
        (.ymdName, rx(#"\b(\d{4})\#(sep1)\#(mon)\#(sep)(\d{1,2})\b"#)),         // 1994 DEC 25
        (.ymdNum, rx(#"\b(\d{4})[.\-/ ](\d{1,2})[.\-/ ](\d{1,2})\b"#)),         // 1994.12.25
        (.mdyNum, rx(#"\b(\d{1,2})[.\-/ ](\d{1,2})[.\-/ ](\d{4}|\d{2})\b"#)),   // 12.25.94
    ]
    private static let timePatterns: [NSRegularExpression] = [
        rx(#"\b(AM|PM)\s*(\d{1,2})[:.](\d{2})(?:[:.]\d{2})?\b"#),               // PM 9:41
        rx(#"\b(\d{1,2})[:.](\d{2})(?:[:.]\d{2})?\s*(AM|PM)\b"#),               // 9:41 PM
        rx(#"\b([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?\b"#),                    // 21:41
    ]
    private static let oneFix = rx(#"(?<=\d)[lI|]|(?<![A-Za-z])[lI|](?=\d)"#)
    private static let zeroFix = rx(#"(?<=\d)O|(?<![A-Z])O(?=\d)"#)

    /// Clocks that were never set show these.
    private static let unsetClocks: Set<[Int]> = [[1980, 1, 1], [1990, 1, 1], [2000, 1, 1], [2001, 1, 1]]
    static let earliestYear = 1975

    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    // MARK: Parsing

    /// Upper-cases and fixes common OCR slips next to digits (O→0, I/l/|→1).
    static func normalize(_ text: String) -> String {
        var t = replace(oneFix, in: text, with: "1").uppercased()
        while true {
            let fixed = replace(zeroFix, in: t, with: "0")
            if fixed == t { break }
            t = fixed
        }
        return t.replacingOccurrences(of: "\u{2019}", with: "'")
    }

    static func parse(_ text: String,
                      thisYear: Int = Calendar.current.component(.year, from: .now)) -> DateStamp? {
        let t = normalize(text)
        guard let found = parseDate(t, thisYear: thisYear) else { return nil }
        let (day, span) = found
        // Don't read the date's own digits as a time ("12.25" in "12.25.94").
        let ns = t as NSString
        let rest = ns.substring(to: span.location) + " " + ns.substring(from: span.location + span.length)
        let time = parseTime(rest)
        return DateStamp(year: day[0], month: day[1], day: day[2], hour: time?.0, minute: time?.1)
    }

    /// The most common day across frames, with the earliest time seen on that day.
    static func vote(_ readings: [DateStamp?], frames: Int? = nil) -> (stamp: DateStamp, confidence: Double)? {
        let found = readings.compactMap { $0 }
        guard !found.isEmpty else { return nil }
        var counts: [[Int]: Int] = [:]
        for r in found { counts[r.dayKey, default: 0] += 1 }
        // Ties go to the day seen first.
        guard let best = found.map(\.dayKey).max(by: { counts[$0]! < counts[$1]! }) else { return nil }
        let times = found.filter { $0.dayKey == best }
            .compactMap { r in r.hour.map { ($0, r.minute ?? 0) } }
            .sorted { $0 < $1 }
        let total = max(frames ?? readings.count, 1)
        let stamp = DateStamp(year: best[0], month: best[1], day: best[2],
                              hour: times.first?.0, minute: times.first?.1)
        return (stamp, (Double(counts[best]!) / Double(total) * 100).rounded() / 100)
    }

    // MARK: Helpers

    private static func parseDate(_ t: String, thisYear: Int) -> ([Int], NSRange)? {
        let ns = t as NSString
        for (kind, regex) in datePatterns {
            for m in regex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let g = (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
                var y = 0, mo = 0, d = 0
                switch kind {
                case .mdyName: y = fullYear(Int(g[2])!); mo = months[String(g[0].prefix(3))]!; d = Int(g[1])!
                case .dmyName: y = fullYear(Int(g[2])!); mo = months[String(g[1].prefix(3))]!; d = Int(g[0])!
                case .ymdName: y = Int(g[0])!; mo = months[String(g[1].prefix(3))]!; d = Int(g[2])!
                case .ymdNum: y = Int(g[0])!; mo = Int(g[1])!; d = Int(g[2])!
                case .mdyNum:
                    // US camcorders put the month first; a "month" over 12 means a day-first stamp.
                    y = fullYear(Int(g[2])!); mo = Int(g[0])!; d = Int(g[1])!
                    if mo > 12 && d <= 12 { swap(&mo, &d) }
                }
                if isValid(y, mo, d, thisYear: thisYear) { return ([y, mo, d], m.range) }
            }
        }
        return nil
    }

    private static func parseTime(_ t: String) -> (Int, Int)? {
        let ns = t as NSString
        for (i, regex) in timePatterns.enumerated() {
            guard let m = regex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { continue }
            let g = (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
            var h: Int, mi: Int, ampm: String
            switch i {
            case 0: ampm = g[0]; h = Int(g[1])!; mi = Int(g[2])!
            case 1: h = Int(g[0])!; mi = Int(g[1])!; ampm = g[2]
            default: return (Int(g[0])!, Int(g[1])!)
            }
            guard (1...12).contains(h), mi < 60 else { continue }
            h = h % 12 + (ampm == "PM" ? 12 : 0)
            return (h, mi)
        }
        return nil
    }

    private static func fullYear(_ y: Int) -> Int {
        y >= 100 ? y : (y >= 70 ? 1900 + y : 2000 + y)
    }

    private static func isValid(_ y: Int, _ m: Int, _ d: Int, thisYear: Int) -> Bool {
        guard (earliestYear...thisYear).contains(y), (1...12).contains(m),
              !unsetClocks.contains([y, m, d]) else { return false }
        let comps = DateComponents(calendar: Calendar(identifier: .gregorian), year: y, month: m, day: d)
        return comps.isValidDate
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                       withTemplate: template)
    }
}
