import SwiftUI

/// First-run setup: installs FFmpeg with one click (no Terminal).
struct FFmpegSetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            Text("One Quick Setup Step")
                .font(.title.bold())
            Text("CineFam uses FFmpeg, a free video toolkit trusted by millions of apps, to read your tapes and save your movies. It's about \(FFmpegInstaller.downloadSize) and is installed just for CineFam.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)

            if let p = model.ffmpegInstallProgress {
                VStack(spacing: 8) {
                    ProgressView(value: p).frame(width: 260)
                    Text(p < 0.95 ? "Downloading…" : "Finishing up…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } else {
                Button {
                    model.installFFmpeg()
                } label: {
                    Label("Install FFmpeg", systemImage: "arrow.down.circle")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 6)
            }

            VStack(spacing: 4) {
                Text("Already installed FFmpeg yourself (for example with Homebrew)?")
                Button("Check Again") { model.checkFFmpeg() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
