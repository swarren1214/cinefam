import Foundation
import FoundationModels

@Generable
struct EventDescription {
    @Guide(description: "A short movie-style title for this home video, 2 to 6 words, with an en dash between the occasion and a detail, like \"Christmas Morning – Opening Presents\" or \"Lake Day – Tubing\". Only use a person's name if it is spoken in the transcript.")
    var title: String

    @Guide(description: "One or two plain sentences saying what happens in the video, for its description.")
    var summary: String

    @Guide(description: "Three to six lowercase keywords, such as birthday, cake, backyard.")
    var keywords: [String]
}

/// What the namer hands back (plain struct, separate from the @Generable schema).
struct EventNaming {
    var title: String
    var summary: String
    var keywords: [String]
}

/// Writes titles, summaries and keywords for events, on this Mac.
/// Uses Apple's on-device Foundation Models when available, with a simple
/// keyword-based fallback when it isn't (Apple Intelligence off, older Macs).
struct EventNamer {
    static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private static let instructions = """
        You name home videos from old family tapes so they can be saved as movies. \
        You get a few labels a computer saw in frames of the video, how many faces it saw, \
        words spoken in it, its date if known, and the label written on the tape. \
        Be concrete, warm and plain. Never invent names of people or places that are not \
        in the input. If you can't tell what is happening, describe the setting.
        """

    struct Input {
        var tags: [String]
        var faces: Int
        var transcript: String
        var dateText: String?
        var tapeLabel: String
        var length: TimeInterval
        var onScreenText: [String]
    }

    func describe(_ input: Input) async -> EventNaming {
        if Self.isModelAvailable, let result = try? await describeWithModel(input) {
            return result
        }
        return Self.fallback(input)
    }

    private func describeWithModel(_ input: Input) async throws -> EventNaming {
        let session = LanguageModelSession(instructions: Self.instructions)
        var prompt = "Tape label: \(input.tapeLabel)\n"
        prompt += "Length: \(input.length.friendlyLength)\n"
        if let d = input.dateText { prompt += "Date: \(d)\n" }
        if !input.tags.isEmpty { prompt += "Seen in frames: \(input.tags.joined(separator: ", "))\n" }
        prompt += "Faces seen at once: \(input.faces)\n"
        let text = input.onScreenText.filter { DateStampParser.parse($0) == nil }.prefix(5)
        if !text.isEmpty { prompt += "Text on screen: \(text.joined(separator: " / "))\n" }
        let spoken = input.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt += spoken.isEmpty ? "Nothing clear was said.\n"
                                 : "Spoken: \"\(String(spoken.prefix(1200)))\"\n"
        let response = try await session.respond(to: prompt, generating: EventDescription.self)
        let d = response.content
        return EventNaming(
            title: d.title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespacesAndNewlines)),
            summary: d.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: d.keywords.map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    // MARK: Fallback

    private static let occasions: [(title: String, cues: [String])] = [
        ("Birthday", ["birthday", "birthday cake", "candle", "happy birthday"]),
        ("Christmas", ["christmas", "christmas tree", "merry christmas", "santa", "ornament"]),
        ("Fourth of July", ["fireworks", "fourth of july", "sparkler"]),
        ("Halloween", ["halloween", "jack o lantern", "costume", "trick or treat"]),
        ("Thanksgiving", ["thanksgiving", "turkey"]),
        ("Easter", ["easter", "easter egg"]),
        ("Wedding", ["wedding", "bride", "wedding dress"]),
        ("Graduation", ["graduation", "graduate", "diploma"]),
        ("Baseball Game", ["baseball", "little league", "softball"]),
        ("Soccer Game", ["soccer"]),
        ("Day at the Beach", ["beach", "ocean", "seashore"]),
        ("Day at the Lake", ["lake", "boat", "dock"]),
        ("Pool Day", ["swimming pool", "pool"]),
        ("Snow Day", ["snow", "sled", "snowman"]),
        ("Camping", ["camping", "tent", "campfire"]),
    ]

    static func fallback(_ input: Input) -> EventNaming {
        let haystack = (input.tags + [input.transcript.lowercased()]).joined(separator: " | ")
        let occasion = occasions.first { o in o.cues.contains { haystack.contains($0) } }?.title
        let setting = input.tags.first.map { $0.capitalized }
        let base = occasion ?? setting ?? "Home Movie"
        let title = input.dateText.map { "\(base) – \($0)" } ?? base
        var summary = occasion.map { "\($0) footage" } ?? "Home video"
        if let d = input.dateText { summary += " from \(d)" }
        if input.faces > 0 { summary += " with \(input.faces) \(input.faces == 1 ? "person" : "people") on screen" }
        summary += "."
        return EventNaming(title: title, summary: summary,
                                keywords: Array(([occasion?.lowercased()].compactMap { $0 } + input.tags).prefix(6)))
    }
}
