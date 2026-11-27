import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Library") {
                Label("All Movies", systemImage: "film.stack")
                    .badge(model.allEvents.count)
                    .tag(SidebarItem.allMovies)
            }
            Section("Tapes") {
                ForEach(model.tapes) { tape in
                    TapeRow(tape: tape)
                        .tag(SidebarItem.tape(tape.id))
                        .contextMenu {
                            Button("Analyze Again") { model.reanalyze(tape.id) }
                            Button("Show Original in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([tape.sourceURL])
                            }
                            Divider()
                            Button("Remove from CineFam", role: .destructive) { model.removeTape(tape.id) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.showImporter = true
            } label: {
                Label("Import Tapes", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(12)
        }
    }
}

private struct TapeRow: View {
    let tape: Tape

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(tape.label).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
    }

    private var subtitle: String {
        switch tape.status {
        case .needsReview: "\(tape.events.count) events · review"
        case .done: "\(tape.events.count) movies"
        default: tape.status.label
        }
    }

    private var icon: String {
        switch tape.status {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .analyzing, .rendering: "gearshape.2"
        default: "recordingtape"
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
