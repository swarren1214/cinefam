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
                if !FFmpeg.isInstalled {
                    ContentUnavailableView {
                        Label("FFmpeg Needed", systemImage: "wrench.and.screwdriver")
                    } description: {
                        Text("CineFam uses the free FFmpeg tools to read and write video.\nIn Terminal, run `brew install ffmpeg`, then reopen CineFam.")
                    }
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
                let videos = urls.flatMap { AppModel.videoFiles(in: $0) }
                model.importTapes(videos)
                return !videos.isEmpty
            }
        }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [.movie, .video, .audiovisualContent, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importTapes(urls) }
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

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent)
    }
}
