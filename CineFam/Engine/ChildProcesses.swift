import AppKit

/// Every ffmpeg / Real-ESRGAN process CineFam starts, so none outlive the app.
/// Child processes keep running after their parent quits or crashes — an orphaned Real-ESRGAN
/// keeps the GPU at full load with nothing waiting for its output.
enum ChildProcesses {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var running: [ObjectIdentifier: Process] = [:]
    }
    private static let registry = Registry()

    static func add(_ p: Process) {
        registry.lock.lock(); defer { registry.lock.unlock() }
        registry.running[ObjectIdentifier(p)] = p
    }

    static func remove(_ p: Process) {
        registry.lock.lock(); defer { registry.lock.unlock() }
        registry.running[ObjectIdentifier(p)] = nil
    }

    /// Called when the app quits.
    static func terminateAll() {
        registry.lock.lock()
        let all = Array(registry.running.values)
        registry.lock.unlock()
        for p in all where p.isRunning { p.terminate() }
    }

    /// Called at launch: stops copies of CineFam's own tools left behind by a crash or force
    /// quit (orphans, re-parented to launchd). Never touches a Homebrew ffmpeg you run yourself.
    static func killOrphans() {
        var tools = [RealESRGAN.executable.path,
                     FFmpegInstaller.folder.appending(path: "ffmpeg").path]
        if let res = Bundle.main.resourceURL { tools.append(res.appending(path: "bin/ffmpeg").path) }
        for path in tools {
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/pkill")
            // -P 1: only processes whose parent is launchd, i.e. left behind.
            p.arguments = ["-P", "1", "-f", NSRegularExpression.escapedPattern(for: path)]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }
}
