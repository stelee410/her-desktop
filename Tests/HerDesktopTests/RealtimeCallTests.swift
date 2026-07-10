import AVFoundation
import XCTest
@testable import HerDesktop

final class RealtimeCallTests: XCTestCase {
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
            sourceSampleRate: hwFormat.sampleRate
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
