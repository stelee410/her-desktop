import AppKit
import Foundation
import SwiftUI

/// Local inbox bridge and captured external events.
extension AppViewModel {
    func startLocalInboxBridge(port: UInt16? = nil) {
        let resolvedPort = port ?? localInboxBridgeState.port
        localInboxBridgeState.status = .starting
        localInboxBridgeState.port = resolvedPort
        localInboxBridgeState.summary = "Starting"
        do {
            try localInboxBridgeServer.start(port: resolvedPort) { [weak self] message in
                await self?.captureLocalInboxBridgeMessage(message)
            }
            localInboxBridgeState.status = .running
            localInboxBridgeState.summary = "Listening on \(localInboxBridgeState.endpoint)"
            audit(
                type: "inbox.bridge_started",
                summary: "Started local HTTP inbox bridge.",
                metadata: ["endpoint": localInboxBridgeState.endpoint]
            )
        } catch {
            localInboxBridgeState.status = .failed
            localInboxBridgeState.summary = error.localizedDescription
            lastError = "Could not start local inbox bridge: \(error.localizedDescription)"
            audit(
                type: "inbox.bridge_start_failed",
                summary: error.localizedDescription,
                metadata: ["port": String(resolvedPort)]
            )
        }
        rebuildRunningTasks()
    }

    func stopLocalInboxBridge() {
        localInboxBridgeServer.stop()
        localInboxBridgeState.status = .stopped
        localInboxBridgeState.summary = "Stopped"
        audit(
            type: "inbox.bridge_stopped",
            summary: "Stopped local HTTP inbox bridge.",
            metadata: ["endpoint": localInboxBridgeState.endpoint]
        )
        rebuildRunningTasks()
    }

    func captureQuickInboxMessage(text: String, url: String = "", source: String = "quick-capture", sender: String = "") {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        captureLocalInboxBridgeMessage(LocalInboxMessage(
            source: source,
            sender: sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? config.userID : sender,
            text: cleanText,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            receivedAt: ISO8601DateFormatter().string(from: Date())
        ))
    }

    func captureExternalInboxEventIfNeeded(invocation: CapabilityInvocation, result: CapabilityResult) {
        guard invocation.capabilityID == "inbox.capture",
              result.title == "Inbox Event Captured" else {
            return
        }
        let source = stringArgument(invocation.arguments, keys: ["source"], fallback: "external")
        let sender = stringArgument(invocation.arguments, keys: ["sender"], fallback: "")
        let text = stringArgument(invocation.arguments, keys: ["text", "request", "body", "content"], fallback: "")
        let url = stringArgument(invocation.arguments, keys: ["url"], fallback: "")
        let receivedAt = stringArgument(invocation.arguments, keys: ["received_at", "receivedAt"], fallback: "")
        let attachmentPaths = stringArrayArgument(invocation.arguments, keys: ["attachment_paths", "attachments", "files"])
        let (attachments, attachmentFailures) = importInboxAttachments(paths: attachmentPaths)
        let summaryPrefix = sender.isEmpty ? source : "\(source) from \(sender)"
        let preview = text.isEmpty ? "External inbox event captured." : String(text.prefix(140))
        var payload: [String: String] = [
            "source": source,
            "sender": sender,
            "textCharacters": String(text.count),
            "toolCallID": invocation.toolCallID,
            "attachmentCount": String(attachments.count)
        ]
        if !attachments.isEmpty {
            payload["attachmentNames"] = attachments.map(\.displayName).joined(separator: ", ")
        }
        if !attachmentFailures.isEmpty {
            payload["attachmentImportFailures"] = attachmentFailures.joined(separator: " | ")
        }
        if !url.isEmpty {
            payload["url"] = url
        }
        if !receivedAt.isEmpty {
            payload["receivedAt"] = receivedAt
        }
        recordInteractionEvent(interactionEventBus.event(
            surface: .externalInbox,
            kind: .externalInboxCaptured,
            summary: "\(summaryPrefix): \(preview)",
            payload: payload,
            attachments: attachments
        ))
    }

    func importInboxAttachments(paths: [String]) -> ([MessageAttachment], [String]) {
        var imported: [MessageAttachment] = []
        var failures: [String] = []
        for path in paths {
            do {
                imported.append(try attachmentStore.importFile(resolveInboxAttachmentURL(path)))
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }
        return (imported, failures)
    }

    func resolveInboxAttachmentURL(_ path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: runtimeCwd, isDirectory: true)
            .appendingPathComponent(expanded)
    }

    func captureLocalInboxBridgeMessage(_ message: LocalInboxMessage) {
        let invocation = CapabilityInvocation(
            toolCallID: "inbox-\(UUID().uuidString)",
            functionName: CapabilityToolCatalog.functionName(for: "inbox.capture"),
            capabilityID: "inbox.capture",
            arguments: [
                "source": message.source,
                "sender": message.sender,
                "text": message.text,
                "url": message.url,
                "received_at": message.receivedAt,
                "attachment_paths": message.attachmentPaths
            ]
        )
        var contentLines = [
            "source: \(message.source)",
            "sender: \(message.sender)"
        ]
        if !message.attachmentPaths.isEmpty {
            contentLines.append("attachment_paths: \(message.attachmentPaths.joined(separator: ", "))")
        }
        contentLines.append("characters: \(message.text.count)")
        contentLines.append("")
        contentLines.append(message.text)
        let result = CapabilityResult(
            title: "Inbox Event Captured",
            content: contentLines.joined(separator: "\n"),
            requiresUserApproval: false
        )
        captureExternalInboxEventIfNeeded(invocation: invocation, result: result)
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        auditCapabilityExecution(invocation: invocation, result: result, approved: false)
        saveSessionSnapshot()
    }
}
