import SwiftUI

/// Title, date, people and output options for one event.
struct EventInspector: View {
    @Environment(AppModel.self) private var model
    @Binding var event: TapeEvent
    let tapeID: UUID
    let currentTime: TimeInterval

    @State private var transcribing = false
    @State private var peopleText = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Event", value: "\(event.index) · \(event.start.clock)–\(event.end.clock)")
                LabeledContent("Length", value: event.duration.friendlyLength)
                LabeledContent("Shots", value: "\(event.shots.count)")
                if event.quiet {
                    Label("Mostly silent — check it's worth keeping", systemImage: "speaker.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                TextField("Title", text: $event.title)
                Toggle("Date known", isOn: Binding(
                    get: { event.date != nil },
                    set: { known in
                        event.date = known ? (event.date ?? Self.defaultDate) : nil
                        event.dateSource = known ? .manual : .unknown
                        event.datePrecision = known ? .day : nil
                    }))
                if event.date != nil {
                    DatePicker("Date", selection: Binding(
                        get: { event.date ?? Self.defaultDate },
                        set: { event.date = $0; event.dateSource = .manual }),
                               displayedComponents: event.precision == .exact ? DatePickerComponents([.date, .hourAndMinute]) : .date)
                    Picker("Known to", selection: Binding(
                        get: { event.precision },
                        set: { event.datePrecision = $0; event.dateSource = .manual })) {
                        ForEach(DatePrecision.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Picker("Source", selection: $event.dateSource) {
                    ForEach(DateSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("People", text: $peopleText, prompt: Text("Mom, Grandpa"))
                    .onSubmit { savePeople() }
                TextField("Summary", text: $event.summary, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section {
                if let tags = event.visualTags, !tags.isEmpty {
                    LabeledContent("Seen", value: tags.prefix(5).joined(separator: ", "))
                }
                if let faces = event.faceCount, faces > 0 {
                    LabeledContent("Faces", value: "Up to \(faces) at once")
                }
                HStack {
                    Text(EventNamer.isModelAvailable ? "Apple Intelligence on this Mac"
                                                     : "Simple naming (Apple Intelligence is off)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.enrichingEventID == event.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Suggest Title & Date", systemImage: "sparkles") {
                            Task { await model.enrich(tape: tapeID, event: event.id) }
                        }
                    }
                }
            } header: {
                Text("AI")
            }

            Section("Movie File") {
                Toggle("Subtitles", isOn: $event.subtitlesEnabled)
                if event.subtitlesEnabled {
                    HStack {
                        Text(event.words.isEmpty ? "Not transcribed yet" : "\(event.words.count) words transcribed")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if transcribing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(event.words.isEmpty ? "Transcribe" : "Redo") {
                                transcribing = true
                                Task {
                                    await model.transcribe(tape: tapeID, event: event.id)
                                    transcribing = false
                                }
                            }
                        }
                    }
                }
                Toggle("Chapters (\(event.chapters.count) scenes)", isOn: $event.chaptersEnabled)
                Toggle("Poster", isOn: $event.posterEnabled)
            }

            Section {
                HStack {
                    Button("Split at Playhead", systemImage: "scissors") {
                        model.split(tape: tapeID, event: event.id, at: currentTime)
                    }
                    .disabled(!(currentTime > event.start + 1 && currentTime < event.end - 1))
                    Button("Merge with Next", systemImage: "arrow.right.to.line") {
                        model.mergeWithNext(tape: tapeID, event: event.id)
                    }
                }
                Button(event.status == .discarded ? "Keep This Event" : "Discard Event",
                       systemImage: event.status == .discarded ? "arrow.uturn.backward" : "trash",
                       role: event.status == .discarded ? nil : ButtonRole.destructive) {
                    event.status = event.status == .discarded ? .proposed : .discarded
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { peopleText = event.people.joined(separator: ", ") }
        .onChange(of: event.id) { peopleText = event.people.joined(separator: ", ") }
        .onDisappear { savePeople() }
    }

    private func savePeople() {
        event.people = peopleText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static let defaultDate = Calendar.current.date(from: DateComponents(year: 1995, month: 1, day: 1)) ?? .now
}
