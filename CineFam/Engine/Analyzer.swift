import Foundation

/// Stages 1–3 of the pipeline: probe, make a proxy, find dead space, split into events.
/// A port of prototype/cinefam_segment.py — keep the two in step.
struct Analyzer {
    struct Settings {
        var minDead: TimeInterval = 1.0
        var minBlack: TimeInterval = 0.4
        var minEvent: TimeInterval = 3.0
        var eventGap: TimeInterval = 2.0
        var cutScore: Double = 12
        var silenceDB = -50
        var silenceMin: TimeInterval = 2.0
    }

    static let analysisFPS = 5.0
    var settings = Settings()

    // MARK: Probe

    func probe(_ url: URL) async throws -> MediaInfo {
        let out = try await FFmpeg.run("ffprobe", ["-v", "error", "-print_format", "json",
                                                   "-show_format", "-show_streams", url.path])
        struct Probe: Decodable {
            struct Stream: Decodable {
                var codec_type: String
                var codec_name: String?
                var width: Int?
                var height: Int?
                var avg_frame_rate: String?
                var field_order: String?
            }
            struct Format: Decodable { var duration: String? }
            var streams: [Stream]
            var format: Format
        }
        let p = try JSONDecoder().decode(Probe.self, from: Data(out.stdout.utf8))
        guard let v = p.streams.first(where: { $0.codec_type == "video" }) else {
            throw FFmpegError.failed(tool: "ffprobe", code: 0, log: "No video stream in this file.")
        }
        let rate: Double = {
            let parts = (v.avg_frame_rate ?? "0/1").split(separator: "/").compactMap { Double($0) }
            return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 0
        }()
        return MediaInfo(duration: Double(p.format.duration ?? "") ?? 0,
                         width: v.width ?? 0, height: v.height ?? 0, frameRate: rate,
                         fieldOrder: v.field_order ?? "unknown", videoCodec: v.codec_name ?? "",
                         hasAudio: p.streams.contains { $0.codec_type == "audio" })
    }

    // MARK: Proxy

    /// A small progressive H.264 copy used for playback in review and for analysis.
    func makeProxy(source: URL, info: MediaInfo, to dest: URL,
                   progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: dest)
        let parser = ProgressParser(duration: info.duration)
        let deint = info.isInterlaced ? "bwdif=mode=send_frame," : ""
        try await FFmpeg.run("ffmpeg", [
            "-hide_banner", "-y", "-i", source.path,
            "-vf", "\(deint)scale=-2:360", "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
            "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats", dest.path,
        ]) { line in
            if let f = parser.fraction(from: line) { progress(f) }
        }
    }

    // MARK: Analysis

    struct Frame {
        var t: Double, yavg: Double, uavg: Double, vavg: Double
        var spread: Double, sat: Double, ydif: Double, cut: Double
        var kind: DeadReason?   // nil = content
    }

    func analyzeFrames(_ url: URL) async throws -> [Frame] {
        let vf = "fps=\(Int(Self.analysisFPS)),scale=160:120,signalstats,scdet=threshold=0,metadata=mode=print:file=-"
        let out = try await FFmpeg.run("ffmpeg", ["-hide_banner", "-nostats", "-i", url.path,
                                                  "-an", "-vf", vf, "-f", "null", "-"])
        var frames: [Frame] = []
        var cur: [String: Double] = [:]
        func flush() {
            guard let t = cur["t"], let y = cur["YAVG"] else { return }
            frames.append(Frame(t: t, yavg: y, uavg: cur["UAVG"] ?? 128, vavg: cur["VAVG"] ?? 128,
                                spread: (cur["YHIGH"] ?? 0) - (cur["YLOW"] ?? 0),
                                sat: cur["SATAVG"] ?? 0, ydif: cur["YDIF"] ?? 0,
                                cut: cur["lavfi.scd.score"] ?? 0, kind: nil))
        }
        for line in out.stdout.split(separator: "\n") {
            if line.hasPrefix("frame:") {
                flush()
                cur = [:]
                if let r = line.range(of: "pts_time:") {
                    let rest = line[r.upperBound...].prefix { $0 == "." || $0.isNumber }
                    cur["t"] = Double(rest)
                }
            } else if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].replacingOccurrences(of: "lavfi.signalstats.", with: "")
                if let v = Double(line[line.index(after: eq)...]) { cur[key] = v }
            }
        }
        flush()
        return frames
    }

    func analyzeSilence(_ url: URL, duration: TimeInterval) async throws -> [ClosedRange<Double>] {
        let s = settings
        let out = try await FFmpeg.run("ffmpeg", ["-hide_banner", "-nostats", "-i", url.path, "-vn",
                                                  "-af", "silencedetect=n=\(s.silenceDB)dB:d=\(s.silenceMin)",
                                                  "-f", "null", "-"])
        var ranges: [ClosedRange<Double>] = []
        var start: Double?
        for line in out.stderr.split(separator: "\n") {
            if let v = Self.number(after: "silence_start: ", in: line) {
                start = v
            } else if let v = Self.number(after: "silence_end: ", in: line), let a = start {
                ranges.append(a...max(a, v)); start = nil
            }
        }
        if let a = start { ranges.append(a...max(a, duration)) }
        return ranges
    }

    static func number(after marker: String, in line: Substring) -> Double? {
        guard let r = line.range(of: marker) else { return nil }
        return Double(line[r.upperBound...].prefix { $0 == "." || $0.isNumber })
    }

    static func classify(_ f: Frame) -> DeadReason? {
        let flat = f.spread < 12
        if flat && f.yavg < 30 { return .black }
        if flat && f.uavg > 160 && f.vavg < 140 && f.sat > 40 { return .blueScreen }
        if f.sat < 6 && f.yavg > 70 && f.yavg < 185 && f.spread > 50 && f.ydif > 28 { return .staticNoise }
        return nil
    }

    // MARK: Segmentation

    func segment(frames input: [Frame], silence: [ClosedRange<Double>],
                 duration: TimeInterval) -> (dead: [DeadRange], events: [TapeEvent]) {
        let s = settings
        let step = 1 / Self.analysisFPS
        var frames = input
        for i in frames.indices { frames[i].kind = Self.classify(frames[i]) }

        // Runs of the same kind of junk long enough to count.
        var dead: [DeadRange] = []
        var i = 0
        while i < frames.count {
            var j = i
            while j + 1 < frames.count && frames[j + 1].kind == frames[i].kind { j += 1 }
            if let kind = frames[i].kind {
                let a = frames[i].t, b = min(frames[j].t + step, duration)
                if b - a >= (kind == .black ? s.minBlack : s.minDead) {
                    dead.append(DeadRange(start: a, end: b, reasons: [kind]))
                }
            }
            i = j + 1
        }

        // Merge touching ranges.
        var merged: [DeadRange] = []
        for r in dead {
            if var last = merged.last, r.start - last.end <= step * 1.5 {
                last.end = r.end
                last.reasons.formUnion(r.reasons)
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }

        // Live stretches between dead space.
        var live: [ClosedRange<Double>] = []
        var t = 0.0
        for r in merged {
            if r.start > t { live.append(t...r.start) }
            t = r.end
        }
        if duration > t { live.append(t...duration) }
        live = live.filter { $0.upperBound - $0.lowerBound >= s.minEvent }

        // Group into events.
        var groups: [[ClosedRange<Double>]] = []
        for r in live {
            if let last = groups.last?.last, r.lowerBound - last.upperBound < s.eventGap {
                groups[groups.count - 1].append(r)
            } else {
                groups.append([r])
            }
        }

        let cuts = frames.filter { $0.cut >= s.cutScore }.map(\.t)
        let events = groups.enumerated().map { n, g -> TapeEvent in
            var shots: [Shot] = []
            for r in g {
                let inner = cuts.filter { $0 > r.lowerBound + 0.5 && $0 < r.upperBound - 0.5 }
                let bounds = [r.lowerBound] + inner + [r.upperBound]
                shots += zip(bounds, bounds.dropFirst()).map { Shot(start: $0, end: $1) }
            }
            let start = g.first!.lowerBound, end = g.last!.upperBound
            let quietTime = silence.reduce(0.0) { acc, q in
                acc + max(0, min(end, q.upperBound) - max(start, q.lowerBound))
            }
            return TapeEvent(index: n + 1, start: start, end: end, shots: shots,
                             title: "Event \(n + 1)",
                             confidence: shots.count > 0 ? 0.6 : 0.4,
                             quiet: quietTime > 0.6 * (end - start),
                             chapters: shots.enumerated().map {
                                 Chapter(title: "Scene \($0.offset + 1)", start: $0.element.start - start)
                             })
        }
        return (merged, events)
    }

    /// Full analysis of one tape: probe → proxy → frames + silence → segments.
    func analyze(_ tape: Tape, proxyFolder: URL,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> Tape {
        var tape = tape
        let info = try await probe(tape.sourceURL)
        tape.info = info
        let proxy = proxyFolder.appending(path: "\(tape.id.uuidString).mp4")
        try await makeProxy(source: tape.sourceURL, info: info, to: proxy) { progress($0 * 0.6) }
        tape.proxyURL = proxy
        progress(0.65)
        let frames = try await analyzeFrames(proxy)
        progress(0.9)
        let silence = try await (info.hasAudio ? analyzeSilence(proxy, duration: info.duration) : [])
        let result = segment(frames: frames, silence: silence, duration: info.duration)
        tape.deadRanges = result.dead
        tape.events = result.events
        progress(1)
        return tape
    }
}
