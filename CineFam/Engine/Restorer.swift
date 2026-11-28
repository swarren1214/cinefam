import CryptoKit
import Foundation

/// Phase 4 settings: how an event is cleaned up and upscaled.
struct RestoreSettings: Codable, Hashable {
    enum Upscaler: String, Codable, CaseIterable, Identifiable {
        case ai, standard
        var id: String { rawValue }
        var title: String { self == .ai ? "AI (Real-ESRGAN)" : "Standard" }
    }
    enum AIModel: String, Codable, CaseIterable, Identifiable {
        case fast, detailed
        var id: String { rawValue }
        var title: String { self == .fast ? "Fast" : "Detailed (slower)" }
        var file: String { self == .fast ? "realesr-animevideov3" : "realesrgan-x4plus" }
        var scales: [Int] { self == .fast ? [2, 3, 4] : [4] }
    }
    enum Denoise: String, Codable, CaseIterable, Identifiable {
        case off, light, strong
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var enabled = true
    var upscaler: Upscaler = .ai
    var model: AIModel = .fast
    /// 1 = all AI, 0 = plain lanczos. Below 1 keeps faces from looking waxy.
    var strength = 0.6
    var denoise: Denoise = .light
    var smoothMotion = false      // 60p from interlaced fields
    var stabilize = false
    var autoColor = true
    var cleanEdges = true
    var cleanAudio = true

    /// Same settings + same event range → same master, so it can be reused.
    func fingerprint(event: TapeEvent, height: Int?) -> String {
        // Include whether the AI upscaler could actually run: a copy made with the plain
        // fallback must not be reused once Real-ESRGAN is installed.
        let ai = upscaler == .ai && RealESRGAN.isInstalled
        let key = "\(self)|\(event.start)|\(event.end)|\(height ?? 0)|ai:\(ai)|v2"
        return SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Finds or installs the Real-ESRGAN command-line tool (BSD-3, by Xintao Wang).
enum RealESRGAN {
    static let downloadURL = URL(string:
        "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip")!
    /// SHA-256 of that release zip, checked before anything is unpacked.
    static let sha256 = "e0ad05580abfeb25f8d8fb55aaf7bedf552c375b5b4d9bd3c8d59764d2cc333a"
    static let downloadSize = "52 MB"

    static var folder: URL { AppModel.supportFolder.appending(path: "Tools/realesrgan") }
    static var executable: URL { folder.appending(path: "realesrgan-ncnn-vulkan") }
    static var modelsFolder: URL { folder.appending(path: "models") }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
            && FileManager.default.fileExists(atPath: modelsFolder.appending(path: "realesr-animevideov3-x2.bin").path)
    }

    enum InstallError: LocalizedError {
        case checksum, unpack
        var errorDescription: String? {
            switch self {
            case .checksum: "The Real-ESRGAN download didn't match the expected file, so it wasn't installed."
            case .unpack: "The Real-ESRGAN download couldn't be unpacked."
            }
        }
    }

    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        progress(0.05)
        let (tmp, _) = try await URLSession.shared.download(from: downloadURL)
        progress(0.7)
        let digest = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { try? fm.removeItem(at: tmp); throw InstallError.checksum }

        let unpack = fm.temporaryDirectory.appending(path: "realesrgan-\(UUID().uuidString)")
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", tmp.path, unpack.path]
        try ditto.run()
        ditto.waitUntilExit()
        try? fm.removeItem(at: tmp)
        guard ditto.terminationStatus == 0 else { throw InstallError.unpack }

        // The zip may hold the files at its top level or inside one folder.
        var root = unpack
        if !fm.fileExists(atPath: unpack.appending(path: "realesrgan-ncnn-vulkan").path) {
            let inner = try fm.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil)
            root = inner.first { $0.hasDirectoryPath } ?? unpack
        }
        guard fm.fileExists(atPath: root.appending(path: "realesrgan-ncnn-vulkan").path) else { throw InstallError.unpack }

        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: root, to: folder)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try? fm.removeItem(at: unpack)
        progress(1)
    }

    /// Upscales every PNG in `input` into `output`. `progress` gets the share of `expected`
    /// frames finished so far, checked by counting output files.
    static func run(input: URL, output: URL, model: RestoreSettings.AIModel, scale: Int,
                    expected: Int, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let p = Process()
        p.executableURL = executable
        p.currentDirectoryURL = folder
        p.arguments = ["-i", input.path, "-o", output.path, "-n", model.file, "-s", String(scale),
                       "-m", modelsFolder.path, "-f", "png"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        // Real-ESRGAN prints a line per tile per frame. It must be read as it comes: left in the
        // pipe, the 64 KB buffer filled and Real-ESRGAN froze mid-write, stalling the render.
        let err = Pipe()
        p.standardError = err
        let tail = LogTail()
        err.fileHandleForReading.readabilityHandler = { tail.append($0.availableData) }

        let watcher = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let done = (try? FileManager.default.contentsOfDirectory(atPath: output.path).count) ?? 0
                progress?(min(1, Double(done) / Double(max(expected, 1))))
            }
        }
        defer { watcher.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                p.terminationHandler = { proc in
                    ChildProcesses.remove(proc)
                    err.fileHandleForReading.readabilityHandler = nil
                    tail.append(err.fileHandleForReading.readDataToEndOfFile())
                    if proc.terminationStatus == 0 { cont.resume() }
                    else if proc.terminationReason == .uncaughtSignal { cont.resume(throwing: CancellationError()) }
                    else { cont.resume(throwing: FFmpegError.failed(tool: "Real-ESRGAN", code: proc.terminationStatus, log: tail.text)) }
                }
                do { try p.run(); ChildProcesses.add(p) } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }
}

/// Keeps only the last few KB of a chatty tool's output, for error messages.
private final class LogTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > 16_384 { data = data.suffix(8_192) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Stage 7: turns one event into a restored master (HEVC 10-bit .mov at the target size).
/// A port of prototype/restore.py — same stages and filter graphs.
struct Restorer {
    var settings: RestoreSettings
    /// nil = keep the source height.
    var targetHeight: Int?
    static let chunkFrames = 240

    /// AI upscaling runs only when the output is meaningfully bigger than the source
    /// (at least 1.25× taller); otherwise the standard path gives the same result far faster.
    static func usesAI(_ s: RestoreSettings, sourceHeight: Int, targetHeight: Int) -> Bool {
        s.upscaler == .ai && RealESRGAN.isInstalled && Double(targetHeight) >= Double(sourceHeight) * 1.25
    }

    static var mastersFolder: URL {
        let url = AppModel.supportFolder.appending(path: "Restored")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func masterURL(for event: TapeEvent) -> URL {
        Self.mastersFolder.appending(path: "\(event.id.uuidString)-\(settings.fingerprint(event: event, height: targetHeight)).mov")
    }

    /// "Clean up edges" trims tape-edge noise: 1% off the left, right and top, 3% off the bottom
    /// (where VHS head-switching noise lives). Fractions of the picture.
    struct EdgeCrop: Sendable { var left, top, width, height: Double }
    static let edgeCrop = EdgeCrop(left: 0.01, top: 0.01, width: 0.98, height: 0.96)
    static let edgeCropFilter = "crop=trunc(iw*0.98/2)*2:trunc(ih*0.96/2)*2:trunc(iw*0.01):trunc(ih*0.01)"

    // MARK: Filter graphs (same strings as prototype/restore.py)

    static func prepassFilter(_ s: RestoreSettings, interlaced: Bool) -> String {
        var f: [String] = []
        if interlaced { f.append(s.smoothMotion ? "bwdif=mode=send_field" : "bwdif=mode=send_frame") }
        f.append("scale=trunc(iw*sar/2)*2:ih:flags=lanczos,setsar=1")
        if s.cleanEdges { f.append(Self.edgeCropFilter) }
        switch s.denoise {
        case .light: f.append("hqdn3d=2:3:3:4.5")
        case .strong: f.append("hqdn3d=4:6:6:9")
        case .off: break
        }
        if s.stabilize { f.append("deshake=edge=mirror") }
        if s.autoColor { f.append("normalize=blackpt=black:whitept=white:smoothing=48:independence=0.5:strength=0.6") }
        return f.joined(separator: ",")
    }

    static let audioCleanup = "highpass=f=70,afftdn=nf=-25,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000"  // loudnorm outputs 192 kHz
    /// Ends every master's audio chain: a fixed 48 kHz stereo format the FLAC encoder always
    /// accepts. Without it, sources whose AAC changes its channel-layout description mid-file
    /// failed with "Cannot select channel layout" when FFmpeg rebuilt the filters.
    static let masterAudioFormat = "aresample=48000,aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=stereo"

    static func blendFilter(width w: Int, height h: Int, strength: Double) -> String {
        let k = String(format: "%.2f", strength)
        return "[0:v]scale=\(w):\(h):flags=lanczos[ai];[1:v]scale=\(w):\(h):flags=lanczos[plain];"
            + "[ai][plain]blend=all_expr='A*\(k)+B*(1-\(k))',format=yuv420p10le[v]"
    }

    static func standardFilter(width w: Int, height h: Int) -> String {
        "scale=\(w):\(h):flags=lanczos,cas=0.4,format=yuv420p10le"
    }

    static let masterCodec = ["-c:v", "hevc_videotoolbox", "-q:v", "80", "-profile:v", "main10", "-tag:v", "hvc1"]

    // MARK: Pipeline

    /// Renders (or reuses) the master. `range` restores only part of the event (for previews).
    func restore(_ event: TapeEvent, in tape: Tape, range: ClosedRange<TimeInterval>? = nil, output: URL? = nil,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let out = output ?? masterURL(for: event)
        if fm.fileExists(atPath: out.path) { progress(1); return out }

        let start = range?.lowerBound ?? event.start, end = range?.upperBound ?? event.end
        let work = AppModel.supportFolder.appending(path: "Work/\(out.deletingPathExtension().lastPathComponent)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let interlaced = tape.info?.isInterlaced ?? true

        // 1. Prepass — one continuous run so temporal filters never restart.
        let prepass = work.appending(path: "prepass.mkv")
        if !fm.fileExists(atPath: prepass.path) {
            let part = work.appending(path: "prepass.part.mkv")
            var a = ["-hide_banner", "-y", "-nostats", "-progress", "pipe:1",
                     "-ss", String(format: "%.3f", start), "-to", String(format: "%.3f", end),
                     // Keep the filters built once: rebuilding them mid-file on a stream
                     // description change is what broke audio on some camera MP4s.
                     "-reinit_filter", "0",
                     "-i", tape.sourceURL.path, "-map", "0:v:0",
                     "-vf", Self.prepassFilter(settings, interlaced: interlaced),
                     "-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuv420p"]
            if tape.info?.hasAudio ?? false {
                let af = settings.cleanAudio ? Self.audioCleanup + "," + Self.masterAudioFormat : Self.masterAudioFormat
                a += ["-map", "0:a:0", "-af", af, "-c:a", "flac"]
            }
            let parser = ProgressParser(duration: end - start)
            try await FFmpeg.run("ffmpeg", a + [part.path]) { line in
                if let f = parser.fraction(from: line) { progress(f * 0.1) }
            }
            try fm.moveItem(at: part, to: prepass)
        }
        let p = try await Self.probeFrames(prepass)
        let h = targetHeight ?? p.height
        let w = max(2, Int((Double(h) * Double(p.width) / Double(p.height) / 2).rounded()) * 2)

        // 2. Upscale in chunks (reused when present, so stopped renders resume).
        // AI only when it actually enlarges the picture: footage already at (or near) the
        // output size went through Real-ESRGAN at 2× and was shrunk back — e.g. 1080p frames
        // rendered at 4K — for no gain and a lot of heat.
        var chunks: [URL] = []
        if Self.usesAI(settings, sourceHeight: p.height, targetHeight: h) {
            let scale = settings.model.scales.first { p.height * $0 >= h } ?? settings.model.scales.last!
            let inDir = work.appending(path: "in"), outDir = work.appending(path: "out")
            var first = 0, index = 0
            while first < p.frames {
                try Task.checkCancellation()
                let n = min(Self.chunkFrames, p.frames - first)
                let chunk = work.appending(path: String(format: "chunk_%05d.mov", index))
                chunks.append(chunk)
                if !fm.fileExists(atPath: chunk.path) {
                    for d in [inDir, outDir] {
                        try? fm.removeItem(at: d)
                        try fm.createDirectory(at: d, withIntermediateDirectories: true)
                    }
                    try await FFmpeg.run("ffmpeg", ["-hide_banner", "-y", "-loglevel", "error",
                                                    "-ss", String(format: "%.6f", Double(first) / p.fps),
                                                    "-i", prepass.path, "-frames:v", String(n),
                                                    "-start_number", "1", inDir.appending(path: "%08d.png").path])
                    let done = first, total = max(p.frames, 1)
                    try await RealESRGAN.run(input: inDir, output: outDir, model: settings.model, scale: scale,
                                             expected: n) { f in
                        progress(0.1 + 0.85 * (Double(done) + Double(n) * f * 0.95) / Double(total))
                    }
                    let part = work.appending(path: String(format: "chunk_%05d.part.mov", index))
                    try await FFmpeg.run("ffmpeg", ["-hide_banner", "-y", "-loglevel", "error",
                                                    "-framerate", p.rate, "-i", outDir.appending(path: "%08d.png").path,
                                                    "-framerate", p.rate, "-i", inDir.appending(path: "%08d.png").path,
                                                    "-filter_complex", Self.blendFilter(width: w, height: h, strength: settings.strength),
                                                    "-map", "[v]"] + Self.masterCodec + [part.path])
                    try fm.moveItem(at: part, to: chunk)
                }
                first += n
                index += 1
                progress(0.1 + 0.85 * Double(first) / Double(max(p.frames, 1)))
            }
            try? fm.removeItem(at: inDir)
            try? fm.removeItem(at: outDir)
        } else {
            let chunk = work.appending(path: "chunk_00000.mov")
            chunks.append(chunk)
            if !fm.fileExists(atPath: chunk.path) {
                let part = work.appending(path: "chunk_00000.part.mov")
                let parser = ProgressParser(duration: end - start)
                try await FFmpeg.run("ffmpeg", ["-hide_banner", "-y", "-nostats", "-progress", "pipe:1",
                                                "-i", prepass.path, "-map", "0:v:0",
                                                "-vf", Self.standardFilter(width: w, height: h)]
                                     + Self.masterCodec + [part.path]) { line in
                    if let f = parser.fraction(from: line) { progress(0.1 + 0.85 * f) }
                }
                try fm.moveItem(at: part, to: chunk)
            }
        }

        // 3. Join the chunks and add the cleaned audio.
        let listing = work.appending(path: "chunks.txt")
        try chunks.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n").write(to: listing, atomically: true, encoding: .utf8)
        var a = ["-hide_banner", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listing.path,
                 "-i", prepass.path, "-map", "0:v:0", "-c:v", "copy"]
        if tape.info?.hasAudio ?? false { a += ["-map", "1:a:0", "-c:a", "aac", "-b:a", "256k"] }
        let part = out.deletingLastPathComponent().appending(path: "\(UUID().uuidString).part.mov")
        try await FFmpeg.run("ffmpeg", a + ["-movflags", "+faststart", part.path])
        try? fm.removeItem(at: out)
        try fm.moveItem(at: part, to: out)
        try? fm.removeItem(at: work)
        progress(1)
        return out
    }

    /// A 10-second side-by-side (original | restored) starting at `time`, for checking settings.
    func preview(_ event: TapeEvent, in tape: Tape, at time: TimeInterval,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let start = max(event.start, min(time, event.end - 10))
        let end = min(event.end, start + 10)
        let folder = AppModel.supportFolder.appending(path: "Previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = "\(event.id.uuidString)-\(Int(start * 10))-\(settings.fingerprint(event: event, height: targetHeight))"
        let master = folder.appending(path: "\(stamp)-restored.mov")
        let sideBySide = folder.appending(path: "\(stamp)-compare-v2.mp4")
        if FileManager.default.fileExists(atPath: sideBySide.path) { progress(1); return sideBySide }

        _ = try await restore(event, in: tape, range: start...end, output: master) { progress($0 * 0.9) }
        let mp = try await Self.probeFrames(master)
        let deint = tape.info?.isInterlaced ?? true ? "bwdif=mode=send_frame," : ""
        let trim = settings.cleanEdges ? Self.edgeCropFilter + "," : ""
        try await FFmpeg.run("ffmpeg", [
            "-hide_banner", "-y", "-loglevel", "error",
            "-ss", String(format: "%.3f", start), "-to", String(format: "%.3f", end), "-i", tape.sourceURL.path,
            "-i", master.path,
            "-filter_complex",
            "[0:v]\(deint)scale=trunc(iw*sar/2)*2:ih,setsar=1,\(trim)scale=\(mp.width):\(mp.height):flags=neighbor,fps=\(mp.rate)[a];"
                + "[1:v]setsar=1[b];[a][b]hstack=inputs=2,scale=-2:min(ih\\,1080)[v]",
            "-map", "[v]", "-map", "1:a?", "-c:v", "h264_videotoolbox", "-b:v", "40M",
            "-c:a", "aac", "-shortest", sideBySide.path])
        try? FileManager.default.removeItem(at: master)
        progress(1)
        return sideBySide
    }

    struct FrameInfo {
        var width: Int, height: Int, frames: Int, fps: Double, rate: String
    }

    static func probeFrames(_ url: URL) async throws -> FrameInfo {
        let out = try await FFmpeg.run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-count_packets",
                                                   "-show_entries", "stream=width,height,r_frame_rate,nb_read_packets",
                                                   "-of", "json", url.path])
        struct R: Decodable {
            struct S: Decodable { var width: Int; var height: Int; var r_frame_rate: String; var nb_read_packets: String? }
            var streams: [S]
        }
        guard let s = try JSONDecoder().decode(R.self, from: Data(out.stdout.utf8)).streams.first else {
            throw FFmpegError.failed(tool: "ffprobe", code: 0, log: "No video in restored file.")
        }
        let parts = s.r_frame_rate.split(separator: "/").compactMap { Double($0) }
        let fps = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 29.97
        return FrameInfo(width: s.width, height: s.height, frames: Int(s.nb_read_packets ?? "") ?? 0,
                         fps: fps, rate: s.r_frame_rate)
    }

    /// Total size of restored masters and leftovers, for Settings.
    static func diskUsage() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for folder in [mastersFolder, AppModel.supportFolder.appending(path: "Work"), AppModel.supportFolder.appending(path: "Previews")] {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in e {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    static func deleteAll() {
        for folder in [mastersFolder, AppModel.supportFolder.appending(path: "Work"), AppModel.supportFolder.appending(path: "Previews")] {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
