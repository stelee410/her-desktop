import XCTest
@testable import HerDesktop

final class ChildProcessRunnerTests: XCTestCase {
    /// Regression: output beyond the ~64 KB kernel pipe buffer used to block
    /// the child in write() forever (the pipes were only drained after exit),
    /// so the command hung until the kill-timeout and came back truncated.
    func testLargeOutputCompletesQuicklyAndUntruncated() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/dd")
        // 200 KB of zeros to stdout — far past the pipe buffer.
        process.arguments = ["if=/dev/zero", "bs=1024", "count=200"]

        let started = Date()
        let output = try await ChildProcessRunner.run(process, timeout: 30)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(output.status, 0)
        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(output.stdout.count, 200 * 1024, "output must not be truncated")
        XCTAssertLessThan(elapsed, 10, "must not stall until the kill-timeout")
    }

    func testCapturesStderrAndExitStatus() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo out; echo err 1>&2; exit 3"]

        let output = try await ChildProcessRunner.run(process, timeout: 10)

        XCTAssertEqual(output.status, 3)
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "out\n")
        XCTAssertEqual(String(data: output.stderr, encoding: .utf8), "err\n")
        XCTAssertFalse(output.timedOut)
    }

    func testTimeoutTerminatesRunawayProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]

        let started = Date()
        let output = try await ChildProcessRunner.run(process, timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(elapsed, 8)
    }
}
