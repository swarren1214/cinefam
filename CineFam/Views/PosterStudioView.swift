import AppKit
import SwiftUI

/// Phase 5: pick a still, a look and a layout, and save a movie poster for each event.
struct PosterStudioView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var spec: PosterSpec?
    @State private var graded: CGImage?
    @State private var showFanart = false
    @State private var working = false
    @State private var pickTime = ""

    private var items: [(tape: Tape, event: TapeEvent)] { model.allEvents }
    private var current: (tape: Tape, event: TapeEvent)? { items.first { $0.event.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            eventList
                .frame(width: 260)
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspector
                .frame(width: 340)
        }
        .navigationTitle("Poster Studio")
        .navigationSubtitle("\(items.count - model.eventsMissingPosters.count) of \(items.count) posters done")
        .toolbar {
            ToolbarItem {
                if let p = model.posterBatchProgress {
                    ProgressView(value: p).frame(width: 120)
                } else {
                    Button("Generate Missing (\(model.eventsMissingPosters.count))", systemImage: "sparkles.rectangle.stack") {
                        model.generateMissingPosters()
                    }
                    .disabled(model.eventsMissingPosters.isEmpty)
                }
            }
            ToolbarItem {
                Button("Save Poster", systemImage: "checkmark") { save() }
                    .buttonStyle(.glassProminent)
                    .disabled(spec == nil || current == nil)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear { if selection == nil { selection = model.selectedEventID ?? items.first?.event.id } }
        .task(id: selection) { await loadSpec() }
        .onChange(of: spec?.heroImage) { regrade() }
        .onChange(of: spec?.grade) { regrade() }
        .onChange(of: spec?.style) { regrade() }
        .onChange(of: spec?.styleStrength) { regrade() }
        .onChange(of: spec?.illustratedImage) { regrade() }
        .task { await model.checkImagePlayground() }
    }

    // MARK: Columns

    private var eventList: some View {
        List(selection: $selection) {
            ForEach(model.tapes) { tape in
                let events = tape.events.filter { $0.status != .discarded }
                if !events.isEmpty {
                    Section(tape.label) {
                        ForEach(events) { e in
                            HStack(spacing: 10) {
                                Thumb(url: e.posterImageURL, renderedAt: e.poster?.renderedAt)
                                    .frame(width: 36, height: 54)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title).lineLimit(1)
                                    Text(e.posterImageURL == nil ? "No poster" : "Poster saved")
                                        .font(.caption)
                                        .foregroundStyle(e.posterImageURL == nil ? Color.secondary : Color.green)
                                }
                            }
                            .tag(e.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var preview: some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                if let spec {
                    let size = showFanart ? FanartCanvas.size : PosterCanvas.size
                    let scale = min(geo.size.width / size.width, geo.size.height / size.height) * 0.92
                    Group {
                        if showFanart {
                            FanartCanvas(spec: spec, image: graded)
                        } else {
                            PosterCanvas(spec: spec, image: graded)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                } else if let c = current, model.loadingHeroes.contains(c.event.id) || working {
                    ProgressView("Finding the best frames…")
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ContentUnavailableView("Pick an Event", systemImage: "rectangle.portrait.on.rectangle.portrait",
                                           description: Text("Choose an event to design its poster."))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            Picker("Show", selection: $showFanart) {
                Text("Poster 2:3").tag(false)
                Text("Backdrop 16:9").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .padding(.bottom, 16)
        }
        .background(RadialGradient(colors: [Color(red: 0.23, green: 0.14, blue: 0.09), Color(white: 0.11)],
                                   center: .init(x: 0.5, y: 0.4), startRadius: 0, endRadius: 700))
    }

    @ViewBuilder
    private var inspector: some View {
        if let c = current, spec != nil {
            let binding = Binding(get: { spec! }, set: { spec = $0 })
            Form {
                Section("Hero Frame") {
                    let heroes = model.heroCandidates[c.event.id] ?? []
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(heroes) { h in
                            Button { choose(h) } label: {
                                Thumb(url: h.imageURL, renderedAt: nil, aspect: 4 / 3)
                                    .overlay(alignment: .bottomLeading) {
                                        Text("\(Int(h.score * 100))")
                                            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                            .padding(4)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(h.imageURL == spec?.heroImage ? Color.orange : .clear, lineWidth: 2)
                                    }
                            }
                            .buttonStyle(.plain)
                            .help("At \(h.time.clock)\(h.faces > 0 ? " · \(h.faces) face\(h.faces == 1 ? "" : "s")" : "")")
                        }
                    }
                    HStack {
                        TextField("Time", text: $pickTime, prompt: Text("e.g. \(c.event.start.clock)"))
                            .frame(width: 110)
                        Button("Use Frame at Time") { Task { await useTime(c) } }
                            .disabled(parse(pickTime) == nil)
                        Spacer()
                        Button("Find Again") { Task { await model.loadHeroes(tape: c.tape.id, event: c.event.id, force: true) } }
                    }
                }

                Section {
                    Picker("Style", selection: Binding(get: { spec?.drawStyle ?? .photo },
                                                       set: { spec?.style = $0 })) {
                        Text(PosterStyle.photo.title).tag(PosterStyle.photo)
                        Section("Drawn on this Mac") {
                            ForEach(PosterStyle.filterStyles) { Text($0.title).tag($0) }
                        }
                        Section("Image Playground") {
                            ForEach(PosterStyle.aiStyles) { Text($0.title).tag($0) }
                        }
                    }
                    if spec?.drawStyle.isFilter == true {
                        LabeledContent("Strength") {
                            HStack {
                                Slider(value: Binding(get: { spec?.strength ?? 0.85 },
                                                      set: { spec?.styleStrength = $0 }), in: 0.3...1)
                                Text("\(Int((spec?.strength ?? 0.85) * 100))%")
                                    .monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                    if spec?.drawStyle.isAI == true {
                        illustrationRow(c)
                    }
                } header: {
                    Text("Style")
                } footer: {
                    if spec?.drawStyle.isAI == true {
                        Text("Image Playground redraws the frame on this Mac. Faces become a likeness, not the real person — use a Drawn style to keep real faces.")
                    } else if spec?.drawStyle.isFilter == true {
                        Text("Drawn styles keep every face as filmed. Lower strength mixes in more of the photo.")
                    }
                }

                Section("Look") {
                    Picker("Color grade", selection: binding.grade) {
                        ForEach(PosterGrade.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Template", selection: binding.template) {
                        ForEach(PosterTemplate.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Accent", selection: binding.accent) {
                        ForEach(PosterAccent.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }

                Section("Words") {
                    TextField("Title", text: binding.title)
                    HStack {
                        TextField("Tagline", text: binding.tagline)
                        Button("New", systemImage: "sparkles") {
                            Task { spec?.tagline = await PosterCopy.tagline(for: c.event) }
                        }
                        .labelStyle(.iconOnly)
                        .help("Suggest a new tagline")
                    }
                    TextField("Top line", text: binding.kicker)
                    TextField("Date", text: binding.dateLine)
                    LabeledContent("Credits") {
                        TextEditor(text: binding.billing)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(height: 60)
                    }
                }

                if let url = c.event.posterImageURL {
                    Section {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Poster Yet", systemImage: "paintbrush")
        }
    }

    @ViewBuilder
    private func illustrationRow(_ c: (tape: Tape, event: TapeEvent)) -> some View {
        if model.imagePlaygroundAvailable == false {
            Label("Image Playground needs Apple Intelligence turned on.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else if model.illustratingEventID == c.event.id {
            HStack {
                ProgressView().controlSize(.small)
                Text("Drawing…").foregroundStyle(.secondary)
            }
        } else {
            Button(spec?.usesIllustration == true ? "Draw Again" : "Draw with Image Playground",
                   systemImage: "paintbrush.pointed") {
                guard let s = spec else { return }
                Task {
                    if let updated = await model.illustrate(s, tape: c.tape.id, event: c.event.id) { spec = updated }
                }
            }
        }
    }

    // MARK: Actions

    private func loadSpec() async {
        spec = nil
        graded = nil
        guard let c = current else { return }
        working = true
        defer { working = false }
        await model.loadHeroes(tape: c.tape.id, event: c.event.id)
        // Switched to another event while frames were loading: that event's task takes over.
        guard !Task.isCancelled else { return }
        let made = await model.defaultSpec(tape: c.tape.id, event: c.event.id)
        guard !Task.isCancelled, selection == c.event.id else { return }
        spec = made
        regrade()
    }

    private func regrade() {
        guard let spec else { graded = nil; return }
        let s = spec
        Task.detached(priority: .userInitiated) {
            let image = PosterRenderer.gradedImage(s)
            await MainActor.run { graded = image }
        }
    }

    private func choose(_ h: HeroCandidate) {
        spec?.illustratedImage = nil      // an illustration of the old frame no longer fits
        spec?.heroImage = h.imageURL
        spec?.heroTime = h.time
        spec?.focusX = h.focusX
        spec?.focusY = h.focusY
    }

    private func useTime(_ c: (tape: Tape, event: TapeEvent)) async {
        guard let t = parse(pickTime) else { return }
        let time = min(max(t, c.event.start), c.event.end)
        if let h = await model.addHeroFrame(tape: c.tape.id, event: c.event.id, at: time) { choose(h) }
    }

    /// "42:18" or "1:02:03" (tape time) or plain seconds.
    private func parse(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private func save() {
        guard let spec, let c = current else { return }
        model.savePoster(spec, tape: c.tape.id, event: c.event.id)
    }
}

/// A small image loaded from disk, refreshed when `renderedAt` changes.
struct Thumb: View {
    let url: URL?
    let renderedAt: Date?
    var aspect: CGFloat = 2 / 3

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.5), style: .init(lineWidth: 1, dash: [3]))
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 6))
        .id(renderedAt)
    }
}
