import Foundation

enum FFmpegError: LocalizedError {
    case notInstalled
    case failed(tool: String, code: Int32, log: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "FFmpeg wasn't found. Install it with `brew install ffmpeg`, then try again."
        case .failed(let tool, let code, let log):
            "\(tool) exited with code \(code).\n\(log.suffix(800))"
        }
    }
}

/// Finds and runs the ffmpeg / ffprobe command-line tools.
///
/// Looks in the app bundle first (Contents/Resources/bin, for a future bundled build),
/// then the usual Homebrew locations.
enum FFmpeg {
    static func url(for tool: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appending(path: "bin/\(tool)"))
        }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map {
            URL(filePath: $0).appending(path: tool)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { url(for: "ffmpeg") != nil && url(for: "ffprobe") != nil }

    struct Output {
        var stdout: String
        var stderr: String
    }

    /// Runs a tool to completion. `onLine` receives stdout line by line as it arrives
    /// (used for `-progress pipe:1`). Cancelling the task terminates the process.
    @discardableResult
    static func run(_ tool: String, _ args: [String],
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        guard let exe = url(for: tool) else { throw FFmpegError.notInstalled }

        let process = Process()
        process.executableURL = exe
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { h in
            collector.appendOut(h.availableData)
        }
        err.fileHandleForReading.readabilityHandler = { h in
            collector.appendErr(h.availableData)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                    let result = collector.finish()
                    if p.terminationStatus == 0 {
                        cont.resume(returning: result)
                    } else if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(throwing: FFmpegError.failed(
                            tool: tool, code: p.terminationStatus, log: result.stderr))
                    }
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Thread-safe buffer for a process's output.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data(), pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        out.append(data)
        var lines: [String] = []
        if onLine != nil {
            pending.append(data)
            while let nl = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func appendErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); err.append(data); lock.unlock()
    }

    func finish() -> FFmpeg.Output {
        lock.lock(); defer { lock.unlock() }
        return .init(stdout: String(decoding: out, as: UTF8.self),
                     stderr: String(decoding: err, as: UTF8.self))
    }
}

/// Turns ffmpeg `-progress pipe:1` lines into a 0...1 fraction.
struct ProgressParser {
    let duration: TimeInterval
    func fraction(from line: String) -> Double? {
        guard duration > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
              let micro = Double(line.split(separator: "=").last ?? "") else { return nil }
        return min(1, max(0, micro / 1_000_000 / duration))
    }
}
