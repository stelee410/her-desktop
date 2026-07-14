import AVFoundation
import Foundation

struct VoiceprintProfile: Codable, Equatable {
    var embedding: [Float]
    var sampleCount: Int
    var createdAt: Date
    var enabled: Bool
}

final class VoiceprintProfileStore {
    private let url: URL

    init(cwd: String) {
        url = HerWorkspacePaths.localAgentDirectory(cwd: cwd)
            .appendingPathComponent("voiceprint-profile.json")
    }

    func load() -> VoiceprintProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VoiceprintProfile.self, from: data)
    }

    func save(_ profile: VoiceprintProfile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profile).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Lightweight, fully local acoustic signature. This is a convenience
/// speaker filter, not an authentication-grade biometric and not replay-safe.
final class SignalVoiceprintEngine: @unchecked Sendable {
    static let dimension = 16
    private static let sampleRate = 16_000
    private static let window = 320
    private static let hop = 160
    private static let bands = [
        (90, 180), (180, 300), (300, 480), (480, 720), (720, 1_050),
        (1_050, 1_500), (1_500, 2_200), (2_200, 3_200),
        (3_200, 4_500), (4_500, 6_200)
    ]

    func embed(_ pcm16: Data) -> [Float] {
        let samples = Self.samples(pcm16)
        var features = [Float](repeating: 0, count: Self.dimension)
        guard samples.count >= Self.window else { return features }
        var windows = 0
        var rmsTotal = 0.0, rmsSqTotal = 0.0
        var zcrTotal = 0.0, zcrSqTotal = 0.0
        var centroidTotal = 0.0, voiced = 0.0
        var start = 0
        while start + Self.window <= samples.count {
            let rms = Self.rms(samples, start: start, count: Self.window)
            let zcr = Self.zcr(samples, start: start, count: Self.window)
            var centroid = 0.0
            var total = 0.000_001
            for (index, band) in Self.bands.enumerated() {
                let energy = Self.bandEnergy(samples, start: start, count: Self.window, low: band.0, high: band.1)
                features[index] += Float(log1p(energy))
                total += energy
                centroid += energy * Double(band.0 + band.1) * 0.5
            }
            rmsTotal += rms; rmsSqTotal += rms * rms
            zcrTotal += zcr; zcrSqTotal += zcr * zcr
            centroidTotal += centroid / total
            if rms > 450 { voiced += 1 }
            windows += 1
            start += Self.hop
        }
        guard windows > 0 else { return features }
        for index in 0..<Self.bands.count { features[index] /= Float(windows) }
        let rmsMean = rmsTotal / Double(windows)
        let zcrMean = zcrTotal / Double(windows)
        features[10] = Float(log1p(rmsMean))
        features[11] = Float(sqrt(max(0, rmsSqTotal / Double(windows) - rmsMean * rmsMean)))
        features[12] = Float(zcrMean)
        features[13] = Float(sqrt(max(0, zcrSqTotal / Double(windows) - zcrMean * zcrMean)))
        features[14] = Float(centroidTotal / Double(windows) / Double(Self.sampleRate))
        features[15] = Float(voiced / Double(windows))
        Self.normalize(&features)
        return features
    }

    func score(_ enrolled: [Float], _ candidate: [Float]) -> Float {
        let count = min(enrolled.count, candidate.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0, lhs: Float = 0, rhs: Float = 0
        for index in 0..<count {
            dot += enrolled[index] * candidate[index]
            lhs += enrolled[index] * enrolled[index]
            rhs += candidate[index] * candidate[index]
        }
        guard lhs > 0, rhs > 0 else { return 0 }
        return dot / sqrt(lhs * rhs)
    }

    static func averageAbsolute(_ data: Data) -> Int {
        let values = samples(data)
        guard !values.isEmpty else { return 0 }
        var total: Int64 = 0
        for value in values { total += Int64(abs(Int(value))) }
        return Int(total / Int64(values.count))
    }

    private static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            return values.map { Int16(littleEndian: $0) }
        }
    }

    private static func rms(_ samples: [Int16], start: Int, count: Int) -> Double {
        var sum = 0.0
        for index in start..<(start + count) { let value = Double(samples[index]); sum += value * value }
        return sqrt(sum / Double(count))
    }

    private static func zcr(_ samples: [Int16], start: Int, count: Int) -> Double {
        var crossings = 0
        for index in (start + 1)..<(start + count) {
            if (samples[index - 1] < 0) != (samples[index] < 0) { crossings += 1 }
        }
        return Double(crossings) / Double(max(1, count - 1))
    }

    private static func bandEnergy(_ samples: [Int16], start: Int, count: Int, low: Int, high: Int) -> Double {
        let lowBin = max(1, Int(round(Double(low * count) / Double(sampleRate))))
        let highBin = max(lowBin, Int(round(Double(high * count) / Double(sampleRate))))
        var sum = 0.0
        for bin in lowBin...highBin {
            var real = 0.0, imaginary = 0.0
            let step = -2 * Double.pi * Double(bin) / Double(count)
            for offset in 0..<count {
                let angle = step * Double(offset)
                let sample = Double(samples[start + offset])
                real += sample * cos(angle); imaginary += sample * sin(angle)
            }
            sum += real * real + imaginary * imaginary
        }
        return sum / Double(max(1, highBin - lowBin + 1))
    }

    private static func normalize(_ values: inout [Float]) {
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return }
        for index in values.indices { values[index] /= norm }
    }
}

/// Per-utterance gate: buffer the beginning, verify it, release the buffered
/// audio only on a match, then reset after a sustained silence.
final class CallVoiceprintGate: @unchecked Sendable {
    struct Result { var frames: [Data]; var score: Float?; var rejected: Bool }
    static let minimumShortBytes = 12_800 // 0.4 s, checked when the phrase ends
    static let earlyVerifyBytes = 19_200 // 0.6 s, high-confidence fast path
    static let targetVerifyBytes = 32_000 // 1.0 s, relaxed final decision
    static let shortThreshold: Float = 0.64
    static let earlyThreshold: Float = 0.60
    static let finalThreshold: Float = 0.52
    static let silenceResetBytes = 12_800 // 0.4 s
    private let enrolled: [Float]
    private let engine = SignalVoiceprintEngine()
    private var buffered = Data()
    private var frames: [Data] = []
    private var decision: Bool?
    private var silenceBytes = 0
    private var triedEarlyDecision = false

    init(enrolled: [Float]) { self.enrolled = enrolled }

    func accept(_ data: Data) -> Result {
        let quiet = SignalVoiceprintEngine.averageAbsolute(data) < 180

        if decision == true {
            if quiet {
                silenceBytes += data.count
                if silenceBytes >= Self.silenceResetBytes { resetUtterance() }
                return Result(frames: [], score: nil, rejected: false)
            }
            silenceBytes = 0
            return Result(frames: [data], score: nil, rejected: false)
        }
        if decision == false {
            if quiet {
                silenceBytes += data.count
                if silenceBytes >= Self.silenceResetBytes { resetUtterance() }
            } else {
                silenceBytes = 0
            }
            return Result(frames: [], score: nil, rejected: true)
        }

        if quiet {
            guard !buffered.isEmpty else { return Result(frames: [], score: nil, rejected: false) }
            silenceBytes += data.count
            guard silenceBytes >= Self.silenceResetBytes else {
                return Result(frames: [], score: nil, rejected: false)
            }
            let candidateFrames = frames
            let candidate = buffered
            resetUtterance()
            guard candidate.count >= Self.minimumShortBytes else {
                return Result(frames: [], score: nil, rejected: true)
            }
            let score = engine.score(enrolled, engine.embed(candidate))
            let accepted = score >= Self.shortThreshold
            return Result(frames: accepted ? candidateFrames : [], score: score, rejected: !accepted)
        }

        silenceBytes = 0
        buffered.append(data)
        frames.append(data)

        if !triedEarlyDecision, buffered.count >= Self.earlyVerifyBytes {
            triedEarlyDecision = true
            let score = engine.score(enrolled, engine.embed(buffered))
            if score >= Self.earlyThreshold {
                decision = true
                let released = frames
                frames.removeAll(keepingCapacity: true)
                buffered.removeAll(keepingCapacity: true)
                return Result(frames: released, score: score, rejected: false)
            }
        }

        guard buffered.count >= Self.targetVerifyBytes else {
            return Result(frames: [], score: nil, rejected: false)
        }
        let score = engine.score(enrolled, engine.embed(buffered))
        decision = score >= Self.finalThreshold
        if decision == true {
            let released = frames
            frames.removeAll(keepingCapacity: true)
            buffered.removeAll(keepingCapacity: true)
            return Result(frames: released, score: score, rejected: false)
        }
        frames.removeAll(keepingCapacity: true)
        buffered.removeAll(keepingCapacity: true)
        return Result(frames: [], score: score, rejected: true)
    }

    private func resetUtterance() {
        buffered.removeAll(keepingCapacity: true); frames.removeAll(keepingCapacity: true)
        decision = nil; silenceBytes = 0; triedEarlyDecision = false
    }
}

/// The audio tap is invoked by AVFAudio on its realtime service queue. Keep
/// this service nonisolated: an actor-isolated tap closure traps at runtime
/// before it can process the first microphone buffer.
final class VoiceprintEnrollmentService: @unchecked Sendable {
    struct Progress: Sendable {
        var percent: Int
        var level: Int
        var voicedMilliseconds: Int
    }

    enum EnrollmentError: LocalizedError {
        case microphoneDenied, couldNotStart, tooQuiet(maxLevel: Int)
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "没有麦克风权限，无法录入声纹。"
            case .couldNotStart: return "无法启动麦克风录入声纹。"
            case let .tooQuiet(maxLevel):
                return "没有检测到足够的说话声（最高音量 \(maxLevel)）。请确认输入设备后，靠近麦克风持续说话约 3 秒。"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let signature = SignalVoiceprintEngine()

    func enroll(onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws -> VoiceprintProfile {
        guard await AVAudioApplication.requestRecordPermission() else { throw EnrollmentError.microphoneDenied }
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { throw EnrollmentError.couldNotStart }
        let collector = EnrollmentCollector()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2_048, format: source) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / source.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var pulled = false
            converter.convert(to: converted, error: nil) { _, status in
                if pulled { status.pointee = .noDataNow; return nil }
                pulled = true; status.pointee = .haveData; return buffer
            }
            guard converted.frameLength > 0, let channel = converted.int16ChannelData else { return }
            let data = Data(bytes: channel[0], count: Int(converted.frameLength) * 2)
            let update = collector.append(data)
            Task { @MainActor in onProgress(update) }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw EnrollmentError.couldNotStart }
        while collector.progress < 100 { try await Task.sleep(nanoseconds: 100_000_000) }
        engine.stop(); input.removeTap(onBus: 0)
        let result = collector.result
        guard result.voicedBytes >= EnrollmentCollector.minimumVoicedBytes else {
            throw EnrollmentError.tooQuiet(maxLevel: result.maxLevel)
        }
        let audio = result.audio
        return VoiceprintProfile(embedding: signature.embed(audio), sampleCount: audio.count / 2, createdAt: Date(), enabled: true)
    }
}

final class EnrollmentCollector: @unchecked Sendable {
    struct Result: Sendable {
        var audio: Data
        var voicedBytes: Int
        var maxLevel: Int
    }

    private let lock = NSLock()
    private var data = Data()
    private var voicedBytes = 0
    private var maxLevel = 0
    static let targetBytes = 96_000
    /// Count voiced duration, not callback count, because AVAudio tap block
    /// sizes vary by device and sample rate. Keep the proven PCM16 voice
    /// threshold high enough that built-in microphone room noise cannot enroll.
    static let minimumVoiceLevel = 420
    static let minimumVoicedBytes = 22_400 // 0.7 s at PCM16 16 kHz mono
    var progress: Int { lock.withLock { min(100, data.count * 100 / Self.targetBytes) } }
    var result: Result { lock.withLock { Result(audio: data, voicedBytes: voicedBytes, maxLevel: maxLevel) } }

    func append(_ chunk: Data) -> VoiceprintEnrollmentService.Progress {
        lock.withLock {
            let level = SignalVoiceprintEngine.averageAbsolute(chunk)
            maxLevel = max(maxLevel, level)
            if data.count < Self.targetBytes {
                let accepted = chunk.prefix(Self.targetBytes - data.count)
                data.append(accepted)
                if level >= Self.minimumVoiceLevel { voicedBytes += accepted.count }
            }
            return VoiceprintEnrollmentService.Progress(
                percent: min(100, data.count * 100 / Self.targetBytes),
                level: level,
                voicedMilliseconds: voicedBytes * 1_000 / 32_000
            )
        }
    }
}
