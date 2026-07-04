import AppKit
import Foundation
import SwiftUI

/// Dictation input and spoken replies.
extension AppViewModel {
    func toggleDictation() {
        if connectionState == .listening {
            stopDictation()
        } else {
            startDictation()
        }
    }

    func startDictation(localeIdentifier: String = Locale.current.identifier) {
        guard connectionState != .listening else { return }
        dictationTask?.cancel()
        dictationBaseText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationTranscript = ""
        connectionState = .listening
        lastError = nil
        audit(
            type: "voice.dictation_started",
            summary: "Started local macOS speech dictation.",
            metadata: ["locale": localeIdentifier]
        )
        recordInteractionEvent(interactionEventBus.event(
            surface: .voice,
            kind: .voiceDictationStarted,
            summary: "Started local macOS speech dictation.",
            payload: ["locale": localeIdentifier]
        ))
        dictationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let final = try await self.speechDictation.start(localeIdentifier: localeIdentifier) { partial in
                    self.applyDictationTranscript(partial)
                }
                self.applyDictationTranscript(final)
                self.audit(
                    type: "voice.dictation_finished",
                    summary: "Finished local macOS speech dictation.",
                    metadata: ["characters": String(final.count)]
                )
                self.recordInteractionEvent(self.interactionEventBus.event(
                    surface: .voice,
                    kind: .voiceDictationFinished,
                    summary: "Finished local macOS speech dictation.",
                    payload: ["characters": String(final.count)]
                ))
            } catch {
                self.lastError = error.localizedDescription
                self.audit(
                    type: "voice.dictation_failed",
                    summary: error.localizedDescription,
                    metadata: ["locale": localeIdentifier]
                )
                self.recordInteractionEvent(self.interactionEventBus.event(
                    surface: .voice,
                    kind: .voiceDictationFailed,
                    summary: error.localizedDescription,
                    payload: ["locale": localeIdentifier]
                ))
            }
            if self.connectionState == .listening {
                self.connectionState = self.config.hasLLMKey ? .ready : .offline
            }
            self.dictationTask = nil
            self.saveSessionSnapshot()
        }
    }

    func stopDictation() {
        speechDictation.stop()
    }

    func applyDictationTranscript(_ transcript: String) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationTranscript = clean
        guard !clean.isEmpty else { return }
        draft = dictationBaseText.isEmpty ? clean : "\(dictationBaseText)\n\(clean)"
    }

    func speakAssistantReplyIfEnabled(_ text: String) async {
        guard config.speakAssistantReplies else { return }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        let previousState = connectionState
        connectionState = .speaking
        do {
            let id = try await speechSynthesizer.speak(
                cleanText,
                voiceIdentifier: config.speechVoiceIdentifier.nilIfEmpty
            )
            audit(
                type: "voice.reply_spoken",
                summary: "Assistant reply was spoken aloud.",
                metadata: ["speechID": id, "characters": String(cleanText.count)]
            )
        } catch {
            audit(
                type: "voice.reply_failed",
                summary: error.localizedDescription,
                metadata: ["characters": String(cleanText.count)]
            )
        }
        if connectionState == .speaking {
            connectionState = previousState == .thinking || previousState == .working ? .ready : previousState
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
