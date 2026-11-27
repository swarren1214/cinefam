import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A frame that could front an event's poster.
struct HeroCandidate: Identifiable, Codable, Hashable {
    var id: TimeInterval { time }
    var time: TimeInterval          // seconds into the tape
    var imageURL: URL               // full-size still (1080 tall)
    var score: Double
    /// Where the subject is, 0–1 from the top-left, used to crop the poster around it.
    var focusX: Double = 0.5
    var focusY: Double = 0.45
    var faces = 0
}

/// Picks the best stills of an event: sharp, well exposed, faces looking at the camera.
/// Pixel measures and weights match prototype/hero_frames.py; Vision adds face quality,
/// aesthetics and the subject's position.
struct HeroFramePicker {
    var samples = 40
    var count = 6
    var minGap: TimeInterval = 2

    static let weights = (sharpness: 0.40, exposure: 0.25, contrast: 0.20, color: 0.15)

    static func folder(for event: TapeEvent) -> URL {
        AppModel.supportFolder.appending(path: "Posters/\(event.id.uuidString)")
    }

    func candidates(for event: TapeEvent, in tape: Tape, restoredMaster: URL?,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [HeroCandidate] {
        let frames = Self.folder(for: event).appending(path: "frames")
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        // Skip moments right next to a cut: they're often mid-transition.
        let cuts = event.shots.map(\.start).filter { $0 > event.start + 0.5 }
        let step = event.duration / Double(samples + 1)
        let times = (1...samples).map { event.start + step * Double($0) }
            .filter { t in cuts.allSatisfy { abs($0 - t) > 0.4 } }

        var measured: [(time: TimeInterval, url: URL, m: Measures, v: VisionMeasures)] = []
        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            let url = frames.appending(path: String(format: "frame_%03d.jpg", i))
            var args = ["-hide_banner", "-y", "-loglevel", "error"]
            if let master = restoredMaster {
                args += ["-ss", String(format: "%.3f", t - event.start), "-i", master.path,
                         "-frames:v", "1", "-vf", "setsar=1"]
            } else {
                let deint = tape.info?.isInterlaced ?? true ? "bwdif=mode=send_frame," : ""
                args += ["-ss", String(format: "%.3f", t), "-i", tape.sourceURL.path, "-frames:v", "1",
                         "-vf", "\(deint)scale=trunc(iw*sar/2)*2:ih,setsar=1,hqdn3d=2:3:3:4.5,scale=-2:1080:flags=lanczos"]
            }
            guard (try? await FFmpeg.run("ffmpeg", args + ["-q:v", "2", url.path])) != nil,
                  let image = Self.loadImage(url) else { continue }
            measured.append((t, url, Self.measure(image), Self.vision(image)))
            progress(Double(i + 1) / Double(times.count))
        }
        guard !measured.isEmpty else { return [] }

        // Scale each pixel measure against the best frame in this event.
        func best(_ k: KeyPath<Measures, Double>) -> Double { max(measured.map { $0.m[keyPath: k] }.max() ?? 1, 1e-6) }
        let bs = best(\.sharpness), be = best(\.exposure), bc = best(\.contrast), bk = best(\.color)
        let w = Self.weights
        let ranked = measured.map { f -> HeroCandidate in
            let pixel = w.sharpness * f.m.sharpness / bs + w.exposure * f.m.exposure / be
                + w.contrast * f.m.contrast / bc + w.color * f.m.color / bk
            var vision = (f.v.aesthetics + 1) / 2
            if let q = f.v.faceQuality { vision = 0.5 * vision + 0.5 * q }
            var score = 0.6 * pixel + 0.4 * vision
            if f.v.isUtility { score -= 0.3 }
            return HeroCandidate(time: f.time, imageURL: f.url, score: score,
                                 focusX: f.v.focus.x, focusY: f.v.focus.y, faces: f.v.faces)
        }.sorted { $0.score > $1.score }

        var chosen: [HeroCandidate] = []
        for c in ranked where chosen.allSatisfy({ abs($0.time - c.time) >= minGap }) {
            chosen.append(c)
            if chosen.count == count { break }
        }
        // Keep the chosen stills, delete the rest.
        let keep = Set(chosen.map(\.imageURL))
        for f in measured where !keep.contains(f.url) { try? FileManager.default.removeItem(at: f.url) }
        return chosen
    }

    /// A still at any moment (for "Choose from Video…").
    func frame(at time: TimeInterval, for event: TapeEvent, in tape: Tape, restoredMaster: URL?) async throws -> HeroCandidate {
        let folder = Self.folder(for: event).appending(path: "frames")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "manual_\(Int(time * 1000)).jpg")
        var args = ["-hide_banner", "-y", "-loglevel", "error"]
        if let master = restoredMaster {
            args += ["-ss", String(format: "%.3f", time - event.start), "-i", master.path, "-frames:v", "1"]
        } else {
            args += ["-ss", String(format: "%.3f", time), "-i", tape.sourceURL.path, "-frames:v", "1",
                     "-vf", "bwdif=mode=send_frame,scale=trunc(iw*sar/2)*2:ih,setsar=1,scale=-2:1080:flags=lanczos"]
        }
        try await FFmpeg.run("ffmpeg", args + ["-q:v", "2", url.path])
        guard let image = Self.loadImage(url) else { throw FFmpegError.failed(tool: "ffmpeg", code: 0, log: "No frame at that time.") }
        let v = Self.vision(image)
        return HeroCandidate(time: time, imageURL: url, score: 1, focusX: v.focus.x, focusY: v.focus.y, faces: v.faces)
    }

    // MARK: Measures

    struct Measures { var sharpness = 0.0, exposure = 0.0, contrast = 0.0, color = 0.0 }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Same formulas as prototype/hero_frames.py `measure()`, on a 256-wide copy.
    static func measure(_ image: CGImage) -> Measures {
        let w = 256, h = max(1, Int((Double(image.height) * 256 / Double(image.width)).rounded()))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return Measures() }

        var y = [Double](repeating: 0, count: w * h)
        var rg = [Double](repeating: 0, count: w * h), yb = [Double](repeating: 0, count: w * h)
        var clipped = 0
        for i in 0..<(w * h) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            y[i] = l
            rg[i] = r - g
            yb[i] = 0.5 * (r + g) - b
            if l < 0.03 || l > 0.97 { clipped += 1 }
        }
        func meanStd(_ a: [Double]) -> (Double, Double) {
            let m = a.reduce(0, +) / Double(a.count)
            let v = a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)
            return (m, v.squareRoot())
        }
        var lap: [Double] = []
        lap.reserveCapacity((w - 2) * (h - 2))
        if w > 2 && h > 2 {
            for row in 1..<(h - 1) {
                for col in 1..<(w - 1) {
                    let i = row * w + col
                    lap.append(-4 * y[i] + y[i - w] + y[i + w] + y[i - 1] + y[i + 1])
                }
            }
        }
        let (lm, ls) = lap.isEmpty ? (0.0, 0.0) : meanStd(lap)
        _ = lm
        let (ym, ys) = meanStd(y)
        let (rgm, rgs) = meanStd(rg), (ybm, ybs) = meanStd(yb)
        let clip = Double(clipped) / Double(w * h)
        return Measures(sharpness: ls * ls,
                        exposure: max(0, 1 - abs(ym - 0.45) * 2.2 - clip * 1.5),
                        contrast: ys,
                        color: (rgs * rgs + ybs * ybs).squareRoot() + 0.3 * (rgm * rgm + ybm * ybm).squareRoot())
    }

    struct VisionMeasures {
        var aesthetics = 0.0          // -1…1
        var isUtility = false
        var faceQuality: Double?      // 0…1, best face
        var faces = 0
        var focus = (x: 0.5, y: 0.45)
    }

    static func vision(_ image: CGImage) -> VisionMeasures {
        var v = VisionMeasures()
        let faces = VNDetectFaceCaptureQualityRequest()
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try? handler.perform([faces, aesthetics, saliency])

        if let a = aesthetics.results?.first {
            v.aesthetics = Double(a.overallScore)
            v.isUtility = a.isUtility
        }
        let found = faces.results ?? []
        v.faces = found.count
        v.faceQuality = found.compactMap { $0.faceCaptureQuality }.max().map(Double.init)
        // Focus on the biggest face, else the salient area. Vision's origin is bottom-left.
        if let face = found.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
            v.focus = (Double(face.boundingBox.midX), Double(1 - face.boundingBox.midY))
        } else if let objects = saliency.results?.first?.salientObjects, !objects.isEmpty {
            let box = objects.map(\.boundingBox).reduce(objects[0].boundingBox) { $0.union($1) }
            v.focus = (Double(box.midX), Double(1 - box.midY))
        }
        return v
    }
}
