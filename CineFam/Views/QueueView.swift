import AppKit
import SwiftUI

/// Library mode: every tape and where it is, plus what happens without you.
struct QueueView: View {
    @Environment(AppModel.self) private var model

    private var counts: (queued: Int, review: Int, done: Int, failed: Int) {
        var c = (0, 0, 0, 0)
        for t in model.tapes {
            switch t.status {
            case .queued, .analyzing: c.0 += 1
            case .needsReview, .rendering: c.1 += 1
            case .done: c.2 += 1
            case .failed: c.3 += 1
            }
        }
        return c
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Group {
                if model.tapes.isEmpty {
                    ContentUnavailableView {
                        Label("Add a Shoebox of Tapes", systemImage: "shippingbox")
                    } description: {
                        Text("Choose a folder of digitized tapes. CineFam works through them one by one — overnight is fine.")
                    } actions: {
                        Button("Add Tapes or Folder…") { model.showImporter = true }.buttonStyle(.glassProminent)
                    }
                } else {
                    List {
                        ForEach(model.tapes) { tape in
                            QueueRow(tape: tape)
                                .contextMenu {
                                    if tape.status == .queued {
                                        Button("Do This One Next") { model.moveToFront(tape.id) }
                                    }
                                    Button("Open") { model.selection = .tape(tape.id) }
                                    Button("Analyze Again") { model.reanalyze(tape.id) }
                                    Divider()
                                    Button("Remove from CineFam", role: .destructive) { model.removeTape(tape.id) }
                                }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            Form {
                Section("Progress") {
                    LabeledContent("Waiting or analyzing", value: "\(counts.queued)")
                    LabeledContent("Ready for review", value: "\(counts.review)")
                    LabeledContent("Done", value: "\(counts.done)")
                    if counts.failed > 0 {
                        LabeledContent("Couldn't read", value: "\(counts.failed)").foregroundStyle(.red)
                    }
                }
                Section {
                    Toggle("Export without waiting for review", isOn: $model.autoExport)
                    Toggle("Make posters", isOn: $model.autoPosters)
                        .disabled(!model.autoExport)
                    Toggle("Find people", isOn: $model.autoPeople)
                    Toggle("Notify me when it's done", isOn: $model.notifyWhenDone)
                        .onChange(of: model.notifyWhenDone) { if model.notifyWhenDone { Notifier.requestPermission() } }
                } header: {
                    Text("When a tape is analyzed")
                } footer: {
                    Text(model.autoExport
                         ? "Movies are saved with the Export settings (\(model.exportSettings.formats.count) format\(model.exportSettings.formats.count == 1 ? "" : "s"), restoration \(model.exportSettings.restore.enabled ? "on" : "off")). Your Mac stays awake while CineFam works."
                         : "Tapes wait for you to review and export them. Your Mac stays awake while CineFam works.")
                }
                Section {
                    Button("Export Settings…") {
                        if let t = model.tapes.first { model.selection = .tape(t.id); model.showExport = true }
                    }
                    .disabled(model.tapes.isEmpty)
                }
            }
            .formStyle(.grouped)
            .frame(width: 330)
        }
        .navigationTitle("Processing")
        .navigationSubtitle(model.queuePaused ? "Paused" : (model.isQueueRunning ? "Working" : "Idle"))
        .toolbar {
            ToolbarItem {
                Button("Add Tapes or Folder…", systemImage: "plus") { model.showImporter = true }
            }
            ToolbarItem {
                if model.queuePaused {
                    Button("Resume", systemImage: "play.fill") { model.resumeQueue() }
                        .buttonStyle(.glassProminent)
                } else {
                    Button("Pause After This Tape", systemImage: "pause.fill") { model.pauseQueue() }
                        .disabled(!model.isQueueRunning)
                }
            }
            ToolbarItem {
                Button("Stop Now", systemImage: "stop.fill") { model.stopCurrent() }
                    .disabled(!model.isQueueRunning)
                    .help("Stop the current tape; it goes back in the queue")
            }
        }
    }
}

private struct QueueRow: View {
    let tape: Tape

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(tape.label).font(.body.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let p = progress { ProgressView(value: p).controlSize(.small) }
            }
            Spacer()
            if let info = tape.info {
                Text(info.duration.clock).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var progress: Double? {
        switch tape.status {
        case .analyzing(let p), .rendering(let p): p
        default: nil
        }
    }

    private var detail: String {
        switch tape.status {
        case .queued: "Waiting"
        case .analyzing: "Analyzing — dead space, events, dates, names"
        case .needsReview: "\(tape.events.count) events · ready for review"
        case .rendering: "Restoring and saving movies"
        case .done: "\(tape.events.filter { $0.status == .rendered }.count) movies saved"
        case .failed(let m): m
        }
    }

    private var icon: String {
        switch tape.status {
        case .queued: "clock"
        case .analyzing: "waveform.badge.magnifyingglass"
        case .needsReview: "eye"
        case .rendering: "gearshape.2"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch tape.status {
        case .done: .green
        case .failed: .red
        case .needsReview: .orange
        default: .secondary
        }
    }
}
