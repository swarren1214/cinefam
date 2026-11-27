import AppKit
import SwiftUI

/// Name someone once; CineFam finds them across every tape.
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var threshold = 0.55

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if model.faceLibrary.faces.isEmpty {
                    ContentUnavailableView {
                        Label("No Faces Yet", systemImage: "person.2")
                    } description: {
                        Text("CineFam looks for faces when it analyzes a tape. Scan the tapes you already have to start.")
                    } actions: {
                        Button("Scan Library") { model.scanAllFaces() }.buttonStyle(.glassProminent)
                            .disabled(model.tapes.isEmpty)
                    }
                    .frame(maxWidth: .infinity, minHeight: 400)
                }

                if !model.faceLibrary.names.isEmpty {
                    Text("People").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(model.faceLibrary.names, id: \.self) { name in
                            PersonCard(name: name)
                        }
                    }
                }

                if !model.faceGroups.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Who's This?").font(.title2.bold())
                        Text("Faces that look like the same person. Name them and they're added to every movie they're in.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.faceGroups) { group in
                        UnnamedGroupRow(group: group)
                    }
                }

                if !model.unsortedFaces.isEmpty {
                    Text("\(model.unsortedFaces.count) faces seen only once aren't shown.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .navigationTitle("People")
        .navigationSubtitle("\(model.faceLibrary.names.count) named · \(model.faceGroups.count) to name")
        .toolbar {
            ToolbarItem {
                HStack(spacing: 6) {
                    Text("Grouping").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $threshold, in: 0.3...0.9, onEditingChanged: { editing in
                        if !editing { model.setGroupingThreshold(threshold) }
                    })
                    .frame(width: 140)
                    .help("Left: stricter groups (more groups, fewer mistakes). Right: looser.")
                }
            }
            ToolbarItem {
                if let p = model.faceScanProgress {
                    ProgressView(value: p).frame(width: 100)
                } else {
                    Button("Scan Library", systemImage: "person.crop.rectangle.stack") { model.scanAllFaces() }
                }
            }
        }
        .onAppear { threshold = model.faceLibrary.threshold }
    }
}

private struct FaceThumb: View {
    let face: FaceRecord?
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let face, let image = NSImage(contentsOf: face.crop) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

private struct PersonCard: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var editing = false
    @State private var newName = ""

    private var faces: [FaceRecord] { model.faces(of: name) }
    private var movies: Int { Set(faces.map(\.eventID)).count }

    var body: some View {
        VStack(spacing: 8) {
            FaceThumb(face: faces.first, size: 96)
            if editing {
                TextField("Name", text: $newName)
                    .multilineTextAlignment(.center)
                    .onSubmit { model.rename(person: name, to: newName); editing = false }
            } else {
                Text(name).font(.headline)
            }
            Text("\(movies) movie\(movies == 1 ? "" : "s") · \(faces.count) faces")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Movies") {
                    model.libraryPersonFilter = name
                    model.selection = .allMovies
                }
                Menu("More") {
                    Button("Rename…") { newName = name; editing = true }
                    Menu("Not \(name)…") {
                        ForEach(faces.prefix(12)) { f in
                            Button("Face at \(f.time.clock)") { model.removeFace(f.id) }
                        }
                    }
                }
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

private struct UnnamedGroupRow: View {
    @Environment(AppModel.self) private var model
    let group: FaceGroup
    @State private var name = ""

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: -10) {
                ForEach(Array(group.faceIDs.prefix(6)), id: \.self) { id in
                    FaceThumb(face: model.face(id), size: 56)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.faceIDs.count) faces")
                Text("in \(Set(group.faceIDs.compactMap { model.face($0)?.eventID }).count) movies")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Who is this?", text: $name)
                .frame(width: 180)
                .onSubmit { model.name(group, as: name) }
            Button("Name") { model.name(group, as: name) }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            if !model.faceLibrary.names.isEmpty {
                Menu("Add to") {
                    ForEach(model.faceLibrary.names, id: \.self) { n in
                        Button(n) { model.name(group, as: n) }
                    }
                }
                .fixedSize()
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
