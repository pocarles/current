import Foundation
import Darwin

enum BoundedProcess {
    /// Reads only a child's stdout. No shell, inherited stderr, or disk output.
    /// Polling also bounds the read when another process keeps the pipe open.
    static func output(_ process: Process, timeout: Double = 2, limit: Int = 32768) -> Data? {
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let pid = process.processIdentifier
        defer {
            if process.isRunning { kill(pid, SIGKILL) }
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        // Close our copy of the write end so EOF reflects the child lifetime.
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        let end = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < end {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                guard count <= limit - data.count else { return nil }
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
                return !process.isRunning && process.terminationStatus == 0 ? data : nil
            } else if errno == EINTR { continue }
            else if errno == EAGAIN {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                let remaining = max(0, end - ProcessInfo.processInfo.systemUptime)
                _ = poll(&descriptor, 1, Int32(min(50, ceil(remaining * 1000))))
            } else { return nil }
        }
        return nil
    }
}
