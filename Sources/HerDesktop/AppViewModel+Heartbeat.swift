import Foundation

/// The heartbeat: a periodic tick that lets Her act on her own schedule —
/// reminders, recurring check-ins, and timed agent turns (计划任务).
///
/// Two task kinds, deliberately different in cost:
/// - `notify`: fires a local notification directly. No LLM turn, no tokens.
/// - `prompt`: wakes the agent with the task text as a real conversation
///   turn. Tools are available; normal approval rules apply (an unattended
///   turn queues approvals instead of bypassing them).
extension AppViewModel {
    // MARK: - Engine lifecycle

    func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        heartbeatTasks = heartbeatStore.load()
        // Catch up work that came due while the app was closed happens on
        // the first tick; fire it shortly after launch, then steadily.
        let timer = Timer.scheduledTimer(
            withTimeInterval: HeartbeatEngine.tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.heartbeatTick()
            }
        }
        // Heartbeat is slack-tolerant; tolerance lets the OS coalesce wakeups.
        timer.tolerance = HeartbeatEngine.tickInterval * 0.2
        heartbeatTimer = timer
        Task { @MainActor [weak self] in
            await self?.heartbeatTick()
        }
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// One heartbeat: fire every due task, reschedule, persist. Prompt tasks
    /// enqueue background jobs (which themselves yield to an in-flight user
    /// turn), so firing is safe at any time.
    ///
    /// Snapshot-then-relookup: `fire` suspends on the main actor (`await`),
    /// during which schedule.create/cancel can mutate `heartbeatTasks` —
    /// iterating live indices across that suspension crashed on a stale
    /// index. IDs stay valid; indices don't.
    func heartbeatTick(now: Date = Date()) async {
        guard !heartbeatTasks.isEmpty else { return }
        let dueIDs = heartbeatTasks.filter { $0.isDue(at: now) }.map(\.id)
        guard !dueIDs.isEmpty else { return }
        for id in dueIDs {
            // Re-look-up after each await; the task may have been cancelled.
            guard let index = heartbeatTasks.firstIndex(where: { $0.id == id }),
                  heartbeatTasks[index].isDue(at: now) else { continue }
            var task = heartbeatTasks[index]
            task.lastFiredAt = now
            if case .once = task.schedule {
                task.completedAt = now
            }
            heartbeatTasks[index] = task
            await fire(task)
        }
        // Only when something actually fired — an unconditional persist here
        // rewrote an identical heartbeat.json on the main actor every 30s.
        persistHeartbeatTasks()
    }

    private func fire(_ task: HeartbeatTask) async {
        audit(
            type: "heartbeat.fired",
            summary: "Scheduled task fired: \(task.title)",
            metadata: ["taskID": task.id.uuidString, "action": task.action.rawValue]
        )
        switch task.action {
        case .notify:
            let body = task.prompt.isEmpty ? task.title : task.prompt
            // Card in the conversation too: a system banner is easy to miss
            // (and macOS may suppress it while the app is frontmost).
            deliverConversationCard(ChatMessage(role: .tool, content: "⏰ 提醒 · \(task.title)\n\(body)"))
            do {
                _ = try await notificationScheduler.schedule(
                    title: task.title,
                    body: body,
                    delaySeconds: 1
                )
            } catch {
                audit(
                    type: "heartbeat.notify_failed",
                    summary: error.localizedDescription,
                    metadata: ["taskID": task.id.uuidString]
                )
            }
        case .prompt:
            // Runs as a background job in its own context — the conversation
            // the user is looking at is never interrupted; only the finished
            // result card lands there.
            enqueueJob(
                title: task.title,
                prompt: task.prompt,
                source: .heartbeat(taskTitle: task.title)
            )
        }
    }

    func persistHeartbeatTasks() {
        do {
            try heartbeatStore.save(heartbeatTasks)
        } catch {
            lastError = "计划任务未能保存：\(error.localizedDescription)"
        }
    }

    // MARK: - Capabilities

    func createScheduledTaskCapability(arguments: [String: Any]) -> CapabilityResult {
        let title = stringArgument(arguments, keys: ["title", "name"], fallback: "")
        let prompt = stringArgument(arguments, keys: ["prompt", "body", "message", "request"], fallback: "")
        let actionRaw = stringArgument(arguments, keys: ["action"], fallback: "notify").lowercased()
        guard let action = HeartbeatTask.Action(rawValue: actionRaw) else {
            return CapabilityResult(
                title: "Schedule Create Failed",
                content: "action must be notify or prompt.",
                requiresUserApproval: false,
                outcome: .failed("bad action")
            )
        }
        guard !title.isEmpty else {
            return CapabilityResult(
                title: "Schedule Create Failed",
                content: "title is required.",
                requiresUserApproval: false,
                outcome: .failed("missing title")
            )
        }
        guard let schedule = Self.parseSchedule(arguments: arguments) else {
            return CapabilityResult(
                title: "Schedule Create Failed",
                content: "Provide one of: at (ISO-8601 date, once), every_minutes (recurring), or daily_at (\"HH:mm\").",
                requiresUserApproval: false,
                outcome: .failed("bad schedule")
            )
        }
        let task = HeartbeatTask(title: title, action: action, prompt: prompt, schedule: schedule)
        heartbeatTasks.append(task)
        persistHeartbeatTasks()
        startHeartbeat()
        audit(
            type: "heartbeat.task_created",
            summary: "Scheduled task created: \(title) (\(task.scheduleDescription))",
            metadata: ["taskID": task.id.uuidString, "action": action.rawValue]
        )
        let next = task.nextFireDate(after: Date()).map {
            HeartbeatTaskStore.displayFormatter.string(from: $0)
        } ?? "unscheduled"
        return CapabilityResult(
            title: "Scheduled Task Created",
            content: """
            task_id: \(task.id.uuidString)
            title: \(title)
            action: \(action.rawValue)
            schedule: \(task.scheduleDescription)
            next_fire: \(next)
            """,
            requiresUserApproval: false,
            outcome: .ok
        )
    }

    func listScheduledTasksCapability() -> CapabilityResult {
        guard !heartbeatTasks.isEmpty else {
            return CapabilityResult(
                title: "Scheduled Tasks",
                content: "No scheduled tasks. Create one with schedule.create.",
                requiresUserApproval: false,
                outcome: .ok
            )
        }
        let now = Date()
        let lines = heartbeatTasks.map { task -> String in
            let status: String
            if task.completedAt != nil {
                status = "completed"
            } else if !task.enabled {
                status = "disabled"
            } else if let next = task.nextFireDate(after: now) {
                status = "next \(HeartbeatTaskStore.displayFormatter.string(from: next))"
            } else {
                status = "idle"
            }
            return "- \(task.id.uuidString) [\(task.action.rawValue)] \(task.title) (\(task.scheduleDescription); \(status))"
        }
        return CapabilityResult(
            title: "Scheduled Tasks",
            content: lines.joined(separator: "\n"),
            requiresUserApproval: false,
            outcome: .ok
        )
    }

    func cancelScheduledTaskCapability(arguments: [String: Any]) -> CapabilityResult {
        let rawID = stringArgument(arguments, keys: ["task_id", "taskID", "id"], fallback: "")
        let title = stringArgument(arguments, keys: ["title", "name"], fallback: "")
        let match: HeartbeatTask?
        if !rawID.isEmpty {
            match = heartbeatTasks.first { $0.id.uuidString.caseInsensitiveCompare(rawID) == .orderedSame }
        } else if !title.isEmpty {
            match = heartbeatTasks.first { $0.title == title }
        } else {
            match = nil
        }
        guard let task = match else {
            return CapabilityResult(
                title: "Schedule Cancel Failed",
                content: "No scheduled task matched task_id/title. Call schedule.list first.",
                requiresUserApproval: false,
                outcome: .failed("not found")
            )
        }
        heartbeatTasks.removeAll { $0.id == task.id }
        persistHeartbeatTasks()
        audit(
            type: "heartbeat.task_cancelled",
            summary: "Scheduled task cancelled: \(task.title)",
            metadata: ["taskID": task.id.uuidString]
        )
        return CapabilityResult(
            title: "Scheduled Task Cancelled",
            content: "Cancelled \(task.title) (\(task.id.uuidString)).",
            requiresUserApproval: false,
            outcome: .ok
        )
    }

    /// at (ISO-8601) → once; every_minutes → recurring; daily_at "HH:mm" → daily.
    static func parseSchedule(arguments: [String: Any]) -> HeartbeatTask.Schedule? {
        if let at = arguments["at"] as? String, !at.isEmpty {
            if let date = parseFlexibleDate(at) {
                return .once(at: date)
            }
            return nil
        }
        if let minutes = (arguments["every_minutes"] as? NSNumber)?.doubleValue
            ?? Double(arguments["every_minutes"] as? String ?? "") {
            guard minutes > 0 else { return nil }
            return .every(seconds: minutes * 60)
        }
        if let daily = arguments["daily_at"] as? String, !daily.isEmpty {
            let parts = daily.split(separator: ":").map(String.init)
            guard parts.count == 2,
                  let hour = Int(parts[0]), (0...23).contains(hour),
                  let minute = Int(parts[1]), (0...59).contains(minute) else {
                return nil
            }
            return .daily(hour: hour, minute: minute)
        }
        return nil
    }

    private static func parseFlexibleDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        // Local "yyyy-MM-dd HH:mm" convenience.
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd HH:mm"
        return local.date(from: text)
    }
}
