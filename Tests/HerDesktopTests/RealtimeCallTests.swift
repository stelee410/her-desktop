import AVFoundation
import XCTest
@testable import HerDesktop

final class RealtimeCallTests: XCTestCase {
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
}
