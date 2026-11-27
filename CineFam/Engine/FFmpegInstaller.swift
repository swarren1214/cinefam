import CryptoKit
import Foundation

/// Downloads FFmpeg for people who've never opened Terminal.
///
/// Static ffmpeg/ffprobe 6.1.1 builds from the ffmpeg-static project's GitHub releases,
/// checked against pinned SHA-256 hashes before they're unpacked, and installed only for
/// CineFam in Application Support. Checked to include everything CineFam uses (VideoToolbox
/// HEVC/H.264, x264, ProRes, WMV, MP3, libass subtitles, bwdif, normalize, afftdn, loudnorm,
/// scdet, cas…). These builds use FFmpeg's GPL/nonfree options, which is fine for a download
/// the user asks for; a CineFam release that ships FFmpeg inside the app should bundle an
/// LGPL build instead (see README).
enum FFmpegInstaller {
    struct Asset {
        var url: URL
        var sha256: String
        var tool: String
    }

    static let version = "6.1.1"
    private static let base = "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/"

    static var assets: [Asset] {
        #if arch(arm64)
        return [Asset(url: URL(string: base + "ffmpeg-darwin-arm64.gz")!,
               sha256: "8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa", tool: "ffmpeg"),
         Asset(url: URL(string: base + "ffprobe-darwin-arm64.gz")!,
               sha256: "d986a8ec7b030899fe66a8a288ed809a3543338705a3ce178cfb85869c5d80be", tool: "ffprobe")]
        #else
        return [Asset(url: URL(string: base + "ffmpeg-darwin-x64.gz")!,
               sha256: "929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106", tool: "ffmpeg"),
         Asset(url: URL(string: base + "ffprobe-darwin-x64.gz")!,
               sha256: "d4da574d6e2e197bd259b47d69cf262df9e312af24ad960444f6d806d3d4c186", tool: "ffprobe")]
        #endif
    }

    #if arch(arm64)
    static let downloadSize = "38 MB"
    #else
    static let downloadSize = "50 MB"
    #endif

    static var folder: URL { AppModel.supportFolder.appending(path: "Tools/ffmpeg") }

    enum InstallError: LocalizedError {
        case checksum(String), unpack(String)
        var errorDescription: String? {
            switch self {
            case .checksum(let t): "The \(t) download didn't match the expected file, so it wasn't installed. Check your connection and try again."
            case .unpack(let t): "The \(t) download couldn't be unpacked."
            }
        }
    }

    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let list = assets
        for (i, asset) in list.enumerated() {
            let share = 1 / Double(list.count)
            progress(Double(i) * share + 0.05 * share)
            let (gz, _) = try await URLSession.shared.download(from: asset.url)
            defer { try? fm.removeItem(at: gz) }
            progress(Double(i) * share + 0.7 * share)

            let digest = try SHA256Hex.file(gz)
            guard digest == asset.sha256 else { throw InstallError.checksum(asset.tool) }

            // gunzip into a temporary file, then move into place.
            let tmp = folder.appending(path: "\(asset.tool).part")
            try? fm.removeItem(at: tmp)
            fm.createFile(atPath: tmp.path, contents: nil)
            let out = try FileHandle(forWritingTo: tmp)
            let gunzip = Process()
            gunzip.executableURL = URL(filePath: "/usr/bin/gunzip")
            gunzip.arguments = ["-c", gz.path]
            gunzip.standardOutput = out
            try gunzip.run()
            gunzip.waitUntilExit()
            try out.close()
            guard gunzip.terminationStatus == 0 else { throw InstallError.unpack(asset.tool) }

            let dest = folder.appending(path: asset.tool)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            progress(Double(i + 1) * share)
        }
    }

    static func uninstall() { try? FileManager.default.removeItem(at: folder) }
}

enum SHA256Hex {
    /// Hashes a file in 4 MB chunks.
    static func file(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
