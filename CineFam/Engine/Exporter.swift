import Foundation

/// Stage 9: writes each approved event as a finished movie file (plus sidecars).
struct Exporter {
    var settings: ExportSettings

    struct Job {
        var event: TapeEvent
        var tape: Tape
        var posterURL: URL?
        /// Restored master from `Restorer` (already deinterlaced, cleaned and sized).
        var restoredURL: URL?
    }

    /// Exports one event in every chosen format. Returns the files written.
    func export(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let e = job.event
        let fm = FileManager.default
        let folder = settings.destination.appending(
            path: ExportNaming.folder(e, tapeLabel: job.tape.label, layout: settings.layout))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = ExportNaming.baseName(e, tapeLabel: job.tape.label, layout: settings.layout)
        var written: [URL] = []

        // Subtitles (shared by every format).
        let cues = e.subtitlesEnabled
            ? SubtitleBuilder().cues(from: e.words, cuts: e.shots.map(\.start))
            : []
        // ffmpeg reads a temporary copy with a plain path (safe inside filter arguments);
        // the sidecar beside the movie is the copy people keep.
        var srtURL: URL?
        if !cues.isEmpty {
            let text = SubtitleBuilder.srt(cues, offset: e.start)
            let temp = fm.temporaryDirectory.appending(path: "\(e.id.uuidString).srt")
            try text.write(to: temp, atomically: true, encoding: .utf8)
            srtURL = temp
            if settings.sidecarSRT {
                let lang = settings.subtitleLanguage == "eng" ? "en" : settings.subtitleLanguage
                let sidecar = folder.appending(path: "\(base).\(lang).srt")
                try text.write(to: sidecar, atomically: true, encoding: .utf8)
                written.append(sidecar)
            }
        }

        // Chapters.
        var chaptersURL: URL?
        if settings.chapters && e.chaptersEnabled && e.chapters.count > 1 {
            let url = fm.temporaryDirectory.appending(path: "\(e.id.uuidString).ffmeta")
            try ChapterFile.ffmetadata(e.chapters, duration: e.duration)
                .write(to: url, atomically: true, encoding: .utf8)
            chaptersURL = url
        }

        let formats = ExportFormat.allCases.filter { settings.formats.contains($0) }
        for (n, format) in formats.enumerated() {
            let out = folder.appending(path: "\(base)\(format.nameSuffix).\(format.fileExtension)")
            let args = arguments(job: job, format: format, output: out,
                                 srt: srtURL, chapters: chaptersURL)
            let parser = ProgressParser(duration: e.duration)
            try await FFmpeg.run("ffmpeg", args) { line in
                if let f = parser.fraction(from: line) {
                    progress((Double(n) + f) / Double(formats.count))
                }
            }
            written.append(out)
        }

        if let srtURL { try? fm.removeItem(at: srtURL) }
        if let chaptersURL { try? fm.removeItem(at: chaptersURL) }

        // Poster files for Plex / Infuse.
        if settings.metadataAndArt, let poster = job.posterURL, settings.layout == .movieFolders {
            let dest = folder.appending(path: "poster.jpg")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: poster, to: dest)
            written.append(dest)
        }

        // Sidecar JSON with everything we know about the event.
        let sidecar = folder.appending(path: "\(base).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Sidecar(event: e, tape: job.tape.label, source: job.tape.sourceURL.path))
            .write(to: sidecar)
        written.append(sidecar)
        progress(1)
        return written
    }

    struct Sidecar: Encodable {
        var event: TapeEvent
        var tape: String
        var source: String
    }

    /// The full ffmpeg argument list for one event in one format. Pure, so it can be tested.
    func arguments(job: Job, format: ExportFormat, output: URL,
                   srt: URL?, chapters: URL?) -> [String] {
        let e = job.event
        let info = job.tape.info
        let softSubs = srt != nil && settings.embedSubtitles && format.supportsSoftSubtitles
            && !settings.burnInSubtitles
        let burnIn = srt != nil && (settings.burnInSubtitles
            || (settings.embedSubtitles && !format.supportsSoftSubtitles && !settings.sidecarSRT))
        let useChapters = chapters != nil && format.supportsChapters
        let cover = settings.metadataAndArt && format.supportsCoverArt ? job.posterURL : nil

        var a = ["-hide_banner", "-y", "-nostats", "-progress", "pipe:1"]
        if let master = job.restoredURL {
            a += ["-i", master.path]
        } else {
            a += ["-ss", String(format: "%.3f", e.start), "-to", String(format: "%.3f", e.end),
                  "-i", job.tape.sourceURL.path]
        }
        var next = 1
        var subIndex: Int?, chapIndex: Int?, coverIndex: Int?
        if softSubs, let srt { a += ["-i", srt.path]; subIndex = next; next += 1 }
        if useChapters, let chapters { a += ["-i", chapters.path]; chapIndex = next; next += 1 }
        if let cover { a += ["-i", cover.path]; coverIndex = next; next += 1 }

        a += ["-map", "0:v:0", "-map", "0:a?"]
        if let subIndex { a += ["-map", "\(subIndex):0"] }
        if let coverIndex { a += ["-map", "\(coverIndex):0"] }
        a += ["-map_chapters", chapIndex.map { String($0) } ?? "-1", "-map_metadata:g", "-1"]

        // A restored master is already clean and sized; otherwise do a quick cleanup here.
        var filters: [String] = []
        if job.restoredURL == nil {
            if info?.isInterlaced ?? true { filters.append("bwdif=mode=send_frame") }
            filters.append("scale=trunc(iw*sar/2)*2:ih,setsar=1,hqdn3d=2:3:3:4.5")
            if let h = settings.resolution.height { filters.append("scale=-2:\(h):flags=lanczos") }
        }
        if burnIn, let srt { filters.append("subtitles=filename='\(Self.filterEscape(srt.path))'") }
        filters.append("setsar=1")
        a += ["-filter:v:0", filters.joined(separator: ",")]

        a += format.codecArgs(quality: settings.quality)
        a += ["-ar", "48000"]   // every format here supports 48 kHz; some (WMA) reject more
        if subIndex != nil {
            a += ["-c:s", format.subtitleCodec, "-metadata:s:s:0", "language=\(settings.subtitleLanguage)",
                  "-metadata:s:s:0", "title=English"]
        }
        if coverIndex != nil {
            a += ["-c:v:1", "mjpeg", "-disposition:v:1", "attached_pic"]
        }

        // Movie info.
        if settings.metadataAndArt {
            a += ["-metadata", "title=\(e.title)", "-metadata", "genre=Home Movie"]
            if !e.summary.isEmpty {
                a += ["-metadata", "description=\(e.summary)", "-metadata", "comment=\(e.summary)"]
            }
            if let year = e.year { a += ["-metadata", "date=\(year)"] }
            if let d = e.date, e.precision != .year {
                a += ["-metadata", "creation_time=\(ISO8601DateFormatter().string(from: d))"]
            }
            if !e.people.isEmpty { a += ["-metadata", "artist=\(e.people.joined(separator: ", "))"] }
            if !e.keywords.isEmpty { a += ["-metadata", "keywords=\(e.keywords.joined(separator: ", "))"] }
        }
        a += format.containerArgs
        a.append(output.path)
        return a
    }

    /// Escaping for a path inside an ffmpeg filter argument.
    static func filterEscape(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ":", with: "\\:")
    }
}
