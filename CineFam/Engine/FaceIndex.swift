import CoreGraphics
import Foundation
import Vision

/// One face seen in one frame of one event.
struct FaceRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var tapeID: UUID
    var eventID: UUID
    var time: TimeInterval
    var crop: URL
    var quality: Double
    /// Archived `VNFeaturePrintObservation` of the face crop.
    var print: Data
    /// The person's name once the user (or grouping, from a named person) assigns one.
    var person: String?
}

/// Every face found across the library, saved in Application Support/CineFam/Faces.
struct FaceLibrary: Codable {
    var faces: [FaceRecord] = []
    /// Lower = stricter grouping. Feature-print distances; tune with the slider in People.
    var threshold = 0.55

    static var folder: URL {
        let url = AppModel.supportFolder.appending(path: "Faces")
        try? FileManager.default.createDirectory(at: url.appending(path: "crops"), withIntermediateDirectories: true)
        return url
    }
    private static var file: URL { folder.appending(path: "faces.json") }

    static func load() -> FaceLibrary {
        guard let data = try? Data(contentsOf: file),
              let lib = try? JSONDecoder().decode(FaceLibrary.self, from: data) else { return FaceLibrary() }
        return lib
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.file, options: .atomic) }
    }

    var names: [String] { Array(Set(faces.compactMap(\.person))).sorted() }

    /// Replaces the faces of one tape (after it's analyzed again), keeping names given to
    /// faces of the same event at about the same moment.
    mutating func replaceFaces(of tapeID: UUID, with new: [FaceRecord]) {
        let old = faces.filter { $0.tapeID == tapeID }
        for f in old where !new.contains(where: { $0.crop == f.crop }) { try? FileManager.default.removeItem(at: f.crop) }
        faces.removeAll { $0.tapeID == tapeID }
        faces += new.map { f in
            var f = f
            if f.person == nil,
               let match = old.first(where: { $0.eventID == f.eventID && abs($0.time - f.time) < 0.5 && $0.person != nil }) {
                f.person = match.person
            }
            return f
        }
    }
}

/// An unnamed group of faces that look like one person.
struct FaceGroup: Identifiable, Hashable {
    var id: UUID { faceIDs.first ?? UUID() }
    var faceIDs: [UUID]
}

/// Finds faces in frames and makes a feature print of each.
enum FaceExtractor {
    static let minFacePixels = 48.0
    static let minQuality = 0.25

    static func faces(in image: CGImage, tapeID: UUID, eventID: UUID, time: TimeInterval) -> [FaceRecord] {
        let detect = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([detect])
        let W = Double(image.width), H = Double(image.height)
        var out: [FaceRecord] = []
        for obs in detect.results ?? [] {
            let q = Double(obs.faceCaptureQuality ?? 0)
            let box = obs.boundingBox
            guard Double(box.width) * W >= minFacePixels, q >= minQuality else { continue }
            // Square crop with some margin; Vision's origin is bottom-left.
            let side = max(Double(box.width) * W, Double(box.height) * H) * 1.4
            let cx = Double(box.midX) * W, cy = (1 - Double(box.midY)) * H
            let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
            guard let crop = image.cropping(to: rect), let print = featurePrint(crop) else { continue }
            let id = UUID()
            let url = FaceLibrary.folder.appending(path: "crops/\(id.uuidString).jpg")
            guard (try? PosterRenderer.writeJPEG(crop, to: url, quality: 0.85)) != nil else { continue }
            out.append(FaceRecord(id: id, tapeID: tapeID, eventID: eventID, time: time, crop: url, quality: q, print: print))
        }
        return out
    }

    static func featurePrint(_ image: CGImage) -> Data? {
        let req = VNGenerateImageFeaturePrintRequest()
        req.imageCropAndScaleOption = .scaleFill
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])) != nil,
              let obs = req.results?.first else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true)
    }

    /// Samples each event's frames and collects its faces.
    static func scan(_ tape: Tape, progress: @escaping @Sendable (Double) -> Void) async -> [FaceRecord] {
        let sampler = KeyframeSampler(maxFrames: 8)
        let folder = FileManager.default.temporaryDirectory.appending(path: "cinefam-faces-\(tape.id.uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var all: [FaceRecord] = []
        let events = tape.events.filter { $0.status != .discarded }
        for (n, e) in events.enumerated() {
            if Task.isCancelled { break }
            let times = sampler.times(for: e)
            let urls = (try? await sampler.extract(e, from: tape, into: folder)) ?? []
            for (i, url) in urls.enumerated() {
                guard let img = HeroFramePicker.loadImage(url) else { continue }
                all += faces(in: img, tapeID: tape.id, eventID: e.id, time: i < times.count ? times[i] : e.start)
            }
            progress(Double(n + 1) / Double(max(events.count, 1)))
        }
        return all
    }
}

/// Groups faces into people. A port of prototype/face_groups.py.
struct FaceClusterer {
    var threshold: Double
    var minSize = 2

    struct Result {
        var assigned: [UUID: String]       // faces that joined a named person
        var groups: [FaceGroup]            // unnamed people, largest first
        var unsorted: [UUID]
    }

    func run(_ faces: [FaceRecord]) -> Result {
        var prints: [UUID: VNFeaturePrintObservation] = [:]
        for f in faces {
            prints[f.id] = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: f.print)
        }
        func dist(_ a: UUID, _ b: UUID) -> Double {
            guard let pa = prints[a], let pb = prints[b] else { return .infinity }
            var d: Float = 0
            return (try? pa.computeDistance(&d, to: pb)) != nil ? Double(d) : .infinity
        }
        let usable = faces.filter { prints[$0.id] != nil }

        // 1. Faces near a named person join them (mean of the 3 nearest of their faces).
        var people: [String: [UUID]] = [:]
        for f in usable { if let p = f.person { people[p, default: []].append(f.id) } }
        var assigned: [UUID: String] = [:]
        var loose: [FaceRecord] = []
        for f in usable where f.person == nil {
            var best: (String, Double)?
            for (name, members) in people {
                let ds = members.map { dist(f.id, $0) }.sorted()
                let d = ds.prefix(3).reduce(0, +) / Double(min(3, ds.count))
                if d < (best?.1 ?? .infinity) { best = (name, d) }
            }
            if let best, best.1 < threshold {
                assigned[f.id] = best.0
                people[best.0, default: []].append(f.id)
            } else {
                loose.append(f)
            }
        }

        // 2. Greedy grouping, best faces first.
        var groups: [[UUID]] = []
        for f in loose.sorted(by: { $0.quality > $1.quality }) {
            var best: (Int, Double)?
            for (i, g) in groups.enumerated() {
                let d = g.prefix(32).map { dist(f.id, $0) }.min() ?? .infinity
                if d < (best?.1 ?? .infinity) { best = (i, d) }
            }
            if let best, best.1 < threshold { groups[best.0].append(f.id) } else { groups.append([f.id]) }
        }

        // 3. Merge groups that are really one person.
        var merged = true
        while merged {
            merged = false
            outer: for i in groups.indices {
                for j in groups.indices where j > i {
                    var ds: [Double] = []
                    for a in groups[i].prefix(32) { for b in groups[j].prefix(32) { ds.append(dist(a, b)) } }
                    ds.sort()
                    if ds.prefix(3).reduce(0, +) / Double(min(3, ds.count)) < threshold {
                        let absorbed = groups.remove(at: j)   // j > i, so i stays valid
                        groups[i] += absorbed
                        merged = true
                        break outer
                    }
                }
            }
        }

        let big = groups.filter { $0.count >= minSize }.sorted { $0.count > $1.count }
        return Result(assigned: assigned, groups: big.map { FaceGroup(faceIDs: $0) },
                      unsorted: groups.filter { $0.count < minSize }.flatMap { $0 })
    }
}
