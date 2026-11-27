import Foundation

/// Phase 3: dates, transcripts, titles and summaries for every event on a tape.
///
/// Pass 1, per event: keyframes → Vision (date stamp, scene tags, faces) → transcript.
/// Then dates spread to undated neighbours and the tape label.
/// Pass 2, per event: title, summary and keywords.
struct EventEnricher {
    struct Options {
        var transcribe = true
        var name = true
    }

    var options = Options()
    var sampler = KeyframeSampler()

    func enrich(_ tape: Tape, only eventID: UUID? = nil,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Tape {
        var tape = tape
        let indices = tape.events.indices.filter { eventID == nil || tape.events[$0].id == eventID }
        let folder = FileManager.default.temporaryDirectory.appending(path: "cinefam-frames-\(tape.id.uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var insights: [UUID: FrameInsights] = [:]
        let steps = Double(max(indices.count, 1) * 2)
        var done = 0.0

        // Pass 1: see and listen.
        for i in indices {
            try Task.checkCancellation()
            var e = tape.events[i]
            let frames = (try? await sampler.extract(e, from: tape, into: folder)) ?? []
            let seen = FrameAnalyzer.analyze(frames)
            insights[e.id] = seen
            e.visualTags = seen.topTags
            e.faceCount = seen.maxFaces

            // A date the user typed is never overwritten.
            if e.dateSource != .manual, let vote = DateStampParser.vote(seen.stampReadings),
               vote.confidence >= 0.25, let date = vote.stamp.date {
                e.date = date
                e.datePrecision = vote.stamp.precision
                e.dateSource = .dateStamp
                e.confidence = max(e.confidence, min(0.95, 0.5 + vote.confidence / 2))
            }

            if options.transcribe && e.words.isEmpty && !e.quiet {
                if let words = try? await EventTranscriber().transcribe(e, in: tape) { e.words = words }
            }
            tape.events[i] = e
            done += 1
            progress(done / steps)
        }

        if eventID == nil { Self.fillDates(&tape) }

        // Pass 2: name.
        if options.name {
            let namer = EventNamer()
            for i in indices {
                try Task.checkCancellation()
                var e = tape.events[i]
                let seen = insights[e.id] ?? FrameInsights()
                let d = await namer.describe(.init(
                    tags: seen.topTags, faces: seen.maxFaces, transcript: e.transcript,
                    dateText: e.dateText, tapeLabel: tape.label, length: e.duration,
                    onScreenText: seen.recognizedText))
                if !d.title.isEmpty { e.title = d.title }
                e.summary = d.summary
                e.keywords = d.keywords
                e.aiNamed = EventNamer.isModelAvailable
                tape.events[i] = e
                done += 1
                progress(done / steps)
            }
        }
        progress(1)
        return tape
    }

    /// Undated events borrow a date: the same day when the events on both sides share
    /// one, else the year of the nearest dated event, else a year on the tape label.
    static func fillDates(_ tape: inout Tape) {
        let cal = Calendar.current
        let known = tape.events.indices.filter { tape.events[$0].date != nil && tape.events[$0].dateSource != .nearbyEvent }
        for i in tape.events.indices where tape.events[i].date == nil {
            let prev = known.last { $0 < i }.map { tape.events[$0] }
            let next = known.first { $0 > i }.map { tape.events[$0] }
            if let p = prev?.date, let n = next?.date, cal.isDate(p, inSameDayAs: n) {
                tape.events[i].date = p
                tape.events[i].datePrecision = .day
                tape.events[i].dateSource = .nearbyEvent
            } else if let nearest = prev?.date ?? next?.date {
                tape.events[i].date = nearest
                tape.events[i].datePrecision = .year
                tape.events[i].dateSource = .nearbyEvent
            } else if let year = labelYear(tape.label),
                      let d = cal.date(from: DateComponents(year: year, month: 1, day: 1)) {
                tape.events[i].date = d
                tape.events[i].datePrecision = .year
                tape.events[i].dateSource = .tapeLabel
            }
        }
    }

    /// "Summer 1996" → 1996, "Christmas '94" → 1994.
    static func labelYear(_ label: String) -> Int? {
        let thisYear = Calendar.current.component(.year, from: .now)
        let ns = label as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = try? NSRegularExpression(pattern: #"\b(19[7-9]\d|20[0-3]\d)\b"#).firstMatch(in: label, range: range),
           let y = Int(ns.substring(with: m.range(at: 1))), y <= thisYear {
            return y
        }
        if let m = try? NSRegularExpression(pattern: #"['’](\d{2})\b"#).firstMatch(in: label, range: range),
           let yy = Int(ns.substring(with: m.range(at: 1))) {
            let y = yy >= 70 ? 1900 + yy : 2000 + yy
            return y <= thisYear ? y : nil
        }
        return nil
    }
}
