import Foundation
import TrafficCore

enum SpeedTestRunner {
    /// Runs macOS's own `networkQuality` against Apple's servers: fixed system path, no shell,
    /// bounded runtime and output. Nothing is installed and no third-party service is contacted.
    /// Cancelling the calling task terminates the child, so quit and sleep never leave a test running.
    static func run() async throws -> SpeedTestResult {
        let handle = ChildHandle()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
            let tool = URL(fileURLWithPath: "/usr/bin/networkQuality")
            guard FileManager.default.isExecutableFile(atPath: tool.path) else {
                throw HistoryError("This Mac has no built-in speed test.")
            }
            let process = Process()
            process.executableURL = tool
            process.arguments = ["-c", "-M", "12"]
            guard handle.adopt(process) else { throw CancellationError() }
            let start = Date()
            let output = BoundedProcess.output(process, timeout: 30, limit: 1 << 20, launched: handle.launched)
            if handle.isCancelled { throw CancellationError() }
            guard let data = output else {
                throw HistoryError("The speed test didn't finish. Check the connection and try again.")
            }
            guard let result = SpeedTestResult.parse(data, start: start, end: Date()) else {
                throw HistoryError("The speed test returned no usable result.")
            }
            return result
            }.value
        } onCancel: { handle.cancel() }
    }
}

/// Lets cancellation reach a child process started on another thread.
private final class ChildHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    /// Returns false when cancellation already happened, so the child is never started.
    func adopt(_ process: Process) -> Bool {
        lock.withLock { guard !cancelled else { return false }; self.process = process; return true }
    }
    func cancel() {
        let running = lock.withLock { cancelled = true; return process }
        if let running, running.isRunning { running.terminate() }
    }
    /// Covers a cancel that arrived after adoption but before launch, when `isRunning` was still false.
    func launched(_ process: Process) {
        if isCancelled { process.terminate() }
    }
}

enum SpeedTestPhase: Equatable {
    case idle
    /// Waiting for the person to accept data use on a metered connection.
    case confirmMetered
    case running(since: Date)
    case failed(String)
}
