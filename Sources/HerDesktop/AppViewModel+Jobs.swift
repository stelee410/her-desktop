import Foundation

/// A background unit of agent work with its own context, state, log, and
/// budget — the "process" of the agentOS. Scheduled (heartbeat) and future
/// event-triggered work runs here instead of interrupting the conversation
/// the user is looking at; only the finished result card reaches it.
struct AgentJob: Identifiable, Equatable {
    enum Source: Equatable {
        case heartbeat(taskTitle: String)
        case user
    }

    enum State: String, Equatable {
        case queued
        case running
        case done
        case failed
        /// Stopped at a capability that needs the user's approval; the
        /// approval card is waiting in the conversation.
        case needsApproval
    }

    var id: UUID = UUID()
    var title: String
    var prompt: String
    var source: Source
    var state: State = .queued
    var createdAt: Date = Date()
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    /// Budget: the hard cap on tool rounds (the LLM-call budget until token
    /// accounting exists — see docs/agentos-gap-analysis.md R2).
    var maxToolRounds: Int = 6
    /// Human-readable step log shown in the inspector.
    var log: [String] = []
    var result: String? = nil
    var failureReason: String? = nil

    var isFinished: Bool {
        state == .done || state == .failed || state == .needsApproval
    }
}

/// Background job queue + executor. Jobs run strictly one at a time, and a
/// job never starts while the visible conversation is generating — the two
/// share the LLM and the capability runtime, and unattended work must yield
/// to the user, never race them.
extension AppViewModel {
    @discardableResult
    func enqueueJob(
        title: String,
        prompt: String,
        source: AgentJob.Source,
        maxToolRounds: Int = 6
    ) -> AgentJob {
        let job = AgentJob(
            title: title,
            prompt: prompt,
            source: source,
            maxToolRounds: min(max(maxToolRounds, 1), 12)
        )
        guard !isShuttingDown else {
            // Teardown already began (a heartbeat tick can still be in
            // flight); don't respawn the worker after shutdown.
            return job
        }
        agentJobs.insert(job, at: 0)
        audit(
            type: "job.enqueued",
            summary: "Queued background job: \(title)",
            metadata: ["jobID": job.id.uuidString]
        )
        pumpJobQueue()
        return job
    }

    /// Start the worker if it is not already draining the queue.
    func pumpJobQueue() {
        guard jobWorkerTask == nil else { return }
        jobWorkerTask = Task { @MainActor [weak self] in
            defer { self?.jobWorkerTask = nil }
            while let self, let next = self.agentJobs.last(where: { $0.state == .queued }) {
                // Yield to the user's in-flight turn instead of racing it.
                while self.isGenerating || self.isLoadingConversation {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return }
                }
                await self.executeJob(next.id)
            }
        }
    }

    func cancelQueuedJobs() {
        jobWorkerTask?.cancel()
        jobWorkerTask = nil
        for index in agentJobs.indices where agentJobs[index].state == .queued {
            agentJobs[index].state = .failed
            agentJobs[index].failureReason = "cancelled"
            agentJobs[index].finishedAt = Date()
        }
    }

    // MARK: - Execution

    /// One background turn loop: same system prompt, same tool catalog, same
    /// approval gate and audit pipeline as the interactive loop — but
    /// non-streaming, against the job's own context, with tool chatter kept
    /// in the job log instead of the transcript.
    private func executeJob(_ jobID: UUID) async {
        guard let index = agentJobs.firstIndex(where: { $0.id == jobID }) else { return }
        agentJobs[index].state = .running
        agentJobs[index].startedAt = Date()
        let job = agentJobs[index]
        audit(
            type: "job.started",
            summary: "Background job started: \(job.title)",
            metadata: ["jobID": job.id.uuidString]
        )

        do {
            let memContext = await retrieveMemory(for: job.prompt)
            let prompt = SystemPromptBuilder(pluginManifests: plugins, projectDocs: projectPromptDocs).build(
                memoryContext: memContext,
                activeTaskSummary: activeTaskSummary(),
                agentLoopSummary: "",
                runtimeContext: PromptRuntimeContext.current(config: config, cwd: runtimeCwd),
                companionContext: companionPromptContext(),
                roleplayContext: roleplayPromptSection()
            )
            var llmMessages: [AgentLLMMessage] = [
                .system(prompt),
                .user("[后台任务 · \(job.title)] \(job.prompt)")
            ]
            var catalog = CapabilityToolCatalog.build(from: plugins)

            for round in 0...job.maxToolRounds {
                let message = try await agentLLM.chat(messages: llmMessages, tools: catalog.tools)
                let toolCalls = message.toolCalls ?? []
                if toolCalls.isEmpty {
                    let reply = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    finishJob(jobID, state: .done, result: reply.isEmpty ? "(空回复)" : reply)
                    return
                }
                guard round < job.maxToolRounds else {
                    finishJob(
                        jobID,
                        state: .failed,
                        result: nil,
                        failureReason: "达到 \(job.maxToolRounds) 轮工具调用预算上限"
                    )
                    return
                }
                llmMessages.append(.assistant(content: message.content, toolCalls: toolCalls))

                for toolCall in toolCalls {
                    let capabilityID = catalog.functionToCapability[toolCall.function.name] ?? toolCall.function.name
                    let invocation = CapabilityInvocation(
                        toolCallID: toolCall.id,
                        functionName: toolCall.function.name,
                        capabilityID: capabilityID,
                        arguments: parseArguments(toolCall.function.arguments)
                    )
                    if requiresApproval(for: invocation) {
                        // Unattended work never bypasses approval: park the
                        // request where the user will see it and stop here.
                        let (approval, isNew) = enqueueApproval(for: invocation)
                        if isNew {
                            messages.append(ChatMessage(
                                role: .tool,
                                content: "Approval Required\n\(approval.title)\n\(approval.detail)",
                                approvalID: approval.id
                            ))
                            saveSessionSnapshot()
                        }
                        appendJobLog(jobID, "待审批: \(capabilityID)")
                        // Honest copy: approving runs THAT action standalone;
                        // the job itself does not resume its remaining plan.
                        finishJob(
                            jobID,
                            state: .needsApproval,
                            result: "任务在需要你批准的操作(\(capabilityID))处停住了。批准后该操作会单独执行；如需继续整个任务，请重新发起。"
                        )
                        return
                    }
                    let activityID = beginCapabilityActivity(
                        invocation: invocation,
                        status: .running,
                        summary: "Background job: \(job.title)"
                    )
                    let outcome = await runInvocation(
                        invocation,
                        activityID: activityID,
                        approved: false,
                        postToConversation: false
                    )
                    llmMessages.append(.toolResult(
                        id: toolCall.id,
                        name: toolCall.function.name,
                        content: outcome.result.content
                    ))
                    appendJobLog(jobID, "\(capabilityID): \(outcome.result.title)")
                }
                await reloadPlugins()
                catalog = CapabilityToolCatalog.build(from: plugins)
            }
        } catch {
            finishJob(jobID, state: .failed, result: nil, failureReason: error.localizedDescription)
        }
    }

    private func appendJobLog(_ jobID: UUID, _ line: String) {
        guard let index = agentJobs.firstIndex(where: { $0.id == jobID }) else { return }
        agentJobs[index].log.append(line)
    }

    private func finishJob(
        _ jobID: UUID,
        state: AgentJob.State,
        result: String?,
        failureReason: String? = nil
    ) {
        guard let index = agentJobs.firstIndex(where: { $0.id == jobID }) else { return }
        agentJobs[index].state = state
        agentJobs[index].finishedAt = Date()
        agentJobs[index].result = result
        agentJobs[index].failureReason = failureReason
        let job = agentJobs[index]
        audit(
            type: "job.finished",
            summary: "Background job \(state.rawValue): \(job.title)",
            metadata: ["jobID": job.id.uuidString, "state": state.rawValue]
        )
        deliverJobResultCard(job)
        trimFinishedJobs()
    }

    /// The single message a finished job contributes to the conversation.
    private func deliverJobResultCard(_ job: AgentJob) {
        let header: String
        switch job.state {
        case .done: header = "后台任务完成 · \(job.title)"
        case .needsApproval: header = "后台任务待批准 · \(job.title)"
        default: header = "后台任务失败 · \(job.title)"
        }
        let steps = job.log.isEmpty ? "" : "\n\n步骤:\n" + job.log.map { "- \($0)" }.joined(separator: "\n")
        let body = job.result ?? job.failureReason ?? ""
        deliverConversationCard(ChatMessage(role: .tool, content: "\(header)\n\(body)\(steps)"))
        if case .heartbeat = job.source {
            Task { [notificationScheduler] in
                _ = try? await notificationScheduler.schedule(
                    title: header,
                    body: String(body.prefix(120)),
                    delaySeconds: 1
                )
            }
        }
    }

    /// Append a system-generated card (job result, heartbeat reminder) to
    /// the conversation. Waits out any in-flight transcript load first — a
    /// card appended mid-load would be clobbered by the load completion
    /// (`messages = loaded`).
    func deliverConversationCard(_ card: ChatMessage) {
        Task { @MainActor [weak self] in
            var waited = 0
            while self?.isLoadingConversation == true, waited < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            guard let self else { return }
            self.messages.append(card)
            self.saveSessionSnapshot()
        }
    }

    /// Keep the visible job list bounded; finished jobs' results live on in
    /// the conversation transcript and the audit trail.
    private func trimFinishedJobs() {
        let finished = agentJobs.filter(\.isFinished)
        if finished.count > 8 {
            let overflow = finished.suffix(from: 8).map(\.id)
            agentJobs.removeAll { overflow.contains($0.id) }
        }
    }
}
