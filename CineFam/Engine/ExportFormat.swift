import Foundation

/// The seven export formats from the plan's Export section.
enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case m4v, mp4, mov, mkv, windowsMP4, wmv, avi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m4v: "M4V"
        case .mp4: "MP4"
        case .mov: "MOV"
        case .mkv: "MKV"
        case .windowsMP4: "Windows MP4"
        case .wmv: "WMV"
        case .avi: "AVI"
        }
    }

    var detail: String {
        switch self {
        case .m4v: "Apple TV, QuickTime, iPhone"
        case .mp4: "Universal, web, Android"
        case .mov: "Archive master, Final Cut"
        case .mkv: "Plex, Jellyfin, VLC"
        case .windowsMP4: "Plays on Windows out of the box"
        case .wmv: "Older Windows PCs"
        case .avi: "Legacy players"
        }
    }

    var isWindows: Bool { [.windowsMP4, .wmv, .avi].contains(self) }

    var fileExtension: String {
        switch self {
        case .m4v: "m4v"
        case .mp4, .windowsMP4: "mp4"
        case .mov: "mov"
        case .mkv: "mkv"
        case .wmv: "wmv"
        case .avi: "avi"
        }
    }

    /// Suffix added to the file name so several formats can sit in one folder.
    var nameSuffix: String {
        switch self {
        case .windowsMP4: " - Windows"
        case .mp4: " - MP4"
        default: ""
        }
    }

    var supportsSoftSubtitles: Bool { ![.wmv, .avi].contains(self) }
    var supportsChapters: Bool { ![.wmv, .avi].contains(self) }
    /// MOV and MKV don't keep an embedded cover; poster.jpg sits beside the file instead.
    var supportsCoverArt: Bool { [.m4v, .mp4, .windowsMP4].contains(self) }

    var subtitleCodec: String { self == .mkv ? "srt" : "mov_text" }

    enum Quality: String, CaseIterable, Identifiable, Codable {
        case small, balanced, best
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// Video + audio encoder arguments.
    func codecArgs(quality: Quality) -> [String] {
        let hevcQ = ["small": "50", "balanced": "62", "best": "75"][quality.rawValue]!
        let x264crf = ["small": "26", "balanced": "21", "best": "17"][quality.rawValue]!
        switch self {
        case .m4v, .mp4, .mkv:
            // Hardware HEVC on Apple silicon; hvc1 tag so Apple players accept it.
            return ["-c:v:0", "hevc_videotoolbox", "-q:v:0", hevcQ, "-profile:v:0", "main10", "-tag:v:0", "hvc1",
                    "-pix_fmt:v:0", "p010le",
                    "-c:a", "aac", "-b:a", "256k"]
        case .mov:
            return ["-c:v:0", "prores_ks", "-profile:v:0", "3", "-pix_fmt:v:0", "yuv422p10le",
                    "-c:a", "pcm_s16le"]
        case .windowsMP4:
            // H.264: HEVC needs a paid extension on many Windows PCs.
            return ["-c:v:0", "libx264", "-preset", "slow", "-crf", x264crf, "-profile:v:0", "high",
                    "-pix_fmt:v:0", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        case .wmv:
            let rate = ["small": "2500k", "balanced": "5000k", "best": "8000k"][quality.rawValue]!
            return ["-c:v:0", "wmv2", "-b:v:0", rate, "-c:a", "wmav2", "-b:a", "192k"]
        case .avi:
            return ["-c:v:0", "mpeg4", "-tag:v:0", "xvid", "-q:v:0", quality == .best ? "2" : "4",
                    "-c:a", "libmp3lame", "-b:a", "192k"]
        }
    }

    var containerArgs: [String] {
        switch self {
        case .m4v, .mp4, .windowsMP4: ["-f", "mp4", "-movflags", "+faststart"]
        case .mov: ["-f", "mov"]
        case .mkv: ["-f", "matroska"]
        case .wmv: ["-f", "asf"]
        case .avi: ["-f", "avi"]
        }
    }
}

enum ExportResolution: String, CaseIterable, Identifiable, Codable {
    case original, p720, p1080, p2160
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original"
        case .p720: "720p"
        case .p1080: "1080p"
        case .p2160: "4K"
        }
    }
    var height: Int? {
        switch self {
        case .original: nil
        case .p720: 720
        case .p1080: 1080
        case .p2160: 2160
        }
    }
}

enum FolderLayout: String, CaseIterable, Identifiable, Codable {
    case movieFolders, dateFirst
    var id: String { rawValue }
    var title: String { self == .movieFolders ? "Movie folders" : "Date first" }
}

/// Everything the Export sheet decides.
struct ExportSettings: Codable, Hashable {
    var formats: Set<ExportFormat> = [.m4v]
    var quality: ExportFormat.Quality = .balanced
    var resolution: ExportResolution = .p1080
    var embedSubtitles = true
    var sidecarSRT = true
    var includeSDH = false
    var burnInSubtitles = false
    var chapters = true
    var metadataAndArt = true
    var layout: FolderLayout = .movieFolders
    var destination: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appending(path: "Home Videos")
    var subtitleLanguage = "eng"
}

/// File and folder names (plan: "Naming and folders").
enum ExportNaming {
    static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Fourth of July – Fireworks (1996)"
    static func movieName(_ e: TapeEvent, tapeLabel: String) -> String {
        let title = safe(e.title.isEmpty ? "\(tapeLabel) – Event \(e.index)" : e.title)
        return e.year.map { "\(title) (\($0))" } ?? title
    }

    /// Folder the files go in, relative to the destination.
    static func folder(_ e: TapeEvent, tapeLabel: String, layout: FolderLayout) -> String {
        switch layout {
        case .movieFolders: return movieName(e, tapeLabel: tapeLabel)
        case .dateFirst: return e.year.map { String($0) } ?? "Undated"
        }
    }

    /// Base file name without extension.
    static func baseName(_ e: TapeEvent, tapeLabel: String, layout: FolderLayout) -> String {
        switch layout {
        case .movieFolders:
            return movieName(e, tapeLabel: tapeLabel)
        case .dateFirst:
            let title = safe(e.title.isEmpty ? "Event \(e.index)" : e.title)
            guard let d = e.date else { return "\(safe(tapeLabel)) – \(String(format: "%02d", e.index)) – \(title)" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            switch e.precision {
            case .exact: f.dateFormat = "yyyy-MM-dd HHmm"
            case .day: f.dateFormat = "yyyy-MM-dd"
            case .year: f.dateFormat = "yyyy"
            }
            return "\(f.string(from: d)) – \(title)"
        }
    }
}
