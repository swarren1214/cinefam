import Foundation
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case allMovies
    case tape(UUID)
}

/// App state: the library of tapes, the analysis queue and exports.
@MainActor
@Observable
final class AppModel {
    var tapes: [Tape] = []
    var selection: SidebarItem? = .allMovies
    var selectedEventID: UUID?
    var exportSettings: ExportSettings = {
        if let data = UserDefaults.standard.data(forKey: "exportSettings"),
           let s = try? JSONDecoder().decode(ExportSettings.self, from: data) { return s }
        return ExportSettings()
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(exportSettings) {
                UserDefaults.standard.set(data, forKey: "exportSettings")
            }
        }
    }
    /// "Restoring event 2 of 7…" while exporting.
    var renderStage: String?
    var esrganInstallProgress: Double?

    // Restoration preview
    var showRestorePreview = false
    var previewURL: URL?
    var previewProgress: Double?
    private var previewTask: Task<Void, Never>?

    var showImporter = false
    var showExport = false
    var showInspector = true
    var errorMessage: String?
    var exportProgress: Double?
    var enrichingEventID: UUID?

    /// Settings › Analysis.
    var autoTranscribe = UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "autoTranscribe") }
    }
    var aiNaming = UserDefaults.standard.object(forKey: "aiNaming") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aiNaming, forKey: "aiNaming") }
    }

    private var queueTask: Task<Void, Never>?
    private let analyzer = Analyzer()

    // MARK: Storage

    static var supportFolder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CineFam")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var proxyFolder: URL {
        let url = supportFolder.appending(path: "Proxies")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var libraryFile: URL { supportFolder.appending(path: "library.json") }

    init() {
        load()
        // Work interrupted by quitting starts again.
        for i in tapes.indices {
            if case .analyzing = tapes[i].status { tapes[i].status = .queued }
            if case .rendering = tapes[i].status { tapes[i].status = .needsReview }
        }
        runQueue()
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.libraryFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        tapes = (try? decoder.decode([Tape].self, from: data)) ?? []
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do { try encoder.encode(tapes).write(to: Self.libraryFile, options: .atomic) }
        catch { errorMessage = "Couldn't save the library: \(error.localizedDescription)" }
    }

    // MARK: Lookups

    func tape(_ id: UUID) -> Tape? { tapes.first { $0.id == id } }

    var selectedTape: Tape? {
        if case .tape(let id) = selection { return tape(id) }
        return nil
    }

    var allEvents: [(tape: Tape, event: TapeEvent)] {
        tapes.flatMap { t in t.events.filter { $0.status != .discarded }.map { (tape: t, event: $0) } }
            .sorted { ($0.event.date ?? .distantFuture) < ($1.event.date ?? .distantFuture) }
    }

    func binding(tape tapeID: UUID, event eventID: UUID) -> Binding<TapeEvent>? {
        guard let t = tapes.firstIndex(where: { $0.id == tapeID }),
              tapes[t].events.contains(where: { $0.id == eventID }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.tapes.first { $0.id == tapeID }?.events.first { $0.id == eventID }
                    ?? TapeEvent(index: 0, start: 0, end: 0, title: "")
            },
            set: { [weak self] new in
                guard let self,
                      let t = self.tapes.firstIndex(where: { $0.id == tapeID }),
                      let e = self.tapes[t].events.firstIndex(where: { $0.id == eventID }) else { return }
                self.tapes[t].events[e] = new
                self.save()
            })
    }

    private func mutateTape(_ id: UUID, _ change: (inout Tape) -> Void) {
        guard let i = tapes.firstIndex(where: { $0.id == id }) else { return }
        change(&tapes[i])
        save()
    }

    // MARK: Import + analysis

    func importTapes(_ urls: [URL]) {
        for url in urls {
            guard !tapes.contains(where: { $0.sourceURL == url }) else { continue }
            let label = url.deletingPathExtension().lastPathComponent
            tapes.append(Tape(sourceURL: url, label: label))
        }
        save()
        if let last = tapes.last { selection = .tape(last.id) }
        runQueue()
    }

    func reanalyze(_ id: UUID) {
        mutateTape(id) { $0.status = .queued }
        runQueue()
    }

    func removeTape(_ id: UUID) {
        if let proxy = tape(id)?.proxyURL { try? FileManager.default.removeItem(at: proxy) }
        tapes.removeAll { $0.id == id }
        if selection == .tape(id) { selection = .allMovies }
        save()
    }

    /// Analyzes queued tapes one at a time.
    func runQueue() {
        guard queueTask == nil, FFmpeg.isInstalled else { return }
        queueTask = Task { [weak self] in
            while let self, let next = self.tapes.first(where: { $0.status == .queued }) {
                await self.analyze(next)
            }
            self?.queueTask = nil
        }
    }

    private func analyze(_ tape: Tape) async {
        let id = tape.id
        mutateTape(id) { $0.status = .analyzing(progress: 0) }
        do {
            // Stages 1–3 take the first half of the progress bar, dating and naming the rest.
            var result = try await analyzer.analyze(tape, proxyFolder: Self.proxyFolder) { p in
                Task { @MainActor [weak self] in self?.setAnalysisProgress(id, p * 0.5) }
            }
            for i in result.events.indices {
                result.events[i].title = "\(tape.label) – Event \(i + 1)"
            }
            mutateTape(id) { $0 = result; $0.status = .analyzing(progress: 0.5) }
            let enricher = EventEnricher(options: .init(transcribe: autoTranscribe, name: aiNaming))
            result = try await enricher.enrich(result) { p in
                Task { @MainActor [weak self] in self?.setAnalysisProgress(id, 0.5 + p * 0.5) }
            }
            result.status = .needsReview
            mutateTape(id) { $0 = result }
        } catch is CancellationError {
            mutateTape(id) { $0.status = .queued }
        } catch {
            mutateTape(id) { $0.status = .failed(message: error.localizedDescription) }
        }
    }

    private func setAnalysisProgress(_ id: UUID, _ p: Double) {
        guard let i = tapes.firstIndex(where: { $0.id == id }), case .analyzing = tapes[i].status else { return }
        tapes[i].status = .analyzing(progress: p)
    }

    /// Re-reads one event's date stamp and asks for a new title and summary.
    func enrich(tape tapeID: UUID, event eventID: UUID) async {
        guard let tape = self.tape(tapeID) else { return }
        enrichingEventID = eventID
        defer { enrichingEventID = nil }
        do {
            let enricher = EventEnricher(options: .init(transcribe: autoTranscribe, name: true))
            let updated = try await enricher.enrich(tape, only: eventID) { _ in }
            guard let new = updated.events.first(where: { $0.id == eventID }) else { return }
            mutateTape(tapeID) { t in
                if let i = t.events.firstIndex(where: { $0.id == eventID }) {
                    // Keep anything the user edited in the meantime other than these fields.
                    t.events[i].title = new.title
                    t.events[i].summary = new.summary
                    t.events[i].keywords = new.keywords
                    t.events[i].visualTags = new.visualTags
                    t.events[i].faceCount = new.faceCount
                    t.events[i].aiNamed = new.aiNamed
                    if t.events[i].words.isEmpty { t.events[i].words = new.words }
                    if t.events[i].dateSource != .manual {
                        t.events[i].date = new.date
                        t.events[i].datePrecision = new.datePrecision
                        t.events[i].dateSource = new.dateSource
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Review edits

    func split(tape tapeID: UUID, event eventID: UUID, at time: TimeInterval) {
        mutateTape(tapeID) { t in
            guard let i = t.events.firstIndex(where: { $0.id == eventID }) else { return }
            let e = t.events[i]
            guard time > e.start + 1, time < e.end - 1 else { return }
            var first = e, second = e
            second.id = UUID()
            first.end = time
            second.start = time
            first.shots = e.shots.filter { $0.start < time }.map { Shot(start: $0.start, end: min($0.end, time)) }
            second.shots = e.shots.filter { $0.end > time }.map { Shot(start: max($0.start, time), end: $0.end) }
            first.words = e.words.filter { $0.start < time }
            second.words = e.words.filter { $0.start >= time }
            second.title = e.title + " (2)"
            t.events.replaceSubrange(i...i, with: [first, second])
            Self.renumber(&t)
        }
    }

    func mergeWithNext(tape tapeID: UUID, event eventID: UUID) {
        mutateTape(tapeID) { t in
            guard let i = t.events.firstIndex(where: { $0.id == eventID }), i + 1 < t.events.count else { return }
            var merged = t.events[i]
            let next = t.events[i + 1]
            merged.end = next.end
            merged.shots += next.shots
            merged.words += next.words
            merged.chapters += next.chapters.map { Chapter(title: $0.title, start: $0.start + (next.start - merged.start)) }
            t.events.replaceSubrange(i...(i + 1), with: [merged])
            Self.renumber(&t)
        }
    }

    private static func renumber(_ t: inout Tape) {
        for i in t.events.indices { t.events[i].index = i + 1 }
    }

    func transcribe(tape tapeID: UUID, event eventID: UUID) async {
        guard let tape = self.tape(tapeID), let event = tape.events.first(where: { $0.id == eventID }) else { return }
        do {
            let words = try await EventTranscriber().transcribe(event, in: tape)
            mutateTape(tapeID) { t in
                if let i = t.events.firstIndex(where: { $0.id == eventID }) { t.events[i].words = words }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Export

    func exportTape(_ tapeID: UUID) {
        guard let tape = self.tape(tapeID) else { return }
        let events = tape.events.filter { $0.status != .discarded }
        let settings = exportSettings
        let exporter = Exporter(settings: settings)
        let restoring = settings.restore.enabled
        let restorer = Restorer(settings: settings.restore, targetHeight: settings.resolution.height)
        mutateTape(tapeID) { $0.status = .rendering(progress: 0) }
        exportProgress = 0
        Task {
            do {
                for (n, event) in events.enumerated() {
                    // Restoring is the slow part: it gets most of each event's share of the bar.
                    let restoreShare = restoring ? 0.85 : 0.0
                    func report(_ p: Double) {
                        let total = (Double(n) + p) / Double(max(events.count, 1))
                        exportProgress = total
                        mutateTape(tapeID) { $0.status = .rendering(progress: total) }
                    }
                    var master: URL?
                    if restoring {
                        renderStage = "Restoring \(n + 1) of \(events.count): \(event.title)"
                        master = try await restorer.restore(event, in: tape) { p in
                            Task { @MainActor in report(p * restoreShare) }
                        }
                    }
                    renderStage = "Saving \(n + 1) of \(events.count): \(event.title)"
                    _ = try await exporter.export(.init(event: event, tape: tape, posterURL: nil,
                                                        restoredURL: master)) { p in
                        Task { @MainActor in report(restoreShare + p * (1 - restoreShare)) }
                    }
                    mutateTape(tapeID) { t in
                        if let i = t.events.firstIndex(where: { $0.id == event.id }) { t.events[i].status = .rendered }
                    }
                }
                mutateTape(tapeID) { $0.status = .done }
            } catch {
                errorMessage = error.localizedDescription
                mutateTape(tapeID) { $0.status = .needsReview }
            }
            exportProgress = nil
            renderStage = nil
        }
    }

    // MARK: Restoration

    /// Renders a 10-second original | restored comparison starting at `time`.
    func previewRestoration(tape tapeID: UUID, event eventID: UUID, at time: TimeInterval) {
        guard let tape = self.tape(tapeID), let event = tape.events.first(where: { $0.id == eventID }) else { return }
        previewTask?.cancel()
        previewURL = nil
        previewProgress = 0
        showRestorePreview = true
        let restorer = Restorer(settings: exportSettings.restore, targetHeight: exportSettings.resolution.height)
        previewTask = Task {
            do {
                let url = try await restorer.preview(event, in: tape, at: time) { p in
                    Task { @MainActor [weak self] in self?.previewProgress = p }
                }
                previewURL = url
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            previewProgress = nil
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewProgress = nil
    }

    func installRealESRGAN() {
        guard esrganInstallProgress == nil else { return }
        esrganInstallProgress = 0
        Task {
            do {
                try await RealESRGAN.install { p in
                    Task { @MainActor [weak self] in self?.esrganInstallProgress = p }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            esrganInstallProgress = nil
        }
    }
}
