import Foundation

/// Runs a child process to completion while draining stdout/stderr
/// **concurrently**. Reading the pipes only after exit deadlocks once output
/// exceeds the ~64 KB kernel pipe buffer: the child blocks in write(), never
/// exits, and only a kill-timeout ends it — so a routine `cat` of a large
/// file used to hang for the full timeout and come back truncated.
enum ChildProcessRunner {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    /// Thread-safe accumulator fed from FileHandle readability callbacks.
    private final class PipeBuffer: @unchecked Sendable {
        private var data = Data()
        private var closed = false
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func markClosed() {
            lock.lock()
            closed = true
            lock.unlock()
        }

        var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// The caller configures executable/arguments/cwd/environment on
    /// `process`; this owns the pipes, timeout, and draining.
    static func run(_ process: Process, timeout: TimeInterval) async throws -> Output {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = PipeBuffer()
        let stderrBuffer = PipeBuffer()
        install(buffer: stdoutBuffer, on: stdoutPipe)
        install(buffer: stderrBuffer, on: stderrPipe)

        let startedAt = Date()
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }

        // Wait briefly for both pipes to report EOF so trailing output is not
        // lost to a race with the readability callbacks. If a grandchild
        // still holds the write end open (e.g. a daemonizing command), give
        // up after the grace period instead of hanging.
        let drainDeadline = Date().addingTimeInterval(2)
        while !(stdoutBuffer.isClosed && stderrBuffer.isClosed), Date() < drainDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let timedOut = status == 15 && Date().timeIntervalSince(startedAt) >= timeout - 0.1
        return Output(
            status: status,
            stdout: stdoutBuffer.snapshot(),
            stderr: stderrBuffer.snapshot(),
            timedOut: timedOut
        )
    }

    private static func install(buffer: PipeBuffer, on pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                buffer.markClosed()
                handle.readabilityHandler = nil
            } else {
                buffer.append(chunk)
            }
        }
    }
}
