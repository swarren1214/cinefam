import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            Group {
                if !model.ffmpegReady {
                    FFmpegSetupView()
                } else {
                    switch model.selection {
                    case .tape(let id)? where model.tape(id) != nil:
                        TapeReviewView(tapeID: id)
                    case .posterStudio?:
                        PosterStudioView()
                    case .queue?:
                        QueueView()
                    case .people?:
                        PeopleView()
                    default:
                        LibraryView()
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                // Accept now; scan and add on the next turn of the main loop. Doing the work
                // inside the drop callback changed the window mid-layout and crashed AppKit.
                let dropped = urls
                DispatchQueue.main.async { model.importTapes(dropped) }
                return !dropped.isEmpty
            }
            .overlay(alignment: .bottom) {
                if model.importScanning > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for videos…")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(16)
                }
            }
        }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [.movie, .video, .audiovisualContent, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                DispatchQueue.main.async { model.importTapes(urls) }
            }
        }
        .sheet(isPresented: $model.showExport) {
            if let tape = model.selectedTape { ExportSheet(tape: tape) }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    static func isVideo(_ url: URL) -> Bool { MediaFiles.isVideo(url) }
}
