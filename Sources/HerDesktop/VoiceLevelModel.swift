import AVFoundation
import SwiftUI

/// Live microphone level during dictation, as a small ring buffer the
/// composer's waveform renders. Its own observable so ~20Hz level updates
/// invalidate ONLY the waveform view, never the conversation.
@MainActor
final class VoiceLevelModel: ObservableObject {
    static let sampleCount = 28

    @Published private(set) var samples: [CGFloat] = Array(repeating: 0, count: VoiceLevelModel.sampleCount)

    func push(_ level: CGFloat) {
        var next = samples
        next.removeFirst()
        next.append(min(max(level, 0), 1))
        samples = next
    }

    func reset() {
        samples = Array(repeating: 0, count: Self.sampleCount)
    }
}

/// Dictation backends that can report live input level adopt this; the view
/// model wires the callback before starting, so the protocol stays additive
/// (test fakes don't need to care).
@MainActor
protocol AudioLevelReporting: AnyObject {
    var onAudioLevel: (@MainActor (CGFloat) -> Void)? { get set }
}

/// Shared RMS → display level for a mic buffer (audio-thread safe).
enum AudioLevelMeter {
    static func level(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<frames {
            let sample = data[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        // Speech RMS rarely exceeds ~0.35; scale into a lively 0…1.
        return CGFloat(min(1, rms * 6))
    }

    /// Peak absolute sample value — used to tell "quiet room" (tiny but
    /// non-zero noise floor) apart from "TCC is feeding us digital silence".
    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(data[index]))
        }
        return peak
    }
}
