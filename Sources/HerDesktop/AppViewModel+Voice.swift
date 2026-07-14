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
        // Mic capture and local TTS must never overlap. macOS feeds speaker
        // output back into many built-in/external microphones, so leaving TTS
        // alive here lets the assistant transcribe its own reply and creates
        // a conversation loop. Starting dictation is also our barge-in path:
        // stop either playback backend immediately, then open the mic.
        speechTask?.cancel()
        speechTask = nil
        baseSpeechSynthesizer.stop()
        agentLLMSpeechSynthesizer.stop()
        dictationTask?.cancel()
        dictationBaseText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationTranscript = ""
        connectionState = .listening
        lastError = nil
        // Wire the live mic level into the composer waveform.
        voiceLevel.reset()
        (speechDictation as? AudioLevelReporting)?.onAudioLevel = { [weak voiceLevel] level in
            voiceLevel?.push(level)
        }
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
            self.voiceLevel.reset()
            self.saveSessionSnapshot()
        }
    }

    func stopDictation() {
        speechDictation.stop()
    }

    // MARK: - Push-to-talk (hold Space)

    /// Hold Space to talk, release to stop — the recognized text lands in
    /// the composer. A short tap still types one space; key-repeat while
    /// holding never floods the field with spaces.
    func installPushToTalkMonitors() {
        guard pushToTalkMonitors.isEmpty else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local event monitors always run on the main thread; NSEvent is
            // not Sendable, so bridge it in and return only a Sendable Bool.
            nonisolated(unsafe) let event = event
            let swallow = MainActor.assumeIsolated {
                self?.consumeSpaceEvent(event) ?? false
            }
            return swallow ? nil : event
        }
        if let monitor {
            pushToTalkMonitors.append(monitor)
        }
    }

    func removePushToTalkMonitors() {
        for monitor in pushToTalkMonitors {
            NSEvent.removeMonitor(monitor)
        }
        pushToTalkMonitors.removeAll()
        spaceHoldTask?.cancel()
        spaceHoldTask = nil
        spaceHoldPending = false
    }

    private static let spaceKeyCode: UInt16 = 49
    private static let holdThreshold: TimeInterval = 0.8

    /// true = swallow the event; false = pass it through.
    func consumeSpaceEvent(_ event: NSEvent) -> Bool {
        // Scope: main window only (not sheets), Today section, and either
        // the composer owns focus or no other text input does.
        guard event.window?.sheetParent == nil,
              selectedSection == .today,
              !isVibePluginComposerPresented else {
            return false
        }
        let focusedTextView = event.window?.firstResponder as? NSTextView
        guard composerFocused || focusedTextView == nil else { return false }
        // While an input method is composing (拼音选字), Space commits the
        // candidate — it must reach the IME untouched, never push-to-talk.
        if let focusedTextView, focusedTextView.hasMarkedText() {
            cancelSpaceHold(insertSpace: false)
            return false
        }

        if event.type == .keyDown, event.keyCode == Self.spaceKeyCode {
            // Holding the key streams repeats — always swallow them so a
            // long press can never type a run of spaces.
            if event.isARepeat { return true }
            guard !isPushToTalking, connectionState != .listening else { return true }
            spaceHoldPending = true
            spaceHoldTask?.cancel()
            spaceHoldTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.holdThreshold * 1_000_000_000))
                guard let self, !Task.isCancelled, self.spaceHoldPending else { return }
                self.spaceHoldPending = false
                self.isPushToTalking = true
                self.startDictation()
            }
            return true
        }

        if event.type == .keyDown, spaceHoldPending {
            // Another key while the space decision is pending: it was
            // typing, not talking — flush the deferred space first so the
            // character order stays right.
            cancelSpaceHold(insertSpace: true)
            return false
        }

        if event.type == .keyUp, event.keyCode == Self.spaceKeyCode {
            if isPushToTalking {
                isPushToTalking = false
                stopDictation()
                return true
            }
            if spaceHoldPending {
                // Short tap: behave like a normal space.
                cancelSpaceHold(insertSpace: true)
                return true
            }
        }
        return false
    }

    private func cancelSpaceHold(insertSpace: Bool) {
        spaceHoldTask?.cancel()
        spaceHoldTask = nil
        spaceHoldPending = false
        if insertSpace, composerFocused {
            draft += " "
        }
    }

    func applyDictationTranscript(_ transcript: String) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationTranscript = clean
        guard !clean.isEmpty else { return }
        draft = dictationBaseText.isEmpty ? clean : "\(dictationBaseText)\n\(clean)"
    }

    func speakAssistantReplyIfEnabled(_ text: String) async {
        guard config.speakAssistantReplies else { return }
        await speakTextAloud(text)
    }

    /// Speak arbitrary text now (per-message 朗读 button + auto-speak both
    /// land here) through the configured TTS backend.
    func speakTextAloud(_ text: String) async {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        // Close the microphone before any speaker audio starts. This is the
        // other half of the no-overlap invariant enforced by startDictation.
        if connectionState == .listening {
            isPushToTalking = false
            stopDictation()
        }
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
            lastError = error.localizedDescription
            audit(
                type: "voice.reply_failed",
                summary: error.localizedDescription,
                metadata: ["characters": String(cleanText.count)]
            )
        }
        // A cancelled run (the user tapped another bubble) must not clobber
        // the state the replacement run just set.
        if !Task.isCancelled, connectionState == .speaking {
            connectionState = previousState == .thinking || previousState == .working ? .ready : previousState
        }
    }

    /// Toggle for the per-bubble 朗读 button: tap to speak, tap again to
    /// stop. Tapping a different bubble while one is playing switches to it.
    func toggleSpeakMessage(_ text: String, messageID: UUID) {
        let wasSpeakingThisMessage = speakingMessageID == messageID
        speechTask?.cancel()
        speechTask = nil
        baseSpeechSynthesizer.stop()
        agentLLMSpeechSynthesizer.stop()
        speakingMessageID = nil
        if wasSpeakingThisMessage {
            if connectionState == .speaking {
                connectionState = config.hasLLMKey ? .ready : .offline
            }
            return
        }
        speakingMessageID = messageID
        speechTask = Task {
            await speakTextAloud(text)
            if speakingMessageID == messageID {
                speakingMessageID = nil
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
