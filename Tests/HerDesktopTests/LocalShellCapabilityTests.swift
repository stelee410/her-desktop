import XCTest
@testable import HerDesktop

final class LocalShellCapabilityTests: XCTestCase {
    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-local-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func makeExecutor(root: URL) -> CapabilityExecutor {
        CapabilityExecutor(registry: PluginRegistry(config: .empty), baseDirectory: root.path)
    }

    private func invocation(_ capabilityID: String, _ arguments: [String: Any]) -> CapabilityInvocation {
        CapabilityInvocation(
            toolCallID: "call_shell",
            functionName: capabilityID.replacingOccurrences(of: ".", with: "_"),
            capabilityID: capabilityID,
            arguments: arguments
        )
    }

    @MainActor
    func testShellInspectRunsAllowlistedCommandInsideWorkspace() async throws {
        let root = try makeWorkspace()
        try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let executor = makeExecutor(root: root)

        let result = await executor.execute(invocation("shell.inspect", [
            "command": "ls",
            "args": ["-la", "."]
        ]))

        XCTAssertEqual(result.title, "Shell Command Result")
        XCTAssertTrue(result.content.contains("exit_status: 0"))
        XCTAssertTrue(result.content.contains("note.txt"))
    }

    @MainActor
    func testShellInspectBlocksCommandsOutsideAllowlist() async throws {
        let root = try makeWorkspace()
        let executor = makeExecutor(root: root)

        let shell = await executor.execute(invocation("shell.inspect", [
            "command": "bash",
            "args": ["-c", "echo pwned"]
        ]))
        XCTAssertEqual(shell.title, "Shell Command Blocked")

        let sideEffect = await executor.execute(invocation("shell.inspect", [
            "command": "curl",
            "args": ["https://example.com"]
        ]))
        XCTAssertEqual(sideEffect.title, "Shell Command Blocked")
        XCTAssertTrue(sideEffect.content.contains("shell.run"))
    }

    @MainActor
    func testShellInspectBlocksPathsOutsideWorkspace() async throws {
        let root = try makeWorkspace()
        let executor = makeExecutor(root: root)

        let absolute = await executor.execute(invocation("shell.inspect", [
            "command": "cat",
            "args": ["/etc/hosts"]
        ]))
        XCTAssertEqual(absolute.title, "Shell Command Blocked")

        let traversal = await executor.execute(invocation("shell.inspect", [
            "command": "ls",
            "args": ["../"]
        ]))
        XCTAssertEqual(traversal.title, "Shell Command Blocked")
    }

    @MainActor
    func testShellInspectBlocksMutatingFindFlags() async throws {
        let root = try makeWorkspace()
        let executor = makeExecutor(root: root)

        let deleteFlag = await executor.execute(invocation("shell.inspect", [
            "command": "find",
            "args": [".", "-name", "*.txt", "-delete"]
        ]))
        XCTAssertEqual(deleteFlag.title, "Shell Command Blocked")

        let execFlag = await executor.execute(invocation("shell.inspect", [
            "command": "find",
            "args": [".", "-exec", "rm", "{}", ";"]
        ]))
        XCTAssertEqual(execFlag.title, "Shell Command Blocked")
    }

    @MainActor
    func testShellRunExecutesMkdirInsideWorkspaceAndBlocksOutside() async throws {
        let root = try makeWorkspace()
        let executor = makeExecutor(root: root)

        let inside = await executor.execute(invocation("shell.run", [
            "command": "mkdir",
            "args": ["-p", "artifacts/output"]
        ]))
        XCTAssertEqual(inside.title, "Shell Command Result")
        XCTAssertTrue(inside.content.contains("exit_status: 0"))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("artifacts/output").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)

        let outside = await executor.execute(invocation("shell.run", [
            "command": "mkdir",
            "args": ["/tmp/her-shell-escape-\(UUID().uuidString)"]
        ]))
        XCTAssertEqual(outside.title, "Shell Command Blocked")
    }

    @MainActor
    func testShellRunBlocksRmOutsideWorkspaceAndAllowsInside() async throws {
        let root = try makeWorkspace()
        try "delete me".write(to: root.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
        let executor = makeExecutor(root: root)

        let outside = await executor.execute(invocation("shell.run", [
            "command": "rm",
            "args": ["-rf", NSHomeDirectory()]
        ]))
        XCTAssertEqual(outside.title, "Shell Command Blocked")

        let inside = await executor.execute(invocation("shell.run", [
            "command": "rm",
            "args": ["scratch.txt"]
        ]))
        XCTAssertEqual(inside.title, "Shell Command Result")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scratch.txt").path))
    }

    @MainActor
    func testLocalShellManifestLoadsWithApprovalContract() throws {
        let registry = PluginRegistry(config: .empty)
        let manifest = try XCTUnwrap(
            registry.loadPlugins().first { $0.id == "builtin.local-shell" }
        )
        let inspect = try XCTUnwrap(manifest.capabilities.first { $0.id == "shell.inspect" })
        let run = try XCTUnwrap(manifest.capabilities.first { $0.id == "shell.run" })
        XCTAssertFalse(inspect.requiresApproval)
        XCTAssertTrue(run.requiresApproval)
    }
}
