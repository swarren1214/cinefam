import Foundation
import Speech

/// Transcribes an event's audio on this Mac with Apple's speech recognizer, giving
/// word timings for subtitles. (WhisperKit can replace this later behind the same call.)
struct EventTranscriber {
    enum TranscribeError: LocalizedError {
        case notAuthorized, unavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Speech recognition isn't allowed. Turn it on in System Settings › Privacy & Security › Speech Recognition."
            case .unavailable: "On-device speech recognition isn't available for this language. Install it in System Settings › Keyboard › Dictation."
            }
        }
    }

    var locale = Locale(identifier: "en-US")

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    func transcribe(_ event: TapeEvent, in tape: Tape) async throws -> [TimedWord] {
        guard await Self.requestAccess() else { throw TranscribeError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscribeError.unavailable
        }

        // Extract the event's audio as 16 kHz mono.
        let source = tape.proxyURL ?? tape.sourceURL
        let wav = FileManager.default.temporaryDirectory.appending(path: "\(event.id.uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try await FFmpeg.run("ffmpeg", ["-hide_banner", "-y", "-loglevel", "error",
                                        "-ss", String(format: "%.3f", event.start),
                                        "-to", String(format: "%.3f", event.end),
                                        "-i", source.path, "-vn", "-ac", "1", "-ar", "16000", wav.path])

        let request = SFSpeechURLRecognitionRequest(url: wav)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let offset = event.start
        do {
            return try await withCheckedThrowingContinuation { cont in
                var finished = false
                _ = recognizer.recognitionTask(with: request) { result, error in
                    guard !finished else { return }
                    if let result, result.isFinal {
                        finished = true
                        cont.resume(returning: result.bestTranscription.segments.map {
                            TimedWord(text: $0.substring,
                                      start: offset + $0.timestamp,
                                      end: offset + $0.timestamp + $0.duration,
                                      confidence: Double($0.confidence))
                        })
                    } else if let error {
                        finished = true
                        cont.resume(throwing: error)
                    }
                }
            }
        } catch {
            // "No speech detected" is normal for quiet footage.
            if (error as NSError).domain == "kAFAssistantErrorDomain" { return [] }
            throw error
        }
    }
}
