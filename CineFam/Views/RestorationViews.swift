import Combine
import AVKit
import SwiftUI

/// Restoration choices, shared by the Export sheet and the preview window.
struct RestorationSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let r = $model.exportSettings.restore
        Section {
            Toggle("Restore and upscale", isOn: r.enabled)
            if model.exportSettings.restore.enabled {
                Picker("Upscaler", selection: r.upscaler) {
                    ForEach(RestoreSettings.Upscaler.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.exportSettings.restore.upscaler == .ai {
                    ESRGANStatusRow()
                    Picker("AI model", selection: r.model) {
                        ForEach(RestoreSettings.AIModel.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("AI strength") {
                        HStack {
                            Slider(value: r.strength, in: 0.2...1.0, step: 0.1)
                            Text("\(Int(model.exportSettings.restore.strength * 100))%")
                                .monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Picker("Noise reduction", selection: r.denoise) {
                    ForEach(RestoreSettings.Denoise.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Smooth motion (60 fps)", isOn: r.smoothMotion)
                Toggle("Steady shaky footage", isOn: r.stabilize)
                Toggle("Fix color and brightness", isOn: r.autoColor)
                Toggle("Trim noisy tape edges", isOn: r.cleanEdges)
                Toggle("Clean up audio", isOn: r.cleanAudio)
            }
        } header: {
            Text("Restoration")
        } footer: {
            if model.exportSettings.restore.enabled {
                Text("Lower AI strength keeps faces natural. Smooth motion doubles render time. Restored copies are kept, so exporting more formats later is quick.")
            }
        }
    }
}

struct ESRGANStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if RealESRGAN.isInstalled {
            LabeledContent("Real-ESRGAN") {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else if let p = model.esrganInstallProgress {
            LabeledContent("Real-ESRGAN") { ProgressView(value: p).frame(width: 140) }
        } else {
            LabeledContent {
                Button("Download (\(RealESRGAN.downloadSize))") { model.installRealESRGAN() }
            } label: {
                Text("Real-ESRGAN")
                Text("Free, open-source AI upscaler. Until it's installed, Standard upscaling is used.")
            }
        }
    }
}

/// Plays a 10-second before/after comparison with a draggable split, and lets you adjust settings.
struct RestorePreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tapeID: UUID
    let eventID: UUID
    let time: TimeInterval

    @State private var player = AVPlayer()
    /// Width ÷ height of one half of the side-by-side preview clip.
    @State private var aspect: CGFloat = 4 / 3

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let url = model.previewURL {
                        // The clip holds original | restored side by side, so one player drives
                        // both sides of the split and they can never drift apart.
                        SplitCompareView(original: player, restored: player, aspect: aspect,
                                         originalRect: SplitCompareView.leftHalf,
                                         restoredRect: SplitCompareView.rightHalf)
                            .onAppear { play(url) }
                            .onChange(of: url) { play(url) }
                    } else if let p = model.previewProgress {
                        VStack(spacing: 10) {
                            ProgressView(value: p).frame(width: 260)
                            Text("Restoring 10 seconds…").foregroundStyle(.secondary)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { n in
                    // Loop the 10 seconds.
                    guard (n.object as? AVPlayerItem) === player.currentItem else { return }
                    player.seek(to: .zero)
                    player.play()
                }
                Form { RestorationSettingsSection() }
                    .formStyle(.grouped)
                    .frame(width: 340)
            }
            HStack {
                Text("Drag the line to compare the same moment before and after. Change settings, then update.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { model.cancelPreview(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Update Preview") {
                    model.previewRestoration(tape: tapeID, event: eventID, at: time)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.previewProgress != nil)
            }
            .padding(14)
        }
        .frame(minWidth: 1100, minHeight: 620)
    }

    private func play(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        Task {
            if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), size.height > 0 {
                aspect = size.width / 2 / size.height
            }
        }
    }
}
