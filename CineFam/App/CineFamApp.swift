import SwiftUI

@main
struct CineFamApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Tapes…") { model.showImporter = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .importExport) {
                Button("Export Movies…") { model.showExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selectedTape == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
