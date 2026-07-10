import Accelerate
import Foundation

/// 反向声波回灌抑制: software acoustic echo cancellation for calls.
///
/// The engine's real output — tapped at playout time — is the reference; an
/// NLMS adaptive filter estimates the speaker→mic echo path and subtracts
/// the predicted echo from each mic chunk. Both taps run at 16 kHz mono
/// float in [-1, 1].
///
/// Fail-safe by construction: a chunk is only replaced when cancellation
/// actually reduced its energy; otherwise the original samples pass through
/// and the filter leaks toward zero. A diverged filter can therefore never
/// corrupt the outgoing audio for long.
final class CallEchoCanceller: @unchecked Sendable {
    /// 64 ms of echo-path coverage at 16 kHz — comfortably spans device
    /// output+input latency plus the acoustic path on a laptop.
    private let taps: Int
    private let ringSize: Int
    private var weights: [Float]
    private var ring: [Float]
    /// Total reference samples ever written (ring head).
    private var writeCount = 0
    private let lock = NSLock()
    /// Smoothed linear in/out energy ratio of recent processed chunks.
    private var gain: Float = 1

    init(taps: Int = 1_024, ringSeconds: Double = 2, sampleRate: Double = 16_000) {
        self.taps = taps
        self.ringSize = max(Int(sampleRate * ringSeconds), taps * 4)
        self.weights = [Float](repeating: 0, count: taps)
        self.ring = [Float](repeating: 0, count: ringSize)
    }

    /// True once the filter demonstrably removes energy (~3 dB+): the
    /// half-duplex gate can then relax and let soft barge-in through.
    var isConverged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gain > 2
    }

    /// Called from the OUTPUT tap with what is actually playing right now.
    func writeReference(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        for sample in samples {
            ring[writeCount % ringSize] = sample
            writeCount += 1
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        weights = [Float](repeating: 0, count: taps)
        gain = 1
        writeCount = 0
        ring = [Float](repeating: 0, count: ringSize)
        lock.unlock()
    }

    /// Cancels echo from one mic chunk in place. The chunk's last sample is
    /// assumed to align with the freshest reference sample (both taps run on
    /// the same wall clock; the filter absorbs the residual 0–60 ms lag).
    func process(_ mic: inout [Float]) {
        lock.lock()
        defer { lock.unlock() }
        let count = mic.count
        let span = taps + count - 1
        guard count > 0, writeCount >= span, span < ringSize else { return }

        // Materialize the reference span (oldest → newest).
        var reference = [Float](repeating: 0, count: span)
        let start = writeCount - span
        for offset in 0..<span {
            reference[offset] = ring[(start + offset) % ringSize]
        }
        var referenceEnergy: Float = 0
        vDSP_svesq(reference, 1, &referenceEnergy, vDSP_Length(span))
        // Nothing was playing — no echo to remove, keep the filter frozen.
        guard referenceEnergy > 1e-6 else { return }

        var inputEnergy: Float = 0
        vDSP_svesq(mic, 1, &inputEnergy, vDSP_Length(count))

        var cleaned = [Float](repeating: 0, count: count)
        let mu: Float = 0.4
        let epsilon: Float = 1e-4
        // Running ||x||² over the sliding window.
        var windowNorm: Float = 0
        vDSP_svesq(reference, 1, &windowNorm, vDSP_Length(taps))
        reference.withUnsafeBufferPointer { ref in
            let base = ref.baseAddress!
            for index in 0..<count {
                var predicted: Float = 0
                vDSP_dotpr(base + index, 1, weights, 1, &predicted, vDSP_Length(taps))
                let error = mic[index] - predicted
                cleaned[index] = error
                var step = mu * error / (windowNorm + epsilon)
                weights.withUnsafeMutableBufferPointer { w in
                    vDSP_vsma(base + index, 1, &step, w.baseAddress!, 1, w.baseAddress!, 1, vDSP_Length(taps))
                }
                // Slide the norm window one sample forward.
                if index + 1 < count {
                    let leaving = base[index]
                    let entering = base[index + taps]
                    windowNorm += entering * entering - leaving * leaving
                    if windowNorm < 0 { windowNorm = 0 }
                }
            }
        }

        var outputEnergy: Float = 0
        vDSP_svesq(cleaned, 1, &outputEnergy, vDSP_Length(count))
        if outputEnergy <= inputEnergy {
            mic = cleaned
            let chunkGain = inputEnergy / max(outputEnergy, 1e-9)
            gain = gain * 0.8 + min(chunkGain, 100) * 0.2
        } else {
            // Diverging — pass the original through and bleed the filter.
            var leak: Float = 0.85
            vDSP_vsmul(weights, 1, &leak, &weights, 1, vDSP_Length(taps))
            gain = gain * 0.8 + 0.2
        }
    }
}
