import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Choose formats, subtitles and where the movies go.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tape: Tape

    @State private var choosingFolder = false

    private var events: [TapeEvent] { tape.events.filter { $0.status != .discarded } }

    var body: some View {
        @Bindable var model = model
        let s = $model.exportSettings
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(ExportFormat.allCases.filter { !$0.isWindows }) { formatToggle($0) }
                } header: {
                    Text("Formats")
                }
                Section {
                    ForEach(ExportFormat.allCases.filter(\.isWindows)) { formatToggle($0) }
                } header: {
                    Label("Windows", systemImage: "pc")
                } footer: {
                    Text("WMV and AVI can't hold selectable subtitles or chapters, so subtitles are saved as an .srt file (or burned in).")
                }

                Section("Video") {
                    Picker("Quality", selection: s.quality) {
                        ForEach(ExportFormat.Quality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Resolution", selection: s.resolution) {
                        ForEach(ExportResolution.allCases) { Text($0.title).tag($0) }
                    }
                }

                RestorationSettingsSection()

                Section("Subtitles") {
                    Toggle("Embed selectable subtitles", isOn: s.embedSubtitles)
                    Toggle("Also save an .srt file", isOn: s.sidecarSRT)
                    Toggle("Burn into the video", isOn: s.burnInSubtitles)
                }

                Section("Extras") {
                    Toggle("Chapters from scenes", isOn: s.chapters)
                    Toggle("Poster, artwork and movie info", isOn: s.metadataAndArt)
                }

                Section("Location") {
                    LabeledContent("Save to") {
                        Button(model.exportSettings.destination.lastPathComponent) { choosingFolder = true }
                    }
                    Picker("Organize as", selection: s.layout) {
                        ForEach(FolderLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let first = events.first {
                        Text(preview(first))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("\(events.count) movies × \(model.exportSettings.formats.count) formats")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") {
                    model.exportTape(tape.id)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.exportSettings.formats.isEmpty || events.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 580, height: 760)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.exportSettings.destination = url }
        }
    }

    private func formatToggle(_ f: ExportFormat) -> some View {
        Toggle(isOn: Binding(
            get: { model.exportSettings.formats.contains(f) },
            set: { on in
                if on { model.exportSettings.formats.insert(f) } else { model.exportSettings.formats.remove(f) }
            })) {
            VStack(alignment: .leading) {
                Text(f.title)
                Text(f.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func preview(_ e: TapeEvent) -> String {
        let s = model.exportSettings
        let folder = ExportNaming.folder(e, tapeLabel: tape.label, layout: s.layout)
        let base = ExportNaming.baseName(e, tapeLabel: tape.label, layout: s.layout)
        var lines = ["\(folder)/"]
        for f in ExportFormat.allCases where s.formats.contains(f) {
            lines.append("  \(base)\(f.nameSuffix).\(f.fileExtension)")
        }
        if s.sidecarSRT { lines.append("  \(base).en.srt") }
        lines.append("  \(base).json")
        return lines.joined(separator: "\n")
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var restoredBytes: Int64 = 0

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Analysis") {
                Toggle("Transcribe speech for subtitles", isOn: $model.autoTranscribe)
                Toggle("Suggest titles and summaries", isOn: $model.aiNaming)
                LabeledContent("Apple Intelligence",
                               value: EventNamer.isModelAvailable ? "Available" : "Off — simple titles are used")
            }
            LabeledContent("FFmpeg") {
                if let url = FFmpeg.url(for: "ffmpeg") {
                    Text(url.path).textSelection(.enabled)
                } else {
                    Text("Not found — run `brew install ffmpeg`").foregroundStyle(.red)
                }
            }
            Section("Restoration") {
                ESRGANStatusRow()
                LabeledContent("Restored copies") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: restoredBytes, countStyle: .file))
                        Button("Delete") { Restorer.deleteAll(); restoredBytes = Restorer.diskUsage() }
                            .disabled(restoredBytes == 0)
                    }
                }
            }
            LabeledContent("Library") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.supportFolder])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear { restoredBytes = Restorer.diskUsage() }
    }
}
