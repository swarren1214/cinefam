import Foundation

/// A digitized tape the user imported. The original file is never modified.
struct Tape: Identifiable, Codable, Hashable {
    var id = UUID()
    var sourceURL: URL
    var label: String
    var importedAt = Date()
    var info: MediaInfo?
    var proxyURL: URL?
    var status: TapeStatus = .queued
    var deadRanges: [DeadRange] = []
    var events: [TapeEvent] = []

    var keptDuration: TimeInterval {
        events.filter { $0.status != .discarded }.reduce(0) { $0 + $1.duration }
    }
    var deadDuration: TimeInterval { deadRanges.reduce(0) { $0 + $1.duration } }
}

enum TapeStatus: Codable, Hashable {
    case queued
    case analyzing(progress: Double)
    case needsReview
    case rendering(progress: Double)
    case done
    case failed(message: String)

    var label: String {
        switch self {
        case .queued: "Queued"
        case .analyzing(let p): "Analyzing · \(Int(p * 100))%"
        case .needsReview: "Needs review"
        case .rendering(let p): "Rendering · \(Int(p * 100))%"
        case .done: "Done"
        case .failed(let m): "Failed: \(m)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .analyzing, .rendering: true
        default: false
        }
    }
}

/// What ffprobe reports about a source file.
struct MediaInfo: Codable, Hashable {
    var duration: TimeInterval
    var width: Int
    var height: Int
    var frameRate: Double
    var fieldOrder: String
    var videoCodec: String
    var hasAudio: Bool

    var isInterlaced: Bool { !["progressive", "unknown", ""].contains(fieldOrder) }
}

enum DeadReason: String, Codable, Hashable, CaseIterable {
    case blueScreen = "blue_screen"
    case black
    case staticNoise = "static"
    case silence

    var title: String {
        switch self {
        case .blueScreen: "Blue screen"
        case .black: "Black"
        case .staticNoise: "Snow / static"
        case .silence: "Silence"
        }
    }
}

struct DeadRange: Identifiable, Codable, Hashable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var reasons: Set<DeadReason>
    /// The user can bring a range back as content in review.
    var restored = false

    var duration: TimeInterval { end - start }
}

struct Shot: Codable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
}

enum DateSource: String, Codable, Hashable, CaseIterable {
    case dvMetadata, dateStamp, transcript, nearbyEvent, tapeLabel, manual, unknown

    var title: String {
        switch self {
        case .dvMetadata: "DV metadata"
        case .dateStamp: "Date stamp (OCR)"
        case .transcript: "Transcript"
        case .nearbyEvent: "Nearby event on tape"
        case .tapeLabel: "Tape label"
        case .manual: "Entered by you"
        case .unknown: "Unknown"
        }
    }
}

/// How much of a date we actually know.
enum DatePrecision: String, Codable, Hashable, CaseIterable {
    case exact, day, year

    var title: String {
        switch self {
        case .exact: "Date and time"
        case .day: "Day"
        case .year: "Year only"
        }
    }
}

enum EventStatus: String, Codable, Hashable {
    case proposed, approved, discarded, rendered
}

/// One event on a tape: becomes one movie file.
struct TapeEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var index: Int
    var start: TimeInterval
    var end: TimeInterval
    var shots: [Shot] = []
    var title: String
    var date: Date?
    var dateSource: DateSource = .unknown
    var summary = ""
    var keywords: [String] = []
    var people: [String] = []
    var confidence: Double = 0.5
    var status: EventStatus = .proposed
    var quiet = false

    // Output options
    var subtitlesEnabled = true
    var chaptersEnabled = true
    var posterEnabled = false

    /// Filled by transcription (Phase 3).
    var words: [TimedWord] = []
    var chapters: [Chapter] = []

    // Phase 3 additions. Optional so libraries saved before them still load.
    var datePrecision: DatePrecision?
    var visualTags: [String]?
    var faceCount: Int?
    var aiNamed: Bool?

    // Phase 5.
    var poster: PosterSpec?
    var posterImageURL: URL? {
        guard let url = poster?.posterURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var duration: TimeInterval { end - start }
    var year: Int? { date.map { Calendar.current.component(.year, from: $0) } }
    var precision: DatePrecision { datePrecision ?? .exact }
    var transcript: String { words.map(\.text).joined(separator: " ") }

    /// "Jul 4, 1996 at 9:41 PM", "Jul 4, 1996" or "1996", as much as we know.
    var dateText: String? {
        guard let date else { return nil }
        switch precision {
        case .exact: return date.formatted(date: .abbreviated, time: .shortened)
        case .day: return date.formatted(date: .abbreviated, time: .omitted)
        case .year: return date.formatted(.dateTime.year())
        }
    }
}

struct TimedWord: Codable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Double = 1
}

struct Chapter: Codable, Hashable {
    var title: String
    var start: TimeInterval
}

extension TimeInterval {
    /// 1:58:12 or 4:05
    var clock: String {
        let s = Int(self.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "8 min", "1 h 12 min"
    var friendlyLength: String {
        let m = Int((self / 60).rounded())
        if m < 1 { return "\(Int(self)) s" }
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}
