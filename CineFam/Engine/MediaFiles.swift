import Foundation
import UniformTypeIdentifiers

/// Finding video files, safe to call off the main thread (folders on network drives can be slow).
enum MediaFiles {
    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent)
    }

    /// A video file, or every video inside a folder (and its subfolders), sorted by name.
    /// Unreadable folders and files that vanish mid-scan are skipped rather than failing.
    static func videoFiles(in url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return isVideo(url) ? [url] : [] }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                               errorHandler: { _, _ in true })
        var out: [URL] = []
        while let f = e?.nextObject() as? URL { if isVideo(f) { out.append(f) } }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
