import XCTest
@testable import HerDesktop

final class MemoryWritebackStatusBuilderTests: XCTestCase {
    func testBuildsRecentMemoryWritebackStatusesFromAuditEvents() {
        let older = AuditEvent(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            type: "memory.writeback_task_status",
            summary: "AgentMem task succeeded · 42.0ms",
            metadata: [
                "taskID": "task_old",
                "taskType": "memory_add",
                "taskStatus": "succeeded",
                "mode": "turn"
            ]
        )
        let newer = AuditEvent(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 300),
            type: "memory.capability_writeback_task_status",
            summary: "AgentMem task processing",
            metadata: [
                "taskID": "task_new",
                "taskType": "memory_add",
                "taskStatus": "processing",
                "capabilityID": "agentmem.add"
            ]
        )
        let ignored = AuditEvent(
            createdAt: Date(timeIntervalSince1970: 400),
            type: "plugin.installed",
            summary: "Installed plugin.",
            metadata: ["pluginID": "local.test"]
        )

        let statuses = MemoryWritebackStatusBuilder().build(from: [older, ignored, newer])

        XCTAssertEqual(statuses.map(\.taskID), ["task_new", "task_old"])
        XCTAssertEqual(statuses.first?.title, "Capability agentmem.add")
        XCTAssertEqual(statuses.first?.status, "processing")
        XCTAssertEqual(statuses.first?.icon, "hourglass")
        XCTAssertEqual(statuses.last?.title, "Turn writeback")
        XCTAssertEqual(statuses.last?.icon, "checkmark.seal")
    }

    func testBuildsFailedTaskCheckStatusWhenPollingFails() {
        let event = AuditEvent(
            createdAt: Date(timeIntervalSince1970: 100),
            type: "memory.writeback_task_check_failed",
            summary: "HTTP 404: task_id not found",
            metadata: [
                "taskID": "task_missing",
                "mode": "summary"
            ]
        )

        let status = MemoryWritebackStatusBuilder().build(from: [event]).first

        XCTAssertEqual(status?.title, "Summary writeback")
        XCTAssertEqual(status?.status, "check failed")
        XCTAssertEqual(status?.icon, "exclamationmark.triangle")
        XCTAssertTrue(status?.detail.contains("task_missing") == true)
    }

    func testLimitCapsDisplayedStatuses() {
        let events = (0..<6).map { index in
            AuditEvent(
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                type: "memory.writeback_task_status",
                summary: "AgentMem task queued",
                metadata: [
                    "taskID": "task_\(index)",
                    "taskStatus": "queued",
                    "mode": "turn"
                ]
            )
        }

        let statuses = MemoryWritebackStatusBuilder(limit: 3).build(from: events)

        XCTAssertEqual(statuses.map(\.taskID), ["task_5", "task_4", "task_3"])
    }
}
