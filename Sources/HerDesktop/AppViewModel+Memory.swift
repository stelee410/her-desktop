import AppKit
import Foundation
import SwiftUI

/// AgentMem retrieval, writeback, companion signals, and reflection.
extension AppViewModel {
    func refreshDreamContext() {
        dreamContext = DreamPromptContextLoader.load(cwd: runtimeCwd)
    }

    func generateReflectionSnapshot() {
        let result = saveReflectionSnapshot(focus: "")
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        saveSessionSnapshot()
    }

    @discardableResult
    func saveReflectionSnapshot(focus: String) -> CapabilityResult {
        let context = DreamReflectionBuilder().build(
            messages: messages,
            tasks: runningTasks,
            activities: capabilityActivities,
            interactionEvents: interactionEvents,
            pluginEvents: pluginEvents,
            profile: agentProfile,
            memorySignal: memorySignal,
            focus: focus
        )
        do {
            let url = try DreamPromptContextStore.save(context, cwd: runtimeCwd)
            dreamContext = context
            audit(
                type: "dream.reflection_saved",
                summary: "Saved local companion reflection snapshot.",
                metadata: [
                    "path": url.path,
                    "behaviorGuidanceCount": String(context.behaviorGuidance.count),
                    "unresolvedThreadCount": String(context.unresolvedThreads.count),
                    "cautionCount": String(context.cautions.count)
                ]
            )
            return CapabilityResult(
                title: "Reflection Snapshot Saved",
                content: """
                Updated compressed companion context at \(url.path).
                guidance: \(context.behaviorGuidance.count)
                open_threads: \(context.unresolvedThreads.count)
                cautions: \(context.cautions.count)
                """,
                requiresUserApproval: false
            )
        } catch {
            lastError = "Could not save reflection snapshot: \(error.localizedDescription)"
            audit(type: "dream.reflection_save_failed", summary: error.localizedDescription)
            return CapabilityResult(
                title: "Reflection Snapshot Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    @discardableResult
    func refreshAgentProfile() async {
        guard config.hasMemKey else {
            agentProfile = .empty(userID: config.userID)
            memorySignal.relationshipSummary = agentProfile.relationship
            return
        }
        do {
            let object = try await agentMem.relationship()
            let emotion = try? await agentMem.emotion()
            let profile = AgentProfile.fromRelationshipPayload(object, fallbackUserID: config.userID)
            agentProfile = profile
            memorySignal = MemorySignal.fromAgentMemV7(
                relationship: object,
                emotion: emotion,
                fallback: memorySignal
            )
            rebuildRunningTasks()
        } catch {
            lastError = "Could not refresh AgentMem profile: \(error.localizedDescription)"
        }
    }

    func refreshAgentMemTurnSignals() async {
        guard config.hasMemKey else { return }
        var relationship: [String: Any]?
        var emotion: [String: Any]?
        var failures: [String] = []

        do {
            relationship = try await agentMem.relationship()
        } catch {
            failures.append("relationship: \(error.localizedDescription)")
        }

        do {
            emotion = try await agentMem.emotion()
        } catch {
            failures.append("emotion: \(error.localizedDescription)")
        }

        if let relationship {
            agentProfile = AgentProfile.fromRelationshipPayload(relationship, fallbackUserID: config.userID)
            memorySignal = MemorySignal.fromAgentMemV7(
                relationship: relationship,
                emotion: emotion,
                fallback: memorySignal
            )
            rebuildRunningTasks()
        } else if let emotion {
            memorySignal = MemorySignal.fromAgentMemV7(
                relationship: [:],
                emotion: emotion,
                fallback: memorySignal
            )
        }

        if failures.isEmpty {
            audit(
                type: "memory.turn_signals_refreshed",
                summary: "AgentMem relationship and emotion signals refreshed before generation."
            )
        } else {
            audit(
                type: "memory.turn_signals_partial",
                summary: failures.joined(separator: " · ")
            )
        }
    }

    func retrieveMemory(for text: String) async -> String {
        guard config.hasMemKey else { return "" }
        do {
            let response = try await agentMem.query(text, sessionID: sessionID)
            if let first = response.retrievedMemories.first {
                memorySignal = memorySignal.mergedWithRetrieval(
                    count: response.retrievedMemories.count,
                    firstScore: first.score
                )
            }
            return response.injectedContext
        } catch {
            audit(
                type: "memory.query_failed",
                summary: error.localizedDescription
            )
            return ""
        }
    }

    func companionPromptContext() -> CompanionPromptContext {
        CompanionPromptContext(profile: agentProfile, memorySignal: memorySignal)
    }

    func persistTurnMemory(userInput: String, agentResponse: String, attachments: [MessageAttachment] = []) async {
        guard config.hasMemKey else { return }
        do {
            var metadata: [String: Any] = ["surface": "mac", "source": "her-desktop"]
            if !attachments.isEmpty {
                metadata["attachment_count"] = attachments.count
                metadata["attachment_kinds"] = Array(Set(attachments.map { $0.kind.rawValue })).sorted().joined(separator: ",")
                metadata["attachment_names"] = attachments.map(\.displayName).joined(separator: ", ")
            }
            let mode: String
            let response: AgentMemAddResponse
            if let summary = sessionMemorySummary() {
                mode = "summary"
                metadata["writeback_mode"] = mode
                response = try await agentMem.addSummary(summary, sessionID: sessionID, metadata: metadata)
            } else {
                mode = "turn"
                response = try await agentMem.add(
                    userInput: userInput,
                    agentResponse: agentResponse,
                    sessionID: sessionID,
                    metadata: metadata
                )
            }
            audit(
                type: "memory.writeback_succeeded",
                summary: mode == "summary" ? "Session summary was submitted to AgentMem." : "Turn was submitted to AgentMem.",
                metadata: [
                    "sessionID": sessionID,
                    "mode": mode,
                    "status": response.status,
                    "taskID": response.taskID
                ]
            )
            await auditAgentMemTaskStatus(
                taskID: response.taskID,
                eventType: "memory.writeback_task_status",
                failureType: "memory.writeback_task_check_failed",
                metadata: [
                    "sessionID": sessionID,
                    "mode": mode
                ]
            )
        } catch {
            audit(
                type: "memory.writeback_failed",
                summary: error.localizedDescription,
                metadata: ["sessionID": sessionID]
            )
        }
    }

    func sessionMemorySummary(maxMessages: Int = 8) -> String? {
        let visibleMessages = messages.filter { message in
            message.role == .user || message.role == .assistant
        }
        let visible = Array(visibleMessages.drop { $0.role != .user })
        let userCount = visible.filter { $0.role == .user }.count
        let assistantCount = visible.filter { $0.role == .assistant }.count
        guard userCount >= 3, assistantCount >= 3 else { return nil }
        let recent = visible.suffix(maxMessages)
        let userLines = recent.filter { $0.role == .user }.map { message in
            let content = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "- \(String(content.prefix(700)))"
        }
        let assistantLines = recent.filter { $0.role == .assistant }.map { message in
            let content = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "- \(String(content.prefix(500)))"
        }
        return """
        Her Desktop session summary.

        User-stated durable candidates:
        \(userLines.joined(separator: "\n"))

        Assistant context:
        \(assistantLines.joined(separator: "\n"))
        """
    }

    func persistCapabilityMemory(
        invocation: CapabilityInvocation,
        result: CapabilityResult,
        approved: Bool
    ) async {
        guard config.hasMemKey else { return }
        let arguments = approvalDetail(for: invocation)
        let userInput = """
        Capability executed: \(invocation.capabilityID)
        Function: \(invocation.functionName)
        Approved by user: \(approved)
        Arguments:
        \(arguments)
        """
        let agentResponse = """
        Result title: \(result.title)
        Result content:
        \(String(result.content.prefix(4000)))
        """

        do {
            let response = try await agentMem.add(
                userInput: userInput,
                agentResponse: agentResponse,
                sessionID: sessionID,
                metadata: [
                    "surface": "mac",
                    "source": "her-desktop",
                    "event": "capability.execution",
                    "capabilityID": invocation.capabilityID,
                    "functionName": invocation.functionName,
                    "approved": String(approved)
                ]
            )
            audit(
                type: "memory.capability_writeback_succeeded",
                summary: "Capability result was submitted to AgentMem.",
                metadata: [
                    "sessionID": sessionID,
                    "status": response.status,
                    "taskID": response.taskID,
                    "capabilityID": invocation.capabilityID,
                    "functionName": invocation.functionName
                ]
            )
            await auditAgentMemTaskStatus(
                taskID: response.taskID,
                eventType: "memory.capability_writeback_task_status",
                failureType: "memory.capability_writeback_task_check_failed",
                metadata: [
                    "sessionID": sessionID,
                    "capabilityID": invocation.capabilityID,
                    "functionName": invocation.functionName
                ]
            )
        } catch {
            audit(
                type: "memory.capability_writeback_failed",
                summary: error.localizedDescription,
                metadata: [
                    "sessionID": sessionID,
                    "capabilityID": invocation.capabilityID,
                    "functionName": invocation.functionName
                ]
            )
        }
    }

    func auditAgentMemTaskStatus(
        taskID: String,
        eventType: String,
        failureType: String,
        metadata: [String: String]
    ) async {
        do {
            let status = try await agentMem.waitForTaskStatus(taskID: taskID)
            var statusMetadata = metadata
            statusMetadata["taskID"] = status.taskID
            statusMetadata["taskType"] = status.taskType
            statusMetadata["taskStatus"] = status.status
            if let durationMs = status.durationMs {
                statusMetadata["durationMs"] = "\(durationMs)"
            }
            audit(
                type: eventType,
                summary: status.auditSummary,
                metadata: statusMetadata
            )
        } catch {
            var failureMetadata = metadata
            failureMetadata["taskID"] = taskID
            audit(
                type: failureType,
                summary: error.localizedDescription,
                metadata: failureMetadata
            )
        }
    }
}
