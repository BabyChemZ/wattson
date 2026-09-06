import Foundation

enum Shell {
    /// Run a command and capture stdout. Returns nil on launch failure, non-zero
    /// exit, or timeout — every caller here treats a missing sample as "skip this
    /// tick", never as "the process is idle", so failing closed is the safe default.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args

        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }

        // Drain on a background queue: a full pipe buffer would deadlock a
        // process we are simultaneously waiting on.
        let sink = OutputSink()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sink.store(out.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if proc.isRunning {
            proc.terminate()
            _ = drained.wait(timeout: .now() + 2)
            return nil
        }

        guard drained.wait(timeout: .now() + 5) == .success else { return nil }
        guard proc.terminationStatus == 0 else { return nil }

        return String(data: sink.value, encoding: .utf8)
    }
}

/// Hands the drained bytes back from the reader queue to the caller.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ new: Data) {
        lock.lock(); defer { lock.unlock() }
        data = new
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
