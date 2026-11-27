import AVKit
import SwiftUI

/// Stage 6: review a tape — play it, check the proposed events, fix them, then export.
struct TapeReviewView: View {
    @Environment(AppModel.self) private var model
    let tapeID: UUID

    @State private var player = AVPlayer()
    @State private var currentTime: TimeInterval = 0
    @State private var timeObserver: Any?

    /// What the player shows: the original tape (full quality when macOS can play it, else the
    /// 360p working copy) or the restored version of the selected event.
    enum ViewSource: String, CaseIterable, Identifiable {
        case original = "Original", restored = "Restored"
        var id: Self { self }
    }
    @State private var source: ViewSource = .original
    /// Tape time of the player's 0:00 (an event's start when playing its restored copy).
    @State private var offset: TimeInterval = 0
    @State private var originalPlayable: Bool?

    private var tape: Tape? { model.tape(tapeID) }

    /// Troubleshooting switch: hide parts of this screen without rebuilding, e.g.
    /// `defaults write com.cinefam.CineFam debugHide "player,timeline"` (inspector, toolbar too).
    /// `defaults delete com.cinefam.CineFam debugHide` turns everything back on.
    private let debugHide: Set<String> = Set((UserDefaults.standard.string(forKey: "debugHide") ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })

    var body: some View {
        @Bindable var model = model
        if let tape {
            // A plain side panel rather than .inspector: swapping the inspector's contents
            // while a tape was analyzing sent AppKit into a layout loop and crashed.
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    content(tape)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showInspector && !debugHide.contains("inspector") {
                    Divider()
                    inspector(tape)
                        .frame(width: 330)
                        .frame(maxHeight: .infinity)
                }
            }
            .navigationTitle(tape.label)
            .navigationSubtitle(subtitle(tape))
            .toolbar { if !debugHide.contains("toolbar") { toolbar(tape) } }
            .onAppear { load(tape) }
            .onChange(of: tape.proxyURL) { if let t = self.tape { load(t) } }
            .onChange(of: tapeID) { originalPlayable = nil; if let t = self.tape { load(t) } }
            .onChange(of: source) { if let t = self.tape { reloadPlayer(t, at: currentTime) } }
            .onChange(of: model.selectedEventID) {
                // A restored copy is per event: picking another event loads its copy.
                if source == .restored, let t = self.tape,
                   let e = t.events.first(where: { $0.id == model.selectedEventID }) {
                    reloadPlayer(t, at: e.start)
                }
            }
            .onDisappear { stopObserving() }
            .sheet(isPresented: $model.showRestorePreview) {
                if let id = model.selectedEventID ?? tape.events.first?.id {
                    RestorePreviewSheet(tapeID: tape.id, eventID: id, time: currentTime)
                }
            }
        }
    }

    // MARK: Main area

    @ViewBuilder
    private func content(_ tape: Tape) -> some View {
        switch tape.status {
        case .queued, .analyzing:
            ContentUnavailableView {
                Label("Analyzing \(tape.label)", systemImage: "waveform.badge.magnifyingglass")
            } description: {
                Text("Finding blue screens, static and silence, splitting the tape into events, then reading date stamps, transcribing and naming each one.")
            } actions: {
                if case .analyzing(let p) = tape.status {
                    ProgressView(value: p).frame(width: 240)
                } else {
                    Text("Waiting in the queue").foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Analyze This Tape", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.reanalyze(tape.id) }.buttonStyle(.glassProminent)
            }
        default:
            if case .rendering(let p) = tape.status {
                HStack(spacing: 10) {
                    ProgressView(value: p).frame(width: 200)
                    Text(model.renderStage ?? "Exporting").lineLimit(1)
                    Spacer()
                    Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
            if debugHide.contains("player") {
                Color.black.clipShape(.rect(cornerRadius: 16))
            } else {
                VideoPlayer(player: player)
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay {
                        if source == .restored, restoredMaster(tape) == nil {
                            ZStack {
                                Color.black.opacity(0.8)
                                VStack(spacing: 10) {
                                    Text("No restored copy of this event yet").font(.headline)
                                    Text("Preview Restoration restores 10 seconds to compare. Exporting restores the whole event, and you can watch it here afterwards.")
                                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                                        .frame(maxWidth: 380)
                                    Button("Preview Restoration") {
                                        if let id = model.selectedEventID {
                                            model.previewRestoration(tape: tape.id, event: id, at: currentTime)
                                        }
                                    }
                                }
                                .foregroundStyle(.white)
                            }
                            .clipShape(.rect(cornerRadius: 16))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Text(sourceLabel(tape))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: .capsule)
                            .padding(12)
                    }
                    .overlay(alignment: .topLeading) {
                        if let e = event(at: currentTime, in: tape) {
                            // No glass here: glass samples what's behind it, which is
                            // AVKit's AppKit view.
                            Text(e.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.black.opacity(0.55), in: .capsule)
                                .padding(12)
                        }
                    }
            }
            if !debugHide.contains("timeline") {
                TapeTimeline(tape: tape, currentTime: currentTime,
                             selectedEventID: model.selectedEventID) { event in
                    model.selectedEventID = event.id
                    seek(to: event.start)
                } onSeek: { time in
                    seek(to: time)
                }
                .frame(height: 96)
            }
            if tape.events.isEmpty {
                Text("No events found on this tape.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func inspector(_ tape: Tape) -> some View {
        if let id = model.selectedEventID ?? tape.events.first?.id,
           let binding = model.binding(tape: tape.id, event: id) {
            EventInspector(event: binding, tapeID: tape.id, currentTime: currentTime)
        } else {
            ContentUnavailableView("No Event Selected", systemImage: "film",
                                   description: Text("Pick an event on the timeline."))
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ tape: Tape) -> some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: $source) {
                ForEach(ViewSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Watch the original tape, or the restored version of the selected event")
            .disabled(tape.events.isEmpty)
        }
        ToolbarItemGroup {
            Button("Previous Event", systemImage: "chevron.backward") { step(-1, in: tape) }
            Button("Next Event", systemImage: "chevron.forward") { step(1, in: tape) }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button("Preview Restoration", systemImage: "wand.and.sparkles") {
                if let id = model.selectedEventID ?? tape.events.first?.id {
                    model.previewRestoration(tape: tape.id, event: id, at: currentTime)
                }
            }
            .disabled(tape.events.isEmpty || tape.status.isBusy)
            .help("Restore 10 seconds from the playhead and compare it with the original")
        }
        ToolbarItem {
            Button("Approve & Export…", systemImage: "square.and.arrow.up") {
                model.selection = .tape(tape.id)
                model.showExport = true
            }
            .buttonStyle(.glassProminent)
            .disabled(tape.events.isEmpty || tape.status.isBusy)
        }
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.trailing") { model.showInspector.toggle() }
        }
    }

    private func subtitle(_ tape: Tape) -> String {
        var parts: [String] = []
        if let info = tape.info { parts.append(info.duration.clock) }
        parts.append("\(tape.events.count) events")
        if tape.deadDuration > 0 { parts.append("\(tape.deadDuration.friendlyLength) dead space") }
        // Kept steady while work runs: a title bar that changes many times a second makes
        // the window re-lay-out its toolbar constantly. Progress shows in the page instead.
        if tape.status.isBusy { parts.append(tape.status.isRendering ? "Exporting" : "Analyzing") }
        return parts.joined(separator: " · ")
    }

    // MARK: Playback

    private func load(_ tape: Tape) {
        if model.selectedEventID == nil || !tape.events.contains(where: { $0.id == model.selectedEventID }) {
            model.selectedEventID = tape.events.first?.id
        }
        let start = tape.events.first(where: { $0.id == model.selectedEventID })?.start ?? 0
        Task {
            if originalPlayable == nil {
                // AVFoundation plays MOV/MP4/DV; AVI, MKV and some captures need the working copy.
                originalPlayable = (try? await AVURLAsset(url: tape.sourceURL).load(.isPlayable)) ?? false
            }
            reloadPlayer(tape, at: start)
        }
    }

    private func restoredMaster(_ tape: Tape) -> URL? {
        guard let e = tape.events.first(where: { $0.id == model.selectedEventID }) else { return nil }
        return model.restoredMaster(for: e)
    }

    private func sourceLabel(_ tape: Tape) -> String {
        if source == .restored, restoredMaster(tape) != nil {
            let h = model.exportSettings.resolution.height.map { "\($0)p" } ?? "original size"
            return "Restored · \(h)"
        }
        if originalPlayable == true, let info = tape.info { return "Original · \(info.height)p" }
        return "Working copy · 360p"
    }

    private func reloadPlayer(_ tape: Tape, at time: TimeInterval) {
        stopObserving()
        var url: URL?
        var newOffset: TimeInterval = 0
        if source == .restored, let e = tape.events.first(where: { $0.id == model.selectedEventID }),
           let master = model.restoredMaster(for: e) {
            url = master
            newOffset = e.start
        } else if originalPlayable == true {
            url = tape.sourceURL
        } else {
            url = tape.proxyURL ?? (tape.info != nil ? tape.sourceURL : nil)
        }
        guard let url else { return }
        if (player.currentItem?.asset as? AVURLAsset)?.url != url {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        offset = newOffset
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { t in
            currentTime = t.seconds + newOffset
        }
        seek(to: time)
    }

    private func stopObserving() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, time - offset), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    private func event(at time: TimeInterval, in tape: Tape) -> TapeEvent? {
        tape.events.first { time >= $0.start && time < $0.end && $0.status != .discarded }
    }

    private func step(_ delta: Int, in tape: Tape) {
        guard !tape.events.isEmpty else { return }
        let i = tape.events.firstIndex { $0.id == model.selectedEventID } ?? 0
        let next = tape.events[max(0, min(tape.events.count - 1, i + delta))]
        model.selectedEventID = next.id
        seek(to: next.start)
    }
}

/// The tape at a glance: events, dead space, subtitle coverage and the playhead.
struct TapeTimeline: View {
    let tape: Tape
    let currentTime: TimeInterval
    let selectedEventID: UUID?
    var onSelect: (TapeEvent) -> Void
    var onSeek: (TimeInterval) -> Void

    private var duration: TimeInterval { max(tape.info?.duration ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("0:00")
                Spacer()
                Text((duration / 2).clock)
                Spacer()
                Text(duration.clock)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
                        .contentShape(.rect)
                        .onTapGesture { location in onSeek(location.x / w * duration) }

                    ForEach(tape.deadRanges) { r in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.gray.opacity(0.35))
                            .overlay(Stripes().stroke(.white.opacity(0.12), lineWidth: 3))
                            .clipShape(.rect(cornerRadius: 6))
                            .frame(width: max(2, (r.end - r.start) / duration * w), height: 44)
                            .offset(x: r.start / duration * w)
                            .help("\(r.reasons.map(\.title).sorted().joined(separator: " + ")) · \(r.duration.clock)")
                    }

                    ForEach(tape.events) { e in
                        let selected = e.id == selectedEventID
                        Button { onSelect(e) } label: {
                            Text(e.title)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .frame(width: max(4, (e.end - e.start) / duration * w), height: 44, alignment: .leading)
                                .background(selected ? Color.orange : Color.blue.opacity(e.status == .discarded ? 0.12 : 0.4),
                                            in: .rect(cornerRadius: 6))
                                .overlay {
                                    if e.confidence < 0.5 {
                                        RoundedRectangle(cornerRadius: 6).strokeBorder(.yellow, style: .init(lineWidth: 1, dash: [3]))
                                    }
                                }
                                .foregroundStyle(selected ? Color.black : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .offset(x: e.start / duration * w)
                    }

                    // Subtitle cues.
                    ForEach(tape.events) { e in
                        ForEach(Array(e.words.enumerated()), id: \.offset) { _, word in
                            Rectangle().fill(.white.opacity(0.45))
                                .frame(width: max(1, (word.end - word.start) / duration * w), height: 6)
                                .offset(x: word.start / duration * w, y: 52)
                        }
                    }

                    Capsule().fill(.white)
                        .frame(width: 2, height: 64)
                        .offset(x: min(w - 2, currentTime / duration * w), y: -4)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// Diagonal hatching for dead space.
private struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += 8
        }
        return p
    }
}
