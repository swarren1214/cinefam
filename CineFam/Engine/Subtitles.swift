import Foundation

/// One subtitle on screen.
struct SubtitleCue: Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var lines: [String]
}

/// Turns word timings into broadcast-style cues and writes SRT.
///
/// Rules (implementation plan, stage 9): at most 2 lines, about 42 characters a line,
/// 1–6 seconds on screen, never spanning a shot cut, break early on long pauses.
struct SubtitleBuilder {
    var maxLineLength = 42
    var maxLines = 2
    var minDuration: TimeInterval = 1.0
    var maxDuration: TimeInterval = 6.0
    var pauseBreak: TimeInterval = 0.8

    func cues(from words: [TimedWord], cuts: [TimeInterval] = []) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: [TimedWord] = []

        func close() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(SubtitleCue(start: first.start, end: last.end, lines: wrap(current.map(\.text))))
            current = []
        }

        for word in words {
            if let last = current.last, let first = current.first {
                let pause = word.start - last.end > pauseBreak
                let tooLong = word.end - first.start > maxDuration
                let crossesCut = cuts.contains { $0 > last.end && $0 <= word.start }
                let wouldOverflow = wrap(current.map(\.text) + [word.text]).count > maxLines
                let sentenceEnd = last.text.last.map { ".?!".contains($0) } ?? false
                if pause || tooLong || crossesCut || wouldOverflow
                    || (sentenceEnd && last.end - first.start >= minDuration) {
                    close()
                }
            }
            current.append(word)
        }
        close()

        // Hold short cues a little longer, without running into the next one.
        for i in cues.indices where cues[i].end - cues[i].start < minDuration {
            let limit = i + 1 < cues.count ? cues[i + 1].start - 0.05 : .infinity
            cues[i].end = max(cues[i].end, min(cues[i].start + minDuration, limit))
        }
        return cues
    }

    /// Greedy wrap into lines of at most `maxLineLength`, balanced for two lines.
    func wrap(_ words: [String]) -> [String] {
        let text = words.joined(separator: " ")
        if text.count <= maxLineLength { return [text] }
        // Two lines: break at the space nearest the middle that keeps both short enough.
        let spaces = text.indices.filter { text[$0] == " " }
        let mid = text.count / 2
        let best = spaces.min { abs(text.distance(from: text.startIndex, to: $0) - mid)
                               < abs(text.distance(from: text.startIndex, to: $1) - mid) }
        if let b = best {
            let a = String(text[..<b]), c = String(text[text.index(after: b)...])
            if a.count <= maxLineLength && c.count <= maxLineLength { return [a, c] }
        }
        // Longer than two lines: plain greedy wrap (caller splits the cue).
        var lines: [String] = [], line = ""
        for w in words {
            if line.isEmpty { line = w }
            else if line.count + 1 + w.count <= maxLineLength { line += " " + w }
            else { lines.append(line); line = w }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    static func srt(_ cues: [SubtitleCue], offset: TimeInterval = 0) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(timestamp(c.start - offset)) --> \(timestamp(c.end - offset))\n\(c.lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    /// 00:01:02,345
    static func timestamp(_ t: TimeInterval) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

/// FFmpeg metadata file with one chapter per scene.
enum ChapterFile {
    static func ffmetadata(_ chapters: [Chapter], duration: TimeInterval) -> String {
        var s = ";FFMETADATA1\n"
        for (i, c) in chapters.enumerated() {
            let end = i + 1 < chapters.count ? chapters[i + 1].start : duration
            s += "\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(c.start * 1000))\nEND=\(Int(end * 1000))\ntitle=\(escape(c.title))\n"
        }
        return s
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "=;#\\\n".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
