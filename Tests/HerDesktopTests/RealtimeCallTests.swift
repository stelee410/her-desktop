import AVFoundation
import XCTest
@testable import HerDesktop

final class RealtimeCallTests: XCTestCase {
    private func pcmTone(
        frequency: Double,
        samples: Int,
        sampleRate: Double = 16_000,
        amplitude: Double = 12_000
    ) -> Data {
        var values = [Int16](repeating: 0, count: samples)
        for index in values.indices {
            values[index] = Int16(sin(2 * .pi * frequency * Double(index) / sampleRate) * amplitude)
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 反向声波: the NLMS canceller must learn a simulated speaker→mic echo
    /// path (20 ms delay, 0.5 gain) and remove most of its energy, while a
    /// simultaneous "user voice" component survives.
    func testEchoCancellerLearnsSimulatedEchoPath() {
        let canceller = CallEchoCanceller()
        let sampleRate = 16_000.0
        let chunk = 320
        let delay = 320 // 20 ms echo path
        let echoGain: Float = 0.5

        // Speech-ish reference: a few drifting sine partials.
        func referenceSample(_ index: Int) -> Float {
            let t = Double(index) / sampleRate
            let wobble = 1 + 0.3 * sin(2 * .pi * 0.7 * t)
            return Float(
                0.30 * sin(2 * .pi * 220 * wobble * t)
                    + 0.20 * sin(2 * .pi * 470 * t)
                    + 0.10 * sin(2 * .pi * 900 * wobble * t)
            )
        }

        var produced = 0
        var lastEchoOnlyRatio: Float = 1
        // 4 seconds of adaptation.
        for _ in 0..<200 {
            var reference = [Float](repeating: 0, count: chunk)
            for offset in 0..<chunk {
                reference[offset] = referenceSample(produced + offset)
            }
            reference.withUnsafeBufferPointer { canceller.writeReference($0) }

            // Mic hears only the delayed, attenuated playback.
            var mic = [Float](repeating: 0, count: chunk)
            for offset in 0..<chunk {
                let sourceIndex = produced + offset - delay
                mic[offset] = sourceIndex >= 0 ? echoGain * referenceSample(sourceIndex) : 0
            }
            let inEnergy = mic.reduce(Float(0)) { $0 + $1 * $1 }
            canceller.process(&mic)
            let outEnergy = mic.reduce(Float(0)) { $0 + $1 * $1 }
            if inEnergy > 0 { lastEchoOnlyRatio = outEnergy / inEnergy }
            produced += chunk
        }

        // Converged: residual echo energy under 10% (>10 dB cancellation).
        XCTAssertLessThan(lastEchoOnlyRatio, 0.1)
        XCTAssertTrue(canceller.isConverged)
    }

    /// Regression for the 打电话 crash: the mic tap block runs on the audio
    /// render thread. If the closure carries main-actor isolation (which it
    /// inherits when formed inside a @MainActor method), the runtime
    /// isolation assert SIGTRAPs on first invoke. Driving the block from a
    /// non-main thread here reproduces exactly that condition.
    func testMicTapBlockIsSafeOffMainThread() async {
        let hwFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)!
        let shared = RealtimeCallController.TapShared()

        let block = RealtimeCallController.makeMicTapBlock(
            shared: shared,
            converter: converter,
            targetFormat: targetFormat,
            sourceSampleRate: hwFormat.sampleRate,
            canceller: CallEchoCanceller()
        )

        let buffer = AVAudioPCMBuffer(pcmFormat: hwFormat, frameCapacity: 960)!
        buffer.frameLength = 960
        let time = AVAudioTime(sampleTime: 0, atRate: hwFormat.sampleRate)

        // Off-main invoke, both unmuted and muted paths. No socket is
        // attached; converted frames are simply dropped.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                XCTAssertFalse(Thread.isMainThread)
                block(buffer, time)
                shared.muted = true
                block(buffer, time)
                continuation.resume()
            }
        }
    }

    func testPlaybackGateTracksQueuedLocalAudioPastServerDone() {
        let shared = RealtimeCallController.TapShared()
        shared.assistantPlaying = true
        shared.schedulePlayback(duration: 1.0, now: 100)
        shared.schedulePlayback(duration: 0.5, now: 100.1)

        // output_audio.done clears the streaming flag, but 1.5 seconds of
        // locally queued audio and its acoustic tail still hold the mic.
        shared.assistantPlaying = false
        XCTAssertTrue(shared.shouldDropMicrophone(at: 101.49))
        XCTAssertTrue(shared.shouldDropMicrophone(at: 102.24))
        XCTAssertFalse(shared.shouldDropMicrophone(at: 102.26))
    }

    func testHardPlaybackGateDropsEvenLoudMicrophoneChunks() async {
        let hwFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)!
        let shared = RealtimeCallController.TapShared()
        shared.assistantPlaying = true
        let block = RealtimeCallController.makeMicTapBlock(
            shared: shared,
            converter: converter,
            targetFormat: targetFormat,
            sourceSampleRate: hwFormat.sampleRate,
            canceller: nil
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: hwFormat, frameCapacity: 960)!
        buffer.frameLength = 960
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = 0.95
        }
        let time = AVAudioTime(sampleTime: 0, atRate: hwFormat.sampleRate)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                block(buffer, time)
                continuation.resume()
            }
        }
        XCTAssertEqual(shared.framesSent, 0, "speaker-level bleed must never bypass the playback gate")
    }

    func testVoiceprintGateReleasesBufferedMatchingUtterance() {
        let engine = SignalVoiceprintEngine()
        let audio = pcmTone(frequency: 440, samples: 24_000)
        let gate = CallVoiceprintGate(enrolled: engine.embed(audio))

        let result = gate.accept(audio)

        XCTAssertFalse(result.rejected)
        XCTAssertNotNil(result.score)
        XCTAssertEqual(result.frames, [audio])
    }

    func testVoiceprintGateRejectsDifferentSignal() {
        let engine = SignalVoiceprintEngine()
        let enrolled = engine.embed(pcmTone(frequency: 220, samples: 24_000))
        let gate = CallVoiceprintGate(enrolled: enrolled)

        let result = gate.accept(pcmTone(frequency: 1_800, samples: 24_000))

        XCTAssertTrue(result.rejected)
        XCTAssertTrue(result.frames.isEmpty)
    }

    func testVoiceprintGateAcceptsMatchingShortPhraseWhenSilenceEndsIt() {
        let engine = SignalVoiceprintEngine()
        let enrollment = pcmTone(frequency: 440, samples: 24_000)
        let shortPhrase = pcmTone(frequency: 440, samples: 7_200) // 0.45 s
        let gate = CallVoiceprintGate(enrolled: engine.embed(enrollment))

        XCTAssertTrue(gate.accept(shortPhrase).frames.isEmpty)
        let result = gate.accept(Data(repeating: 0, count: CallVoiceprintGate.silenceResetBytes))

        XCTAssertFalse(result.rejected)
        XCTAssertNotNil(result.score)
        XCTAssertEqual(result.frames, [shortPhrase])
    }

    func testVoiceprintGateDropsTooShortClickInsteadOfAuthenticatingIt() {
        let engine = SignalVoiceprintEngine()
        let enrollment = pcmTone(frequency: 440, samples: 24_000)
        let gate = CallVoiceprintGate(enrolled: engine.embed(enrollment))

        _ = gate.accept(pcmTone(frequency: 440, samples: 2_000))
        let result = gate.accept(Data(repeating: 0, count: CallVoiceprintGate.silenceResetBytes))

        XCTAssertTrue(result.rejected)
        XCTAssertTrue(result.frames.isEmpty)
    }

    func testVoiceprintProfilePersistsAcrossLaunches() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-voiceprint-\(UUID().uuidString)", isDirectory: true)
        let store = VoiceprintProfileStore(cwd: root.path)
        let profile = VoiceprintProfile(embedding: [0.1, 0.2], sampleCount: 48_000, createdAt: Date(), enabled: true)

        try store.save(profile)

        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.embedding, profile.embedding)
        XCTAssertEqual(restored.sampleCount, profile.sampleCount)
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, profile.createdAt.timeIntervalSince1970, accuracy: 1.0)
    }

    func testVoiceprintEnrollmentUsesVoicedDurationInsteadOfTapCount() {
        let collector = EnrollmentCollector()
        let spokenAudio = pcmTone(frequency: 220, samples: 48_000, amplitude: 1_000)

        // Some Mac devices deliver only a few large tap buffers. The old
        // callback-count check rejected these even with three seconds of
        // clearly non-silent audio.
        let midpoint = spokenAudio.count / 2
        _ = collector.append(spokenAudio.prefix(midpoint))
        let progress = collector.append(spokenAudio.suffix(from: midpoint))

        XCTAssertEqual(progress.percent, 100)
        XCTAssertGreaterThanOrEqual(collector.result.voicedBytes, EnrollmentCollector.minimumVoicedBytes)
        XCTAssertGreaterThanOrEqual(progress.voicedMilliseconds, 2_900)
    }

    func testVoiceprintEnrollmentStillRejectsSilence() {
        let collector = EnrollmentCollector()

        _ = collector.append(Data(repeating: 0, count: EnrollmentCollector.targetBytes))

        XCTAssertEqual(collector.result.voicedBytes, 0)
        XCTAssertEqual(collector.result.maxLevel, 0)
    }

    func testRealtimeConnectionErrorsUseActionableChineseCopy() {
        XCTAssertEqual(
            RealtimeCallController.friendlyConnectionError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            ),
            "连接通话服务超时，请重试。"
        )
        XCTAssertEqual(
            RealtimeCallController.friendlyConnectionError(
                NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: [
                    NSLocalizedDescriptionKey: "Socket is not connected"
                ])
            ),
            "尚未连接到通话服务，请重试。"
        )
    }
}
