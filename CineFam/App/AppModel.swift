import AppKit
import Foundation
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case allMovies
    case queue
    case people
    case posterStudio
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
    /// Whether ffmpeg/ffprobe can be found (checked at launch and after installing).
    var ffmpegReady = FFmpeg.isInstalled
    var ffmpegInstallProgress: Double?
    var esrganInstallProgress: Double?

    // Restoration preview
    var showRestorePreview = false
    var previewURL: URL?
    var previewProgress: Double?
    private var previewTask: Task<Void, Never>?

    // Poster Studio
    var heroCandidates: [UUID: [HeroCandidate]] = [:]
    var loadingHeroes: Set<UUID> = []
    var posterBatchProgress: Double?
    var illustratingEventID: UUID?
    var imagePlaygroundAvailable: Bool?

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

    // MARK: Library mode (Phase 7)

    var queuePaused = false
    /// Tapes finished by the current unattended run, for the "done" notification.
    private var batchDone = 0
    private var keepAwake: NSObjectProtocol?

    var autoExport = UserDefaults.standard.bool(forKey: "autoExport") {
        didSet { UserDefaults.standard.set(autoExport, forKey: "autoExport") }
    }
    var autoPosters = UserDefaults.standard.object(forKey: "autoPosters") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPosters, forKey: "autoPosters") }
    }
    var autoPeople = UserDefaults.standard.object(forKey: "autoPeople") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPeople, forKey: "autoPeople") }
    }
    var notifyWhenDone = UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyWhenDone, forKey: "notifyWhenDone") }
    }

    // People
    var faceLibrary = FaceLibrary.load()
    var faceGroups: [FaceGroup] = []
    var unsortedFaces: [UUID] = []
    var faceScanProgress: Double?
    var libraryPersonFilter: String?
    private let analyzer = Analyzer()

    /// Shows an error to the user, except cancellations: those happen on purpose (switching
    /// events in Poster Studio, stopping a render) and aren't failures.
    func report(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return }
        if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError { return }
        errorMessage = error.localizedDescription
    }

    // MARK: Storage

    nonisolated static var supportFolder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CineFam")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    nonisolated static var proxyFolder: URL {
        let url = supportFolder.appending(path: "Proxies")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    nonisolated private static var libraryFile: URL { supportFolder.appending(path: "library.json") }

    init() {
        // A crash or force quit leaves our ffmpeg / Real-ESRGAN running (and the Mac hot):
        // stop those first, and make sure quitting stops whatever is running now.
        Task.detached(priority: .utility) { ChildProcesses.killOrphans() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { _ in
            ChildProcesses.terminateAll()
        }
        load()
        // Work interrupted by quitting starts again.
        for i in tapes.indices {
            if case .analyzing = tapes[i].status { tapes[i].status = .queued }
            if case .rendering = tapes[i].status { tapes[i].status = .needsReview }
        }
        runQueue()
        Task { await regroupFaces() }
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

    /// Adds tapes (files or folders). Folder scanning runs in the background, so a slow
    /// network drive never blocks the window, and the library changes happen on a later
    /// main-thread turn, never in the middle of a drop or a layout pass.
    func importTapes(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importScanning += 1
        Task {
            let files = await Task.detached(priority: .userInitiated) {
                urls.flatMap { MediaFiles.videoFiles(in: $0) }
            }.value
            importScanning -= 1
            if files.isEmpty {
                let names = urls.map(\.lastPathComponent).prefix(3).joined(separator: ", ")
                errorMessage = "No videos found in \(names). CineFam looks for movie files such as MOV, MP4, AVI, DV, MPG and MKV, including inside folders."
                return
            }
            addTapes(files)
        }
    }

    /// Folders being searched for videos right now (shown as a spinner).
    var importScanning = 0

    private func addTapes(_ files: [URL]) {
        var added = 0
        for url in files {
            guard !tapes.contains(where: { $0.sourceURL == url }) else { continue }
            let label = url.deletingPathExtension().lastPathComponent
            tapes.append(Tape(sourceURL: url, label: label))
            added += 1
        }
        save()
        // One tape: open it. A shoebox: show the queue.
        if added == 1, let last = tapes.last { selection = .tape(last.id) }
        else if added > 1 { selection = .queue }
        runQueue()
    }

    static func videoFiles(in url: URL) -> [URL] { MediaFiles.videoFiles(in: url) }

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
    var queuedCount: Int { tapes.filter { $0.status == .queued }.count }
    var isQueueRunning: Bool { queueTask != nil }

    /// Works through queued tapes one at a time: analyze, then (in library mode) find
    /// people, make posters and export, without waiting for review.
    func runQueue() {
        guard queueTask == nil, !queuePaused, FFmpeg.isInstalled,
              tapes.contains(where: { $0.status == .queued }) else { return }
        batchDone = 0
        keepAwake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "CineFam is processing tapes")
        queueTask = Task { [weak self] in
            while let self, !self.queuePaused, !Task.isCancelled,
                  let next = self.tapes.first(where: { $0.status == .queued }) {
                await self.analyze(next)
                guard !Task.isCancelled, self.tape(next.id)?.status == .needsReview else { continue }
                if self.autoPeople { await self.scanFaces(tape: next.id) }
                if self.autoExport {
                    if self.autoPosters { await self.makeMissingPosters(tape: next.id) }
                    await self.runExport(next.id)
                }
                self.batchDone += 1
            }
            self?.queueFinished()
        }
    }

    private func queueFinished() {
        queueTask = nil
        if let keepAwake { ProcessInfo.processInfo.endActivity(keepAwake) }
        keepAwake = nil
        if batchDone > 0 && notifyWhenDone && !queuePaused {
            let movies = tapes.reduce(0) { $0 + $1.events.filter { $0.status == .rendered }.count }
            Notifier.post(title: "CineFam finished \(batchDone) tape\(batchDone == 1 ? "" : "s")",
                          body: autoExport ? "\(movies) movies are in your library." : "They're ready for review.")
        }
    }

    func pauseQueue() { queuePaused = true }

    func resumeQueue() {
        queuePaused = false
        runQueue()
    }

    /// Stops the tape being worked on now; it goes back in the queue.
    func stopCurrent() {
        queuePaused = true
        queueTask?.cancel()
    }

    func moveToFront(_ id: UUID) {
        guard let i = tapes.firstIndex(where: { $0.id == id }) else { return }
        let t = tapes.remove(at: i)
        let firstQueued = tapes.firstIndex { $0.status == .queued } ?? tapes.count
        tapes.insert(t, at: firstQueued)
        save()
    }

    private func makeMissingPosters(tape tapeID: UUID) async {
        for e in tape(tapeID)?.events ?? [] where e.status != .discarded && e.posterImageURL == nil {
            await makeDefaultPoster(tape: tapeID, event: e.id)
        }
    }

    // MARK: People

    /// Finds faces in a tape's events, then regroups the whole library.
    func scanFaces(tape tapeID: UUID) async {
        guard let tape = self.tape(tapeID) else { return }
        faceScanProgress = 0
        let found = await FaceExtractor.scan(tape) { p in
            Task { @MainActor [weak self] in self?.faceScanProgress = p }
        }
        faceLibrary.replaceFaces(of: tapeID, with: found)
        faceLibrary.save()
        faceScanProgress = nil
        await regroupFaces()
    }

    func scanAllFaces() {
        Task {
            for t in tapes where t.status == .needsReview || t.status == .done { await scanFaces(tape: t.id) }
        }
    }

    /// Re-runs grouping off the main thread and applies names to events.
    func regroupFaces() async {
        let faces = faceLibrary.faces
        let clusterer = FaceClusterer(threshold: faceLibrary.threshold)
        let result = await Task.detached(priority: .userInitiated) { clusterer.run(faces) }.value
        for (id, name) in result.assigned {
            if let i = faceLibrary.faces.firstIndex(where: { $0.id == id }) { faceLibrary.faces[i].person = name }
        }
        faceGroups = result.groups
        unsortedFaces = result.unsorted
        faceLibrary.save()
        applyFaceNames()
    }

    func face(_ id: UUID) -> FaceRecord? { faceLibrary.faces.first { $0.id == id } }

    func faces(of person: String) -> [FaceRecord] {
        faceLibrary.faces.filter { $0.person == person }.sorted { $0.quality > $1.quality }
    }

    /// Names an unnamed group (or adds it to someone already named).
    func name(_ group: FaceGroup, as rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for id in group.faceIDs {
            if let i = faceLibrary.faces.firstIndex(where: { $0.id == id }) { faceLibrary.faces[i].person = name }
        }
        faceGroups.removeAll { $0 == group }
        faceLibrary.save()
        applyFaceNames()
        Task { await regroupFaces() }      // other faces may now join this person
    }

    func rename(person old: String, to rawNew: String) {
        let new = rawNew.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return }
        for i in faceLibrary.faces.indices where faceLibrary.faces[i].person == old { faceLibrary.faces[i].person = new }
        for t in tapes.indices {
            for e in tapes[t].events.indices {
                tapes[t].events[e].people = tapes[t].events[e].people.map { $0 == old ? new : $0 }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            }
        }
        faceLibrary.save()
        save()
    }

    /// "That's not them": takes a face away from a person.
    func removeFace(_ id: UUID) {
        guard let i = faceLibrary.faces.firstIndex(where: { $0.id == id }) else { return }
        faceLibrary.faces[i].person = nil
        faceLibrary.save()
        Task { await regroupFaces() }
    }

    func setGroupingThreshold(_ value: Double) {
        faceLibrary.threshold = value
        faceLibrary.save()
        Task { await regroupFaces() }
    }

    /// Adds the names of people seen in each event to its People (typed names are kept).
    private func applyFaceNames() {
        var byEvent: [UUID: Set<String>] = [:]
        for f in faceLibrary.faces { if let p = f.person { byEvent[f.eventID, default: []].insert(p) } }
        for t in tapes.indices {
            for e in tapes[t].events.indices {
                guard let names = byEvent[tapes[t].events[e].id] else { continue }
                for n in names.sorted() where !tapes[t].events[e].people.contains(n) {
                    tapes[t].events[e].people.append(n)
                }
            }
        }
        save()
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
            report(error)
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
            report(error)
        }
    }

    // MARK: Export

    func exportTape(_ tapeID: UUID) {
        Task { await runExport(tapeID) }
    }

    /// Restores (if switched on), makes posters (if switched on) and exports every kept
    /// event of a tape. Returns false if it stopped with an error.
    @discardableResult
    func runExport(_ tapeID: UUID) async -> Bool {
        guard let tape = self.tape(tapeID) else { return false }
        let events = tape.events.filter { $0.status != .discarded }
        let settings = exportSettings
        let exporter = Exporter(settings: settings)
        let restoring = settings.restore.enabled
        let restorer = Restorer(settings: settings.restore, targetHeight: settings.resolution.height)
        if restoring && !RealESRGAN.isInstalled && settings.restore.upscaler == .ai {
            renderStage = "Downloading Real-ESRGAN (\(RealESRGAN.downloadSize))…"
            await ensureRealESRGAN()
        }
        mutateTape(tapeID) { $0.status = .rendering(progress: 0) }
        exportProgress = 0
        defer { exportProgress = nil; renderStage = nil }
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
                var current = self.tape(tapeID)?.events.first { $0.id == event.id } ?? event
                if current.posterEnabled && current.posterImageURL == nil && settings.metadataAndArt {
                    await makeDefaultPoster(tape: tapeID, event: event.id)
                    current = self.tape(tapeID)?.events.first { $0.id == event.id } ?? current
                }
                _ = try await exporter.export(.init(event: current, tape: tape, posterURL: current.posterImageURL,
                                                    restoredURL: master, fanartURL: current.poster?.fanartURL)) { p in
                    Task { @MainActor in report(restoreShare + p * (1 - restoreShare)) }
                }
                mutateTape(tapeID) { t in
                    if let i = t.events.firstIndex(where: { $0.id == event.id }) { t.events[i].status = .rendered }
                }
            }
            mutateTape(tapeID) { $0.status = .done }
            return true
        } catch is CancellationError {
            mutateTape(tapeID) { $0.status = .needsReview }
            return false
        } catch {
            report(error)
            mutateTape(tapeID) { $0.status = .needsReview }
            return false
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
            await ensureRealESRGAN()
            do {
                let url = try await restorer.preview(event, in: tape, at: time) { p in
                    Task { @MainActor [weak self] in self?.previewProgress = p }
                }
                previewURL = url
            } catch is CancellationError {
            } catch {
                report(error)
            }
            previewProgress = nil
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewProgress = nil
    }

    // MARK: Posters

    func restoredMaster(for event: TapeEvent) -> URL? {
        let url = Restorer(settings: exportSettings.restore, targetHeight: exportSettings.resolution.height)
            .masterURL(for: event)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Ranks stills for an event (cached until asked again).
    func loadHeroes(tape tapeID: UUID, event eventID: UUID, force: Bool = false) async {
        guard force || heroCandidates[eventID] == nil, !loadingHeroes.contains(eventID),
              let tape = self.tape(tapeID), let event = tape.events.first(where: { $0.id == eventID }) else { return }
        loadingHeroes.insert(eventID)
        defer { loadingHeroes.remove(eventID) }
        do {
            heroCandidates[eventID] = try await HeroFramePicker().candidates(
                for: event, in: tape, restoredMaster: restoredMaster(for: event)) { _ in }
        } catch {
            report(error)
        }
    }

    func addHeroFrame(tape tapeID: UUID, event eventID: UUID, at time: TimeInterval) async -> HeroCandidate? {
        guard let tape = self.tape(tapeID), let event = tape.events.first(where: { $0.id == eventID }) else { return nil }
        do {
            let c = try await HeroFramePicker().frame(at: time, for: event, in: tape, restoredMaster: restoredMaster(for: event))
            heroCandidates[eventID, default: []].insert(c, at: 0)
            return c
        } catch {
            report(error)
            return nil
        }
    }

    /// A starting poster: best still, warm grade, classic layout, AI tagline.
    func defaultSpec(tape tapeID: UUID, event eventID: UUID) async -> PosterSpec? {
        guard let tape = self.tape(tapeID), let event = tape.events.first(where: { $0.id == eventID }) else { return nil }
        if let existing = event.poster { return existing }
        await loadHeroes(tape: tapeID, event: eventID)
        guard let hero = heroCandidates[eventID]?.first else { return nil }
        return PosterSpec(heroTime: hero.time, heroImage: hero.imageURL, focusX: hero.focusX, focusY: hero.focusY,
                          title: PosterCopy.title(for: event), tagline: await PosterCopy.tagline(for: event),
                          billing: PosterCopy.billing(for: event, tape: tape), dateLine: PosterCopy.dateLine(for: event))
    }

    func savePoster(_ spec: PosterSpec, tape tapeID: UUID, event eventID: UUID) {
        guard let event = tape(tapeID)?.events.first(where: { $0.id == eventID }) else { return }
        do {
            let rendered = try PosterRenderer.render(spec, for: event)
            mutateTape(tapeID) { t in
                if let i = t.events.firstIndex(where: { $0.id == eventID }) {
                    t.events[i].poster = rendered
                    t.events[i].posterEnabled = true
                }
            }
        } catch {
            report(error)
        }
    }

    func makeDefaultPoster(tape tapeID: UUID, event eventID: UUID) async {
        guard let spec = await defaultSpec(tape: tapeID, event: eventID) else { return }
        savePoster(spec, tape: tapeID, event: eventID)
    }

    func checkImagePlayground() async {
        guard imagePlaygroundAvailable == nil else { return }
        imagePlaygroundAvailable = await IllustrationEngine.isAvailable()
    }

    /// Redraws the spec's hero still with Image Playground; returns the spec pointing at it.
    func illustrate(_ spec: PosterSpec, tape tapeID: UUID, event eventID: UUID) async -> PosterSpec? {
        guard spec.drawStyle.isAI, let event = tape(tapeID)?.events.first(where: { $0.id == eventID }),
              let still = HeroFramePicker.loadImage(spec.heroImage) else { return nil }
        illustratingEventID = eventID
        defer { illustratingEventID = nil }
        // Describe the scene, not the people: generators shouldn't guess at names.
        var description = event.summary.isEmpty ? PosterCopy.title(for: event) : event.summary
        if let tags = event.visualTags, !tags.isEmpty { description += " " + tags.prefix(4).joined(separator: ", ") }
        do {
            let url = try await IllustrationEngine.illustrate(still, style: spec.drawStyle, description: description,
                                                              saveIn: HeroFramePicker.folder(for: event))
            var updated = spec
            if let old = spec.illustratedImage, old != url { try? FileManager.default.removeItem(at: old) }
            updated.illustratedImage = url
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    var eventsMissingPosters: [(tape: Tape, event: TapeEvent)] {
        allEvents.filter { $0.event.posterImageURL == nil }
    }

    func generateMissingPosters() {
        let todo = eventsMissingPosters
        guard !todo.isEmpty, posterBatchProgress == nil else { return }
        posterBatchProgress = 0
        Task {
            for (n, item) in todo.enumerated() {
                await makeDefaultPoster(tape: item.tape.id, event: item.event.id)
                posterBatchProgress = Double(n + 1) / Double(todo.count)
            }
            posterBatchProgress = nil
        }
    }

    func installFFmpeg() {
        guard ffmpegInstallProgress == nil else { return }
        ffmpegInstallProgress = 0
        Task {
            do {
                try await FFmpegInstaller.install { p in
                    Task { @MainActor [weak self] in self?.ffmpegInstallProgress = p }
                }
            } catch {
                report(error)
            }
            ffmpegInstallProgress = nil
            checkFFmpeg()
        }
    }

    /// Looks again (e.g. after installing with Homebrew) and starts any waiting work.
    func checkFFmpeg() {
        ffmpegReady = FFmpeg.isInstalled
        if ffmpegReady { runQueue() }
    }

    /// AI upscaling chosen but Real-ESRGAN missing: install it now rather than quietly
    /// falling back to plain upscaling (which barely changes the picture).
    func ensureRealESRGAN() async {
        let r = exportSettings.restore
        guard r.enabled, r.upscaler == .ai, !RealESRGAN.isInstalled, esrganInstallProgress == nil else { return }
        esrganInstallProgress = 0
        defer { esrganInstallProgress = nil }
        do {
            try await RealESRGAN.install { p in
                Task { @MainActor [weak self] in self?.esrganInstallProgress = p }
            }
        } catch {
            report(error)
        }
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
                report(error)
            }
            esrganInstallProgress = nil
        }
    }
}
