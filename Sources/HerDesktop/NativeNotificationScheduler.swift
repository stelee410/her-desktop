import Foundation
import AVFoundation
import Speech
import UserNotifications

@MainActor
protocol NativeNotificationScheduling {
    func schedule(title: String, body: String, delaySeconds: TimeInterval) async throws -> String
}

@MainActor
protocol NativeSpeechDictating {
    func start(localeIdentifier: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> String
    func stop()
}

@MainActor
final class MacSpeechDictationService: NSObject, NativeSpeechDictating, AudioLevelReporting {
    var onAudioLevel: (@MainActor (CGFloat) -> Void)?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var latestTranscript = ""
    private var captureStats: AudioCaptureStats?
    private var captureSampleRate: Double = 48_000

    func start(localeIdentifier: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await requestPermissions()
        stop()
        latestTranscript = ""

        let locale = Locale(identifier: localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Locale.current.identifier : localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        // The tap fires on the CoreAudio render thread. Appending directly is
        // the documented usage (the request is thread-safe for append); the
        // closure must NOT inherit @MainActor isolation — an inherited
        // isolation assertion on a realtime audio thread is a crash.
        nonisolated(unsafe) let tapRequest = request
        // Level callback snapshotted before start; reported at ~1/3 buffer
        // rate so the waveform updates ~15Hz without flooding the main actor.
        let levelHandler = onAudioLevel
        let levelCounter = TapCounter()
        let stats = AudioCaptureStats()
        captureStats = stats
        captureSampleRate = format.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            tapRequest.append(buffer)
            stats.record(peak: AudioLevelMeter.peak(of: buffer), frames: Int(buffer.frameLength))
            if let levelHandler, levelCounter.shouldSample() {
                let level = AudioLevelMeter.level(of: buffer)
                Task { @MainActor in levelHandler(level) }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // The result handler fires on a Speech-framework background
            // queue: keep the closure @Sendable (no inherited @MainActor
            // isolation → no runtime assertion crash), extract Sendable
            // values there, then hop to the main actor for state.
            self.recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let transcript = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self else { return }
                    if let transcript {
                        self.latestTranscript = transcript
                        onPartial(transcript)
                        if isFinal {
                            self.finish(.success(transcript))
                        }
                    }
                    if let error {
                        self.finish(.failure(error))
                    }
                }
            }
        }
    }

    func stop() {
        guard audioEngine.isRunning || recognitionTask != nil || recognitionRequest != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        if latestTranscript.isEmpty,
           captureStats?.capturedOnlySilence(sampleRate: captureSampleRate) == true {
            // All-zero capture: stale TCC grant (signature changed since the
            // permission was given) — say so instead of returning "".
            finish(.failure(DictationError.silentMicrophone))
        } else {
            finish(.success(latestTranscript))
        }
        captureStats = nil
    }

    private func requestPermissions() async throws {
        // @Sendable is load-bearing: a plain closure formed in this
        // @MainActor context inherits main-actor isolation, but TCC invokes
        // the callback on a background XPC queue — the Swift 6 runtime
        // isolation assertion then crashes (dispatch_assert_queue_fail).
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw DictationError.speechPermissionDenied
        }

        let microphoneGranted = await AVAudioApplication.requestRecordPermission()
        guard microphoneGranted else {
            throw DictationError.microphonePermissionDenied
        }
    }

    private func finish(_ result: Result<String, Error>) {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let transcript):
            continuation.resume(returning: transcript)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    enum DictationError: LocalizedError {
        case speechPermissionDenied
        case microphonePermissionDenied
        case recognizerUnavailable
        case silentMicrophone

        var errorDescription: String? {
            switch self {
            case .speechPermissionDenied:
                return "Speech recognition permission was not granted."
            case .microphonePermissionDenied:
                return "Microphone permission was not granted."
            case .recognizerUnavailable:
                return "Speech recognizer is not available for the selected locale."
            case .silentMicrophone:
                return "麦克风只收到了静音——请在 系统设置 → 隐私与安全性 → 麦克风 中重新为 Her Desktop 授权后再试。"
            }
        }
    }
}

final class UserNotificationScheduler: NativeNotificationScheduling {
    func schedule(title: String, body: String, delaySeconds: TimeInterval) async throws -> String {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else {
            throw NotificationError.permissionDenied
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let interval = max(delaySeconds, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let id = "her-native-notify-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try await center.add(request)
        return id
    }

    enum NotificationError: LocalizedError {
        case permissionDenied

        var errorDescription: String? {
            "Notification permission was not granted."
        }
    }
}

/// Thread-safe modulo counter for audio-tap sampling.
final class TapCounter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()

    func shouldSample(every n: Int = 3) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count % n == 0
    }
}

/// Peak/duration accounting for a capture session, written from the CoreAudio
/// render thread and read on the main actor after the session ends. Detects
/// the "granted but silent" microphone state: a stale TCC grant (e.g. after
/// the app's code signature changed) makes CoreAudio deliver all-zero buffers
/// while the permission API still reports authorized.
final class AudioCaptureStats: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var frames = 0

    func record(peak newPeak: Float, frames newFrames: Int) {
        lock.lock()
        peak = max(peak, newPeak)
        frames += newFrames
        lock.unlock()
    }

    /// True when at least `minSeconds` of audio was captured and every single
    /// sample was digital zero — real rooms always have a noise floor.
    func capturedOnlySilence(sampleRate: Double, minSeconds: Double = 0.5) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Double(frames) >= sampleRate * minSeconds && peak == 0
    }
}

@MainActor
protocol NativeSpeechSynthesizing {
    func speak(_ text: String, voiceIdentifier: String?) async throws -> String
    func stop()
}

@MainActor
final class MacSpeechSynthesizer: NSObject, NativeSpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    private var continuation: CheckedContinuation<String, Error>?
    private var utteranceID: String?

    func speak(_ text: String, voiceIdentifier: String?) async throws -> String {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            throw SpeechError.emptyText
        }

        stop()

        let utteranceID = "her-speech-\(UUID().uuidString)"
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: cleanText)
        if let voiceIdentifier, !voiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        }
        synthesizer.delegate = self
        self.synthesizer = synthesizer
        self.utteranceID = utteranceID

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        finishSpeech(.success(utteranceID ?? "stopped"))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            finishSpeech(.success(utteranceID ?? "finished"))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            finishSpeech(.failure(SpeechError.interrupted))
        }
    }

    private func finishSpeech(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        synthesizer?.delegate = nil
        synthesizer = nil
        let id = utteranceID
        utteranceID = nil
        switch result {
        case .success:
            continuation.resume(returning: id ?? "speech-complete")
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    enum SpeechError: LocalizedError {
        case emptyText
        case couldNotStart
        case interrupted

        var errorDescription: String? {
            switch self {
            case .emptyText:
                return "No text was provided for speech."
            case .couldNotStart:
                return "macOS speech synthesis could not start."
            case .interrupted:
                return "Speech was interrupted."
            }
        }
    }
}
