import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import FoundationModels
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Everything that makes one event's poster. Saved on the event, so it can be re-rendered.
struct PosterSpec: Codable, Hashable {
    var heroTime: TimeInterval
    var heroImage: URL
    var focusX = 0.5
    var focusY = 0.45
    var grade: PosterGrade = .warm80s
    var template: PosterTemplate = .classic
    var title: String
    var tagline: String
    var kicker = "A FAMILY PICTURE"
    var billing: String
    var dateLine: String
    var accent: PosterAccent = .orange
    var posterURL: URL?
    var fanartURL: URL?
    var renderedAt: Date?

    // Phase 6. Optional so posters saved before them still load.
    var style: PosterStyle?
    var styleStrength: Double?
    /// Image Playground result for an AI style (kept so it isn't regenerated every render).
    var illustratedImage: URL?

    var drawStyle: PosterStyle { style ?? .photo }
    var strength: Double { styleStrength ?? 0.85 }
    var usesIllustration: Bool {
        drawStyle.isAI && illustratedImage.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
    /// Generated illustrations have their own composition, so crop them from the centre.
    var focus: CGPoint { usesIllustration ? CGPoint(x: 0.5, y: 0.45) : CGPoint(x: focusX, y: focusY) }
}

enum PosterGrade: String, Codable, CaseIterable, Identifiable {
    case natural, warm80s, fadedFilm, tealOrange, noir
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: "Natural"
        case .warm80s: "Warm ’80s"
        case .fadedFilm: "Faded Film"
        case .tealOrange: "Teal & Orange"
        case .noir: "Black & White"
        }
    }

    /// Core Image color grade.
    func apply(_ input: CIImage) -> CIImage {
        func matrix(_ img: CIImage, r: (CGFloat, CGFloat, CGFloat), g: (CGFloat, CGFloat, CGFloat),
                    b: (CGFloat, CGFloat, CGFloat), bias: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)) -> CIImage {
            let f = CIFilter.colorMatrix()
            f.inputImage = img
            f.rVector = CIVector(x: r.0, y: r.1, z: r.2, w: 0)
            f.gVector = CIVector(x: g.0, y: g.1, z: g.2, w: 0)
            f.bVector = CIVector(x: b.0, y: b.1, z: b.2, w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            f.biasVector = CIVector(x: bias.0, y: bias.1, z: bias.2, w: 0)
            return f.outputImage ?? img
        }
        func controls(_ img: CIImage, saturation: Float, contrast: Float, brightness: Float = 0) -> CIImage {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = saturation
            f.contrast = contrast
            f.brightness = brightness
            return f.outputImage ?? img
        }
        func vignette(_ img: CIImage, _ intensity: Float) -> CIImage {
            let f = CIFilter.vignette()
            f.inputImage = img
            f.intensity = intensity
            f.radius = Float(max(img.extent.width, img.extent.height)) * 0.9
            return f.outputImage ?? img
        }
        switch self {
        case .natural:
            return controls(input, saturation: 1.05, contrast: 1.03)
        case .warm80s:
            let warm = matrix(input, r: (1.08, 0, 0), g: (0, 1.0, 0), b: (0, 0, 0.86), bias: (0.02, 0.01, 0))
            return vignette(controls(warm, saturation: 1.12, contrast: 1.06), 0.7)
        case .fadedFilm:
            let lifted = matrix(input, r: (0.9, 0, 0), g: (0, 0.9, 0), b: (0, 0, 0.88), bias: (0.07, 0.06, 0.08))
            return vignette(controls(lifted, saturation: 0.75, contrast: 0.9), 0.4)
        case .tealOrange:
            let graded = matrix(input, r: (1.12, 0, -0.04), g: (0, 1.0, 0.02), b: (-0.04, 0.08, 0.92),
                                bias: (0, 0.01, 0.03))
            return vignette(controls(graded, saturation: 1.18, contrast: 1.1), 0.6)
        case .noir:
            return vignette(controls(input, saturation: 0, contrast: 1.22), 0.9)
        }
    }
}

enum PosterTemplate: String, Codable, CaseIterable, Identifiable {
    case classic, minimal, vhsBox, titleCard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "Classic One-Sheet"
        case .minimal: "Minimal"
        case .vhsBox: "VHS Box"
        case .titleCard: "Title Card"
        }
    }
}

enum PosterAccent: String, Codable, CaseIterable, Identifiable {
    case orange, gold, red, teal, white
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .orange: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .gold: Color(red: 0.95, green: 0.8, blue: 0.45)
        case .red: Color(red: 0.92, green: 0.24, blue: 0.2)
        case .teal: Color(red: 0.3, green: 0.8, blue: 0.82)
        case .white: .white
        }
    }
}

// MARK: - Canvas (used for the live preview and for rendering)

/// The poster at 1000 × 1500 points. Previews scale it down; rendering draws it at 1:1.
struct PosterCanvas: View {
    static let size = CGSize(width: 1000, height: 1500)
    let spec: PosterSpec
    let image: CGImage?

    var body: some View {
        ZStack {
            Color.black
            switch spec.template {
            case .classic: classic
            case .minimal: minimal
            case .vhsBox: vhsBox
            case .titleCard: titleCard
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    // Classic one-sheet: full-bleed photo, title at the bottom.
    private var classic: some View {
        ZStack(alignment: .bottom) {
            FocusFill(image: image, focus: spec.focus, size: Self.size)
            LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.95)],
                           startPoint: .init(x: 0.5, y: 0.45), endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.18))
            VStack(spacing: 22) {
                Text(spec.kicker.uppercased())
                    .font(.system(size: 26, weight: .medium)).tracking(12)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 60)
                Text(spec.title)
                    .font(.system(size: 150, weight: .black)).fontWidth(.condensed)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.35)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 20)
                if !spec.tagline.isEmpty {
                    Text(spec.tagline)
                        .font(.system(size: 40, weight: .regular, design: .serif)).italic()
                        .foregroundStyle(.white.opacity(0.9)).lineLimit(2).minimumScaleFactor(0.5)
                }
                Text(spec.billing.uppercased())
                    .font(.system(size: 20, weight: .medium)).fontWidth(.condensed).tracking(3)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 14)
                Text(spec.dateLine.uppercased())
                    .font(.system(size: 30, weight: .semibold)).tracking(10)
                    .foregroundStyle(spec.accent.color)
            }
            .padding(.horizontal, 70).padding(.bottom, 70)
        }
    }

    // Minimal: paper background, framed photo, serif title.
    private var minimal: some View {
        ZStack {
            Color(red: 0.95, green: 0.93, blue: 0.89)
            VStack(alignment: .leading, spacing: 34) {
                FocusFill(image: image, focus: spec.focus,
                          size: CGSize(width: 840, height: 900))
                    .frame(width: 840, height: 900).clipped()
                Text(spec.title)
                    .font(.system(size: 104, weight: .bold, design: .serif))
                    .lineLimit(2).minimumScaleFactor(0.4)
                    .foregroundStyle(Color(white: 0.1))
                HStack(alignment: .firstTextBaseline) {
                    Text(spec.tagline)
                        .font(.system(size: 30, design: .serif)).italic()
                        .foregroundStyle(Color(white: 0.3)).lineLimit(2)
                    Spacer()
                    Text(spec.dateLine)
                        .font(.system(size: 26, weight: .semibold)).tracking(4)
                        .foregroundStyle(Color(white: 0.3))
                }
            }
            .padding(80)
        }
    }

    // VHS box: black sleeve, ’80s stripes, bold italic title.
    private var vhsBox: some View {
        let stripes: [Color] = [.yellow, .orange, .red, .pink, .purple]
        return ZStack(alignment: .top) {
            Color(white: 0.06)
            VStack(spacing: 0) {
                HStack(spacing: 0) { ForEach(0..<5, id: \.self) { stripes[$0].frame(height: 34) } }
                    .padding(.top, 70)
                FocusFill(image: image, focus: spec.focus,
                          size: CGSize(width: 1000, height: 820))
                    .frame(width: 1000, height: 820).clipped()
                    .padding(.top, 50)
                VStack(alignment: .leading, spacing: 16) {
                    Text(spec.title.uppercased())
                        .font(.system(size: 120, weight: .heavy)).fontWidth(.expanded).italic()
                        .lineLimit(2).minimumScaleFactor(0.3)
                        .foregroundStyle(LinearGradient(colors: [.yellow, .orange, .pink], startPoint: .top, endPoint: .bottom))
                    Text(spec.tagline)
                        .font(.system(size: 32, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    HStack {
                        Text("HQ · VHS · \(spec.dateLine)")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.7), lineWidth: 2))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                    }
                }
                .padding(.horizontal, 70).padding(.top, 50)
                Spacer(minLength: 0)
            }
        }
    }

    // Title card: the whole frame on a blurred bed, title over the middle.
    private var titleCard: some View {
        ZStack {
            FocusFill(image: image, focus: spec.focus, size: Self.size)
                .blur(radius: 40).overlay(Color.black.opacity(0.45))
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 900).shadow(radius: 30)
            }
            Color.black.opacity(0.25)
            VStack(spacing: 24) {
                Text(spec.title)
                    .font(.system(size: 130, weight: .bold, design: .serif))
                    .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.35)
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 16)
                Rectangle().fill(spec.accent.color).frame(width: 160, height: 4)
                Text(spec.dateLine.uppercased())
                    .font(.system(size: 32, weight: .medium)).tracking(12)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(80)
            VStack {
                Spacer()
                Text(spec.tagline)
                    .font(.system(size: 34, design: .serif)).italic()
                    .foregroundStyle(.white.opacity(0.85)).padding(.bottom, 90)
            }
        }
    }
}

/// Fills `size` with the image, keeping `focus` (0–1, top-left origin) in view.
struct FocusFill: View {
    let image: CGImage?
    let focus: CGPoint
    let size: CGSize

    var body: some View {
        if let image {
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = max(size.width / iw, size.height / ih)
            let w = iw * scale, h = ih * scale
            let x = min(0, max(size.width - w, size.width / 2 - focus.x * w))
            let y = min(0, max(size.height - h, size.height / 2 - focus.y * h))
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: w, height: h)
                .offset(x: x + (w - size.width) / 2, y: y + (h - size.height) / 2)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            LinearGradient(colors: [.indigo, .orange], startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: size.height)
        }
    }
}

/// 16:9 backdrop for Plex and the Apple TV app: the graded still, no text.
struct FanartCanvas: View {
    static let size = CGSize(width: 1920, height: 1080)
    let spec: PosterSpec
    let image: CGImage?

    var body: some View {
        FocusFill(image: image, focus: spec.focus, size: Self.size)
    }
}

// MARK: - Rendering

enum PosterRenderer {
    static let ciContext = CIContext()

    /// The hero still (or its AI illustration) with the spec's color grade and style.
    static func gradedImage(_ spec: PosterSpec) -> CGImage? {
        let source = spec.usesIllustration ? spec.illustratedImage! : spec.heroImage
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let graded = spec.grade.apply(input).cropped(to: input.extent)
        let output = spec.drawStyle.apply(graded, strength: spec.strength).cropped(to: input.extent)
        return ciContext.createCGImage(output, from: input.extent)
    }

    /// Writes poster.jpg (1000×1500) and fanart.jpg (1920×1080) into the event's folder.
    @MainActor
    static func render(_ spec: PosterSpec, for event: TapeEvent) throws -> PosterSpec {
        var spec = spec
        let folder = HeroFramePicker.folder(for: event)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = gradedImage(spec)

        let poster = ImageRenderer(content: PosterCanvas(spec: spec, image: image))
        poster.scale = 1
        let fanart = ImageRenderer(content: FanartCanvas(spec: spec, image: image))
        fanart.scale = 1
        guard let posterImage = poster.cgImage, let fanartImage = fanart.cgImage else {
            throw PosterError.render
        }
        let posterURL = folder.appending(path: "poster.jpg")
        let fanartURL = folder.appending(path: "fanart.jpg")
        try writeJPEG(posterImage, to: posterURL)
        try writeJPEG(fanartImage, to: fanartURL)
        spec.posterURL = posterURL
        spec.fanartURL = fanartURL
        spec.renderedAt = .now
        return spec
    }

    enum PosterError: LocalizedError {
        case render, write
        var errorDescription: String? {
            self == .render ? "The poster couldn't be drawn." : "The poster couldn't be saved."
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PosterError.write
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw PosterError.write }
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PosterError.write
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PosterError.write }
    }
}

// MARK: - Copy

@Generable
struct PosterTagline {
    @Guide(description: "A short, warm movie-poster tagline for a family home video, 3 to 8 words, like \"One night. Too many sparklers.\" or \"Some summers last forever.\" No names unless given.")
    var tagline: String
}

enum PosterCopy {
    /// The poster title: the part of the event title before an en dash, if that reads well.
    static func title(for event: TapeEvent) -> String {
        let parts = event.title.components(separatedBy: " – ")
        if parts.count > 1, parts[0].count >= 4, !parts[0].lowercased().hasPrefix("event") { return parts[0] }
        return event.title
    }

    static func billing(for event: TapeEvent, tape: Tape) -> String {
        var parts: [String] = []
        if !event.people.isEmpty { parts.append("Starring " + event.people.joined(separator: ", ")) }
        let format = (tape.info?.videoCodec ?? "").lowercased().contains("dv") ? "MiniDV" : "VHS"
        parts.append("From the tape “\(tape.label)”")
        parts.append("Shot on \(format)")
        parts.append("Restored by CineFam")
        return parts.joined(separator: " · ")
    }

    static func dateLine(for event: TapeEvent) -> String {
        guard let d = event.date else { return "" }
        switch event.precision {
        case .year: return d.formatted(.dateTime.year())
        default: return d.formatted(.dateTime.month(.wide).day().year())
        }
    }

    static func tagline(for event: TapeEvent) async -> String {
        if EventNamer.isModelAvailable {
            let session = LanguageModelSession(instructions: "You write taglines for movie posters made from family home videos. Plain, warm, a little playful. Never invent names.")
            var prompt = "Title: \(event.title)\n"
            if !event.summary.isEmpty { prompt += "What happens: \(event.summary)\n" }
            if let d = event.dateText { prompt += "When: \(d)\n" }
            if let r = try? await session.respond(to: prompt, generating: PosterTagline.self) {
                let t = r.content.tagline.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”").union(.whitespacesAndNewlines))
                if !t.isEmpty { return t }
            }
        }
        let n = event.title.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 9973 }
        return fallbackTaglines[n % fallbackTaglines.count]
    }

    static let fallbackTaglines = [
        "Some days you remember forever.",
        "Rewind. Play. Remember.",
        "The way we were.",
        "Before anyone had a phone camera.",
        "Starring everyone you love.",
        "Filmed on location. In the living room.",
        "Based on a true story.",
    ]
}
