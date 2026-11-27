import AppKit
import SwiftUI

/// Every kept event across all tapes, as a poster wall grouped by year.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var filtered: [(tape: Tape, event: TapeEvent)] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.allEvents }
        return model.allEvents.filter { item in
            let e = item.event
            let words = e.words.map(\.text).joined(separator: " ")
            return [e.title, e.summary, e.people.joined(separator: " "), item.tape.label, words]
                .contains { $0.lowercased().contains(q) }
        }
    }

    private var byYear: [(String, [(tape: Tape, event: TapeEvent)])] {
        Dictionary(grouping: filtered) { $0.event.year.map { String($0) } ?? "Undated" }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        Group {
            if model.tapes.isEmpty {
                ContentUnavailableView {
                    Label("Import Your First Tape", systemImage: "recordingtape")
                } description: {
                    Text("Drop digitized tapes here (MOV, AVI, DV, MP4). CineFam finds the dead space, splits each tape into events and turns them into movies.")
                } actions: {
                    Button("Import Tapes…") { model.showImporter = true }
                        .buttonStyle(.glassProminent)
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(byYear, id: \.0) { year, items in
                            Text(year).font(.title2.bold())
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 18)],
                                      alignment: .leading, spacing: 20) {
                                ForEach(items, id: \.event.id) { item in
                                    Button {
                                        model.selectedEventID = item.event.id
                                        model.selection = .tape(item.tape.id)
                                    } label: {
                                        PosterCard(event: item.event)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("All Movies")
        .navigationSubtitle("\(model.allEvents.count) movies from \(model.tapes.count) tapes")
        .searchable(text: $search, prompt: "Titles, people, what was said")
    }
}

struct PosterCard: View {
    let event: TapeEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let url = event.posterImageURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(2 / 3, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 10))
                        .id(event.poster?.renderedAt)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: Self.palette(for: event.title),
                                             startPoint: .top, endPoint: .bottom))
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .overlay(alignment: .bottomLeading) {
                            Text(event.title)
                                .font(.system(size: 20, weight: .heavy))
                                .foregroundStyle(.white)
                                .lineLimit(3)
                                .padding(10)
                        }
                }
            }
                .overlay(alignment: .topTrailing) {
                    if event.status == .rendered {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .green)
                            .padding(8)
                    }
                }
            Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
            Text([event.dateText ?? "Undated", event.duration.friendlyLength].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Stand-in art for events without a poster yet.
    static func palette(for title: String) -> [Color] {
        let sets: [[Color]] = [
            [.indigo, .orange], [.teal, .blue], [.orange, .brown], [.purple, .pink], [.blue, .black],
        ]
        let n = title.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 997 }
        return sets[n % sets.count]
    }
}
