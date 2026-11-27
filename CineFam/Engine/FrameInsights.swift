import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Pulls still frames out of an event with FFmpeg (works for any source format).
struct KeyframeSampler {
    var maxFrames = 8

    /// Shot midpoints first, topped up with evenly spaced frames.
    func times(for event: TapeEvent) -> [TimeInterval] {
        var times = event.shots.map { ($0.start + $0.end) / 2 }
        let even = (1...maxFrames).map { event.start + event.duration * Double($0) / Double(maxFrames + 1) }
        for t in even where times.count < maxFrames && !times.contains(where: { abs($0 - t) < 2 }) {
            times.append(t)
        }
        return Array(times.sorted().prefix(maxFrames))
    }

    /// Writes JPEGs at 2x size (small date stamps read better) and returns their URLs.
    func extract(_ event: TapeEvent, from tape: Tape, into folder: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let deint = tape.info?.isInterlaced ?? true ? "yadif," : ""
        var urls: [URL] = []
        for (i, t) in times(for: event).enumerated() {
            let url = folder.appending(path: "\(event.id.uuidString)-\(i).jpg")
            do {
                try await FFmpeg.run("ffmpeg", ["-hide_banner", "-y", "-loglevel", "error",
                                                "-ss", String(format: "%.2f", t), "-i", tape.sourceURL.path,
                                                "-frames:v", "1", "-vf", "\(deint)scale=iw*2:ih*2:flags=lanczos",
                                                "-q:v", "3", url.path])
                urls.append(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue   // one bad frame shouldn't stop the rest
            }
        }
        return urls
    }
}

/// What Vision sees in a set of frames: date stamps, scene labels and faces.
struct FrameInsights {
    var stampReadings: [DateStamp?] = []
    var recognizedText: [String] = []
    var tags: [String: Float] = [:]
    var maxFaces = 0

    var topTags: [String] {
        tags.sorted { $0.value > $1.value }.prefix(8).map(\.key)
    }
}

enum FrameAnalyzer {
    /// Labels too generic to help name a home video.
    private static let ignoredTags: Set<String> = [
        "structure", "material", "textile", "wood processed", "adult", "people", "indoor",
        "outdoor", "consumer electronics", "screenshot", "document", "machine", "conveyance",
    ]

    static func analyze(_ frames: [URL]) -> FrameInsights {
        var insights = FrameInsights()
        for url in frames {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }

            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            text.minimumTextHeight = 0.02
            let classify = VNClassifyImageRequest()
            let faces = VNDetectFaceRectanglesRequest()

            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do { try handler.perform([text, classify, faces]) } catch { continue }

            // Date stamp: try all the text together (date and time are often on
            // separate lines), then each line alone.
            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            insights.recognizedText += lines
            var stamp = DateStampParser.parse(lines.joined(separator: "\n"))
            if stamp == nil {
                stamp = lines.lazy.compactMap { DateStampParser.parse($0) }.first
            }
            insights.stampReadings.append(stamp)

            for obs in (classify.results ?? []).prefix(12) where obs.confidence > 0.35 {
                let tag = obs.identifier.replacingOccurrences(of: "_", with: " ")
                guard !ignoredTags.contains(tag) else { continue }
                insights.tags[tag] = max(insights.tags[tag] ?? 0, obs.confidence)
            }
            insights.maxFaces = max(insights.maxFaces, faces.results?.count ?? 0)
        }
        return insights
    }
}
