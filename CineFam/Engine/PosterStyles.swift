import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImagePlayground

/// Phase 6: how the hero still is drawn.
///
/// The Core Image styles run instantly on this Mac, need no downloads and keep every face
/// exactly as filmed; "strength" blends them with the photo. The Image Playground styles use
/// Apple's on-device image generator to redraw the still — more striking, but faces become
/// a likeness rather than the real person, and they take a few seconds each.
enum PosterStyle: String, Codable, CaseIterable, Identifiable {
    case photo
    case comic, screenPrint, pencilSketch, retroPrint
    case aiAnimation, aiIllustration, aiSketch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: "Photo"
        case .comic: "Comic"
        case .screenPrint: "Screen Print"
        case .pencilSketch: "Pencil Sketch"
        case .retroPrint: "Retro Print"
        case .aiAnimation: "Animated (AI)"
        case .aiIllustration: "Illustration (AI)"
        case .aiSketch: "Sketch (AI)"
        }
    }

    var isAI: Bool { [.aiAnimation, .aiIllustration, .aiSketch].contains(self) }
    var isFilter: Bool { self != .photo && !isAI }

    static var filterStyles: [PosterStyle] { [.comic, .screenPrint, .pencilSketch, .retroPrint] }
    static var aiStyles: [PosterStyle] { [.aiAnimation, .aiIllustration, .aiSketch] }

    /// Redraws `input` in this style and mixes it with the photo by `strength` (0–1).
    func apply(_ input: CIImage, strength: Double) -> CIImage {
        guard isFilter else { return input }
        let extent = input.extent
        let styled = stylize(input).cropped(to: extent)
        guard strength < 0.999 else { return styled }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = input
        mix.targetImage = styled
        mix.time = Float(max(0, strength))
        return (mix.outputImage ?? styled).cropped(to: extent)
    }

    private func stylize(_ input: CIImage) -> CIImage {
        let extent = input.extent
        // Smooth tape noise first so the effects draw shapes, not grain.
        let calm = CIFilter.noiseReduction()
        calm.inputImage = input
        calm.noiseLevel = 0.04
        calm.sharpness = 0.6
        let base = (calm.outputImage ?? input).cropped(to: extent)

        switch self {
        case .comic:
            let f = CIFilter.comicEffect()
            f.inputImage = base
            return f.outputImage ?? base

        case .screenPrint:
            // A few flat inks, a halftone dot in the shadows, a little extra punch.
            let poster = CIFilter.colorPosterize()
            poster.inputImage = saturated(base, 1.35, contrast: 1.15)
            poster.levels = 5
            let inks = (poster.outputImage ?? base).cropped(to: extent)
            let dots = CIFilter.dotScreen()
            dots.inputImage = grayscale(base)
            dots.center = CGPoint(x: extent.midX, y: extent.midY)
            dots.angle = 0.6
            dots.width = Float(max(extent.width, extent.height) / 180)
            dots.sharpness = 0.7
            let multiply = CIFilter.multiplyBlendMode()
            multiply.inputImage = (dots.outputImage ?? base).cropped(to: extent)
            multiply.backgroundImage = inks
            let printed = (multiply.outputImage ?? inks).cropped(to: extent)
            let soften = CIFilter.dissolveTransition()   // dots at 35% so faces stay clear
            soften.inputImage = inks
            soften.targetImage = printed
            soften.time = 0.35
            return soften.outputImage ?? inks

        case .pencilSketch:
            // Pencil lines on warm paper with a faint wash of the original color.
            let lines = CIFilter.lineOverlay()
            lines.inputImage = base
            lines.nrNoiseLevel = 0.07
            lines.nrSharpness = 0.71
            lines.edgeIntensity = 1.2
            lines.threshold = 0.12
            lines.contrast = 50
            let paper = CIImage(color: CIColor(red: 0.96, green: 0.94, blue: 0.89)).cropped(to: extent)
            let wash = CIFilter.dissolveTransition()
            wash.inputImage = paper
            wash.targetImage = saturated(base, 0.45, contrast: 0.8, brightness: 0.18)
            wash.time = 0.28
            let tinted = (wash.outputImage ?? paper).cropped(to: extent)
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = (lines.outputImage ?? base).cropped(to: extent)
            over.backgroundImage = tinted
            return over.outputImage ?? tinted

        case .retroPrint:
            // Two-color print: deep blue shadows, warm cream highlights.
            let poster = CIFilter.colorPosterize()
            poster.inputImage = saturated(base, 1, contrast: 1.25)
            poster.levels = 6
            let duo = CIFilter.falseColor()
            duo.inputImage = (poster.outputImage ?? base).cropped(to: extent)
            duo.color0 = CIColor(red: 0.09, green: 0.13, blue: 0.3)
            duo.color1 = CIColor(red: 0.99, green: 0.86, blue: 0.68)
            return duo.outputImage ?? base

        default:
            return input
        }
    }

    private func saturated(_ img: CIImage, _ saturation: Float, contrast: Float, brightness: Float = 0) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = img
        f.saturation = saturation
        f.contrast = contrast
        f.brightness = brightness
        return (f.outputImage ?? img).cropped(to: img.extent)
    }

    private func grayscale(_ img: CIImage) -> CIImage { saturated(img, 0, contrast: 1.1) }
}

/// Redraws a still with Apple's on-device Image Playground generator.
enum IllustrationEngine {
    enum IllustrationError: LocalizedError {
        case unavailable, noImage
        var errorDescription: String? {
            switch self {
            case .unavailable: "Image Playground isn't available on this Mac. It needs Apple Intelligence turned on in System Settings."
            case .noImage: "Image Playground didn't return a picture. Try again or pick another frame."
            }
        }
    }

    /// Checks once whether this Mac can generate images.
    static func isAvailable() async -> Bool {
        (try? await ImageCreator()) != nil
    }

    /// Generates an illustration of `still` and saves it beside the event's poster.
    static func illustrate(_ still: CGImage, style: PosterStyle, description: String,
                           saveIn folder: URL) async throws -> URL {
        let creator: ImageCreator
        do { creator = try await ImageCreator() } catch { throw IllustrationError.unavailable }

        let wanted: ImagePlaygroundStyle
        switch style {
        case .aiAnimation: wanted = .animation
        case .aiSketch: wanted = .sketch
        default: wanted = .illustration
        }
        let available = creator.availableStyles
        let chosen = available.contains(wanted) ? wanted : (available.first ?? wanted)

        var concepts: [ImagePlaygroundConcept] = [.image(still)]
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { concepts.append(.text(String(text.prefix(200)))) }

        for try await created in creator.images(for: concepts, style: chosen, limit: 1) {
            let url = folder.appending(path: "illustrated-\(style.rawValue)-\(UUID().uuidString.prefix(6)).png")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PosterRenderer.writePNG(created.cgImage, to: url)
            return url
        }
        throw IllustrationError.noImage
    }
}
