import Foundation

/// Run a command, capture what it says, and *always* come back.
///
/// Temple runs binaries it did not write, found on a PATH it did not choose, to
/// ask them whether they work. Some of them won't. The naive version of this —
/// `readDataToEndOfFile()` guarded by a `terminate()` watchdog — has two ways to
/// hang the app forever, and one of them hangs it during launch:
///
/// - `terminate()` is only `SIGTERM`. A process that ignores it keeps its end of
///   the pipe open, so the read never sees EOF and never returns. We escalate to
///   `SIGKILL`, and if even that leaves the pipe held open (a grandchild inherited
///   it), we abandon the reader rather than block the caller.
/// - The read is unbounded. A binary that loops printing an error fills memory as
///   fast as it can write. We stop at `limit` bytes and kill it.
///
/// The caller gets a result — possibly truncated, possibly marked `timedOut` — but
/// it gets one.
enum CommandCapture {

    struct Result {
        /// stdout and stderr, interleaved as the process wrote them.
        let output: String
        let status: Int32
        let timedOut: Bool
        /// Output ran past `limit` and was cut short (the process was killed).
        let truncated: Bool

        var succeeded: Bool { status == 0 && !timedOut }
    }

    /// `nil` only when the command could not be launched at all.
    static func run(_ executable: String,
                    _ arguments: [String],
                    timeout: TimeInterval,
                    limit: Int = 64 * 1024) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // An interactive shell that inherits our stdin can block on a read.
        process.standardInput = FileHandle.nullDevice

        let sink = Sink(limit: limit)
        let reader = pipe.fileHandleForReading
        let done = DispatchSemaphore(value: 0)

        // Drain on a background thread so the caller can time out independently of
        // the reader. If the reader is still stuck at the end we let it park rather
        // than close the handle underneath it — `FileHandle` raises on a read that
        // fails, and crashing the app is a worse outcome than one idle thread.
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = reader.availableData     // returns empty at EOF
                if chunk.isEmpty { break }
                if sink.append(chunk) { break }      // hit the cap
            }
            done.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
        } else if sink.isFull {
            timedOut = false                          // it talked too much, not too long
        }

        if process.isRunning {
            process.terminate()                       // SIGTERM
            if done.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)    // may still time out: reader abandoned
            }
        }
        process.waitUntilExit()

        return Result(output: sink.text(),
                      status: process.terminationStatus,
                      timedOut: timedOut,
                      truncated: sink.isFull)
    }

    /// The reader thread writes; the caller reads after the semaphore (or after the
    /// kill escalation gives up). Both sides go through the lock — a `DispatchWorkItem`
    /// cancellation is not a memory barrier, and pretending otherwise was the old bug.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var full = false
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        /// Returns true once the cap is reached — the caller should stop reading.
        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !full else { return true }
            data.append(chunk)
            if data.count >= limit {
                data = data.prefix(limit)
                full = true
            }
            return full
        }

        var isFull: Bool {
            lock.lock()
            defer { lock.unlock() }
            return full
        }

        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
