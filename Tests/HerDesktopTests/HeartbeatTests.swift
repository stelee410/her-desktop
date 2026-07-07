import XCTest
@testable import HerDesktop

@MainActor
final class HeartbeatTests: XCTestCase {
    final class FakeNotifier: NativeNotificationScheduling {
        var scheduled: [(title: String, body: String, delay: TimeInterval)] = []

        func schedule(title: String, body: String, delaySeconds: TimeInterval) async throws -> String {
            scheduled.append((title, body, delaySeconds))
            return "fake-id"
        }
    }

    private func makeRoot(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-heartbeat-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Store

    func testStoreRoundTripAndCorruptBackup() throws {
        let root = makeRoot("store")
        let store = HeartbeatTaskStore(cwd: root.path)
        let task = HeartbeatTask(
            title: "喝水",
            action: .notify,
            prompt: "该喝水了",
            schedule: .daily(hour: 9, minute: 30)
        )
        try store.save([task])
        let loaded = store.load()
        // ISO-8601 drops sub-second precision, so compare fields, not dates.
        XCTAssertEqual(loaded.map(\.id), [task.id])
        XCTAssertEqual(loaded.first?.title, task.title)
        XCTAssertEqual(loaded.first?.action, task.action)
        XCTAssertEqual(loaded.first?.prompt, task.prompt)
        XCTAssertEqual(loaded.first?.schedule, task.schedule)
        XCTAssertEqual(loaded.first?.enabled, true)

        // Corrupt file → backed up, load returns empty, original preserved.
        try Data("BROKEN".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), [])
        let backups = try FileManager.default
            .contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
            .filter { $0.contains("heartbeat.corrupt-") }
        XCTAssertFalse(backups.isEmpty)
    }

    // MARK: - Due computation

    func testOnceTaskIsDueOnlyUntilFired() {
        let now = Date()
        var task = HeartbeatTask(
            title: "one-shot",
            action: .notify,
            prompt: "",
            schedule: .once(at: now.addingTimeInterval(-60))
        )
        XCTAssertTrue(task.isDue(at: now), "past one-shot fires (catch-up)")
        task.completedAt = now
        XCTAssertFalse(task.isDue(at: now.addingTimeInterval(3600)), "completed one-shot never refires")
    }

    func testEveryTaskAnchorsOnCreationAndEnforcesMinimumInterval() {
        let now = Date()
        var task = HeartbeatTask(
            title: "recurring",
            action: .notify,
            prompt: "",
            schedule: .every(seconds: 1) // below the floor
        )
        // Anchored on creation: "every N" first fires N after creation, and
        // the 1s interval is clamped to the 60s floor.
        XCTAssertFalse(task.isDue(at: now), "must not fire at the moment of creation")
        XCTAssertFalse(task.isDue(at: now.addingTimeInterval(30)))
        XCTAssertTrue(task.isDue(at: now.addingTimeInterval(HeartbeatEngine.minimumInterval + 1)))
        // After firing, the anchor moves to lastFiredAt.
        task.lastFiredAt = now.addingTimeInterval(HeartbeatEngine.minimumInterval + 1)
        XCTAssertFalse(task.isDue(at: now.addingTimeInterval(HeartbeatEngine.minimumInterval + 30)))
        XCTAssertTrue(task.isDue(at: now.addingTimeInterval(2 * HeartbeatEngine.minimumInterval + 2)))
    }

    func testDailyTaskFiresAtNextOccurrenceAfterCreation() {
        let calendar = Calendar.current
        let now = Date()
        let scheduledAt = calendar.date(byAdding: .minute, value: -1, to: now)!
        let hour = calendar.component(.hour, from: scheduledAt)
        let minute = calendar.component(.minute, from: scheduledAt)

        // Created BEFORE today's occurrence → due today (catch-up).
        var task = HeartbeatTask(
            title: "daily",
            action: .notify,
            prompt: "",
            schedule: .daily(hour: hour, minute: minute)
        )
        task.createdAt = calendar.date(byAdding: .hour, value: -2, to: now)!
        XCTAssertTrue(task.isDue(at: now), "created before today's time and not yet fired → due")
        task.lastFiredAt = now
        XCTAssertFalse(task.isDue(at: now.addingTimeInterval(60)),
                       "already fired today — next occurrence is tomorrow")

        // Created AFTER today's occurrence → first fire is tomorrow, not now.
        var lateTask = HeartbeatTask(
            title: "daily-late",
            action: .notify,
            prompt: "",
            schedule: .daily(hour: hour, minute: minute)
        )
        lateTask.createdAt = now
        XCTAssertFalse(lateTask.isDue(at: now),
                       "daily task created after today's time must not fire immediately")
    }

    // MARK: - Engine

    func testTickFiresDueNotifyTaskAndPersistsReschedule() async throws {
        let root = makeRoot("tick")
        let notifier = FakeNotifier()
        let model = AppViewModel(cwd: root.path, notificationScheduler: notifier)
        let due = HeartbeatTask(
            title: "喝水",
            action: .notify,
            prompt: "该喝水了",
            schedule: .once(at: Date().addingTimeInterval(-5))
        )
        let notDue = HeartbeatTask(
            title: "明天的事",
            action: .notify,
            prompt: "",
            schedule: .once(at: Date().addingTimeInterval(86_400))
        )
        model.heartbeatTasks = [due, notDue]

        await model.heartbeatTick()

        XCTAssertEqual(notifier.scheduled.count, 1)
        XCTAssertEqual(notifier.scheduled.first?.title, "喝水")
        XCTAssertEqual(notifier.scheduled.first?.body, "该喝水了")
        XCTAssertNotNil(model.heartbeatTasks.first { $0.title == "喝水" }?.completedAt)
        XCTAssertTrue(model.auditEvents.contains { $0.type == "heartbeat.fired" })

        // Second tick: completed one-shot must not refire.
        await model.heartbeatTick()
        XCTAssertEqual(notifier.scheduled.count, 1)

        // Persisted: a fresh store sees the completed state.
        let persisted = HeartbeatTaskStore(cwd: root.path).load()
        XCTAssertNotNil(persisted.first { $0.title == "喝水" }?.completedAt)
    }

    func testPromptTaskEnqueuesJobThatYieldsToInFlightTurn() async {
        let root = makeRoot("busy")
        let notifier = FakeNotifier()
        let model = AppViewModel(cwd: root.path, notificationScheduler: notifier)
        model.heartbeatTasks = [HeartbeatTask(
            title: "检查",
            action: .prompt,
            prompt: "检查一下",
            schedule: .once(at: Date().addingTimeInterval(-5))
        )]
        model.connectionState = .thinking // a turn is in flight

        await model.heartbeatTick()

        // The task fires into a background job; the job (not the tick)
        // yields to the in-flight turn, so the conversation is untouched.
        XCTAssertNotNil(model.heartbeatTasks[0].lastFiredAt)
        XCTAssertEqual(model.agentJobs.first?.state, .queued)
        XCTAssertFalse(model.messages.contains { $0.role == .user })
        model.cancelQueuedJobs()
    }

    // MARK: - Capabilities

    func testScheduleCapabilitiesCreateListCancel() async {
        let root = makeRoot("caps")
        let model = AppViewModel(cwd: root.path, notificationScheduler: FakeNotifier())

        let created = await model.executeCapabilityInvocation(CapabilityInvocation(
            toolCallID: "t1",
            functionName: "schedule_create",
            capabilityID: "schedule.create",
            arguments: [
                "title": "喝水提醒",
                "action": "notify",
                "prompt": "起来喝水",
                "daily_at": "09:30"
            ]
        ))
        XCTAssertEqual(created.title, "Scheduled Task Created")
        XCTAssertEqual(created.outcome, .ok)
        XCTAssertTrue(created.content.contains("daily at 09:30"))
        XCTAssertEqual(model.heartbeatTasks.count, 1)

        let listed = await model.executeCapabilityInvocation(CapabilityInvocation(
            toolCallID: "t2",
            functionName: "schedule_list",
            capabilityID: "schedule.list",
            arguments: [:]
        ))
        XCTAssertTrue(listed.content.contains("喝水提醒"))

        let taskID = model.heartbeatTasks[0].id.uuidString
        let cancelled = await model.executeCapabilityInvocation(CapabilityInvocation(
            toolCallID: "t3",
            functionName: "schedule_cancel",
            capabilityID: "schedule.cancel",
            arguments: ["task_id": taskID]
        ))
        XCTAssertEqual(cancelled.title, "Scheduled Task Cancelled")
        XCTAssertTrue(model.heartbeatTasks.isEmpty)
        // Cancellation persisted too.
        XCTAssertTrue(HeartbeatTaskStore(cwd: root.path).load().isEmpty)
    }

    func testScheduleCreateRejectsBadSchedule() async {
        let root = makeRoot("bad")
        let model = AppViewModel(cwd: root.path, notificationScheduler: FakeNotifier())
        let result = await model.executeCapabilityInvocation(CapabilityInvocation(
            toolCallID: "t1",
            functionName: "schedule_create",
            capabilityID: "schedule.create",
            arguments: ["title": "x", "action": "notify", "daily_at": "25:99"]
        ))
        XCTAssertEqual(result.outcome, .failed("bad schedule"))
        XCTAssertTrue(model.heartbeatTasks.isEmpty)
    }

    func testScheduleCreateRequiresApprovalByManifest() {
        let root = makeRoot("approval")
        let model = AppViewModel(cwd: root.path, notificationScheduler: FakeNotifier())
        XCTAssertTrue(model.requiresApproval(capabilityID: "schedule.create"),
                      "creating unattended scheduled work needs user approval")
        XCTAssertFalse(model.requiresApproval(capabilityID: "schedule.list"))
        XCTAssertFalse(model.requiresApproval(capabilityID: "schedule.cancel"))
    }
}
