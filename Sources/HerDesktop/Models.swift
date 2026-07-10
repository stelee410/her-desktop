import Foundation
import SwiftUI

enum ConnectionState: String, Codable {
    case offline
    case ready
    case listening
    case thinking
    case speaking
    case working
    case error
}

enum WorkspaceSection: String, CaseIterable, Identifiable, Codable, Equatable {
    case today
    case memory
    case projects
    case apps
    case tools
    case agents
    case characters
    case worldBooks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今天"
        case .memory: return "记忆"
        case .projects: return "项目"
        case .apps: return "应用"
        case .tools: return "工具"
        case .agents: return "智能体"
        case .characters: return "角色卡"
        case .worldBooks: return "世界之书"
        }
    }

    var systemImage: String {
        switch self {
        case .today: return "sun.max"
        case .memory: return "doc.text"
        case .projects: return "briefcase"
        case .apps: return "macwindow.on.rectangle"
        case .tools: return "square.grid.2x2"
        case .agents: return "circle.hexagongrid"
        case .characters: return "theatermasks"
        case .worldBooks: return "book.closed"
        }
    }
}

enum MessageRole: String, Codable, Identifiable {
    case user
    case assistant
    case system
    case tool

    var id: String { rawValue }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: MessageRole
    var content: String
    var reasoning: String = ""
    var approvalID: UUID?
    var createdAt: Date = Date()
    var attachments: [MessageAttachment] = []
    /// Pure UI feedback ("新会话已经准备好", key-saved confirmations, …):
    /// shown in the transcript but NEVER sent to the model — it isn't
    /// conversation content and shouldn't spend context-window slots.
    var localOnly: Bool = false
    /// A compaction summary (/compact). It stays visible in the transcript
    /// and marks the context boundary: everything before the latest recap is
    /// no longer injected into the model; the recap text itself is folded
    /// into the system prompt instead.
    var recap: Bool = false

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        reasoning: String = "",
        approvalID: UUID? = nil,
        createdAt: Date = Date(),
        attachments: [MessageAttachment] = [],
        localOnly: Bool = false,
        recap: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.approvalID = approvalID
        self.createdAt = createdAt
        self.attachments = attachments
        self.localOnly = localOnly
        self.recap = recap
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case reasoning
        case approvalID
        case createdAt
        case attachments
        case localOnly
        case recap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        approvalID = try container.decodeIfPresent(UUID.self, forKey: .approvalID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        localOnly = try container.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
        recap = try container.decodeIfPresent(Bool.self, forKey: .recap) ?? false
    }
}

struct MessageAttachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case text
        case image
        case video
        case audio
        case pdf
        case archive
        case other
    }

    var id: UUID = UUID()
    var originalName: String
    var storedPath: String
    var kind: Kind
    var mimeType: String?
    var byteCount: Int64
    var summary: String
    var textPreview: String?

    var displayName: String {
        originalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? storedPath : originalName
    }

    var contextDescription: String {
        var lines = [
            "- \(displayName)",
            "  kind: \(kind.rawValue)",
            "  bytes: \(byteCount)",
            "  stored_path: \(storedPath)",
            "  summary: \(summary)"
        ]
        if let mimeType, !mimeType.isEmpty {
            lines.insert("  mime_type: \(mimeType)", at: 3)
        }
        if let textPreview, !textPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("  \(previewLabel):")
            lines.append(textPreview.indentedForAttachmentContext())
        }
        return lines.joined(separator: "\n")
    }

    private var previewLabel: String {
        switch kind {
        case .image: return "visual_metadata"
        case .video, .audio: return "media_metadata"
        default: return "text_preview"
        }
    }
}

extension Array where Element == MessageAttachment {
    var contextDescription: String {
        guard !isEmpty else { return "" }
        return """
        Attached files:
        \(map(\.contextDescription).joined(separator: "\n"))
        """
    }
}

private extension String {
    func indentedForAttachmentContext() -> String {
        components(separatedBy: .newlines)
            .prefix(80)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }
}

struct RunningTask: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var progress: Double
    var state: String
}

enum WorkPlanStepStatus: String, Codable, CaseIterable, Equatable {
    case pending
    case inProgress = "in_progress"
    case done
    case blocked

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "In progress"
        case .done: return "Done"
        case .blocked: return "Blocked"
        }
    }
}

struct WorkPlan: Identifiable, Codable, Equatable {
    struct Step: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var title: String
        var status: WorkPlanStepStatus
        var detail: String?

        init(
            id: UUID = UUID(),
            title: String,
            status: WorkPlanStepStatus = .pending,
            detail: String? = nil
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.detail = detail
        }
    }

    var id: UUID = UUID()
    var goal: String
    var source: String
    var steps: [Step]
    var risks: [String]
    var verification: [String]
    var updatedAt: Date = Date()

    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        let completed = steps.filter { $0.status == .done }.count
        let active = steps.filter { $0.status == .inProgress }.count
        return min(1, (Double(completed) + Double(active) * 0.5) / Double(steps.count))
    }

    var stateSummary: String {
        guard !steps.isEmpty else { return "No steps" }
        let done = steps.filter { $0.status == .done }.count
        let blocked = steps.filter { $0.status == .blocked }.count
        if blocked > 0 {
            return "\(blocked) blocked, \(done)/\(steps.count) done"
        }
        if steps.contains(where: { $0.status == .inProgress }) {
            return "In progress, \(done)/\(steps.count) done"
        }
        return "\(done)/\(steps.count) done"
    }
}

enum CapabilityActivityStatus: String, Codable, Equatable {
    case pending
    case running
    case done
    case failed
    case denied
}

struct CapabilityActivity: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var capabilityID: String
    var functionName: String
    var title: String
    var status: CapabilityActivityStatus
    var summary: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct MemorySignal: Codable, Equatable {
    var trust: Double
    var confidence: Double
    var moodLabel: String
    var relationshipSummary: String

    static let empty = MemorySignal(
        trust: 0.72,
        confidence: 0.68,
        moodLabel: "Calm",
        relationshipSummary: "Warming up"
    )

    static func fromAgentMemV7(
        relationship: [String: Any],
        emotion: [String: Any]?,
        fallback: MemorySignal = .empty
    ) -> MemorySignal {
        let bond = relationship["bond"] as? [String: Any]
        let trust = normalizedScore(doubleValue(bond?["trust"])) ?? fallback.trust
        let familiarity = normalizedScore(doubleValue(bond?["familiarity"])) ?? fallback.confidence
        let mood = emotionMoodLabel(emotion) ?? fallback.moodLabel
        let summary = relationshipSummary(relationship: relationship, emotion: emotion)
            ?? fallback.relationshipSummary
        return MemorySignal(
            trust: trust,
            confidence: familiarity,
            moodLabel: mood,
            relationshipSummary: summary
        )
    }

    func mergedWithRetrieval(count: Int, firstScore: Double) -> MemorySignal {
        let memoryPrefix = "\(count) memories nearby"
        let summary: String
        if relationshipSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary = memoryPrefix
        } else if relationshipSummary.contains(memoryPrefix) {
            summary = relationshipSummary
        } else {
            summary = "\(memoryPrefix) · \(relationshipSummary)"
        }
        return MemorySignal(
            trust: min(0.98, max(trust, max(0.48, firstScore))),
            confidence: min(0.96, max(confidence, 0.68 + Double(count) * 0.03)),
            moodLabel: moodLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Grounded" : moodLabel,
            relationshipSummary: summary
        )
    }

    private static func relationshipSummary(relationship: [String: Any], emotion: [String: Any]?) -> String? {
        var pieces: [String] = []
        if let stageLabel = stringValue(relationship["stage_label"]) {
            pieces.append("relationship \(stageLabel)")
        } else if let stage = stringValue(relationship["stage"]) {
            pieces.append("relationship \(stage)")
        }
        if let bond = relationship["bond"] as? [String: Any],
           let affection = doubleValue(bond["affection"]) {
            pieces.append("affection \(formatScore(affection))/10")
        }
        if let mood = emotion?["mood"] as? [String: Any],
           let label = stringValue(mood["label"]) {
            var moodPiece = "recent mood \(label)"
            if let valence = doubleValue(mood["mean_valence"]) {
                moodPiece += " · valence \(formatScore(valence))"
            }
            if let arousal = doubleValue(mood["mean_arousal"]) {
                moodPiece += " · arousal \(formatScore(arousal))"
            }
            pieces.append(moodPiece)
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    private static func emotionMoodLabel(_ emotion: [String: Any]?) -> String? {
        guard let emotion else { return nil }
        if let mood = emotion["mood"] as? [String: Any],
           let label = stringValue(mood["label"]) {
            return label
        }
        if let state = emotion["state"] as? [String: Any] {
            return stringValue(state["label"]) ?? stringValue(state["current"])
        }
        return nil
    }

    private static func normalizedScore(_ raw: Double?) -> Double? {
        guard let raw else { return nil }
        if raw > 1 {
            return min(1, max(0, raw / 10))
        }
        return min(1, max(0, raw))
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(describing: raw)
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func formatScore(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct AgentProfile: Codable, Equatable {
    var displayName: String
    var userDisplayName: String
    var relationship: String
    var memoryID: String
    var known: Bool

    static func empty(userID: String = "local-user") -> AgentProfile {
        AgentProfile(
            displayName: "Her",
            userDisplayName: userID,
            relationship: "Warming up",
            memoryID: "",
            known: false
        )
    }

    static func fromRelationshipPayload(_ object: [String: Any], fallbackUserID: String) -> AgentProfile {
        let stage = stringValue(object["stage"])
        let bond = object["bond"] as? [String: Any]
        let known = boolValue(object["known"]) ?? stage.map { $0 != "stranger" } ?? false
        let displayName = stringValue(object["display_name"])
            ?? stringValue(object["agent_display_name"])
            ?? "Her"
        let userDisplayName = stringValue(object["user_display_name"])
            ?? stringValue(object["user_name"])
            ?? stringValue(object["user_id"])
            ?? fallbackUserID
        let relationship = stringValue(object["relationship"])
            ?? stringValue(object["relationship_summary"])
            ?? relationshipSummary(stage: stage, bond: bond)
            ?? (known ? "Known memory profile" : "Getting acquainted")
        return AgentProfile(
            displayName: displayName,
            userDisplayName: userDisplayName,
            relationship: relationship,
            memoryID: stringValue(object["memory_id"]) ?? "",
            known: known
        )
    }

    private static func relationshipSummary(stage: String?, bond: [String: Any]?) -> String? {
        guard let stage, !stage.isEmpty else { return nil }
        var pieces = ["Stage: \(stage)"]
        if let trust = doubleValue(bond?["trust"]) {
            pieces.append("trust \(formatScore(trust))")
        }
        if let familiarity = doubleValue(bond?["familiarity"]) {
            pieces.append("familiarity \(formatScore(familiarity))")
        }
        if let affection = doubleValue(bond?["affection"]) {
            pieces.append("affection \(formatScore(affection))")
        }
        return pieces.joined(separator: " · ")
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(describing: raw)
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let lower = string.lowercased()
            if ["true", "yes", "1"].contains(lower) { return true }
            if ["false", "no", "0"].contains(lower) { return false }
            return nil
        default:
            return nil
        }
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func formatScore(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct ToolDescriptor: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var kind: String
    var summary: String
    var enabled: Bool
}

enum ServiceHealthState: String, Codable, Equatable {
    case unknown
    case checking
    case online
    case offline
}

struct ServiceHealth: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var kind: String
    var baseURL: URL?
    var state: ServiceHealthState
    var summary: String
    var checkedAt: Date?
}

struct WebServiceArtifact: Identifiable, Equatable {
    struct Request: Equatable {
        var method: String
        var url: String
        var status: Int
    }

    struct Item: Identifiable, Equatable {
        var id: String { "\(index)-\(file ?? url ?? type)" }
        var index: Int
        var type: String
        var url: String?
        var file: String?
    }

    var id: String
    var capabilityID: String
    var createdAt: Date
    var request: Request
    var manifestPath: String
    var responseFile: String
    var artifacts: [Item]

    var localFiles: [String] {
        artifacts.compactMap(\.file)
    }

    var remoteURLs: [String] {
        artifacts.compactMap(\.url)
    }

    var primaryLocalImagePath: String? {
        localFiles.first { path in
            ["png", "jpg", "jpeg", "webp", "gif"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        }
    }
}

struct HerAppConfig: Codable, Equatable {
    static let defaultAgentLLMMaxTokens = 16384

    var agentLLMBaseURL: URL
    var agentLLMAPIKey: String
    var agentLLMModel: String
    var agentLLMMaxTokens: Int
    var agentMemBaseURL: URL
    var agentMemAPIKey: String
    var agentCode: String
    var userID: String
    var pluginDirectory: String
    var speakAssistantReplies: Bool
    var speechVoiceIdentifier: String
    /// "apple" = system SFSpeechRecognizer (default, free, on-device where
    /// supported); "agentllm" = server-side transcription through the
    /// AgentLLM endpoint (OpenAI-compatible audio/transcriptions).
    var speechRecognitionProvider: String
    /// Transcription model when the provider is "agentllm".
    var agentLLMASRModel: String
    /// "apple" = AVSpeechSynthesizer (default); "agentllm" = server-side TTS
    /// through the AgentLLM endpoint (OpenAI-compatible audio/speech).
    var speechSynthesisProvider: String
    /// TTS model + speaker when the provider is "agentllm".
    var agentLLMTTSModel: String
    var agentLLMTTSVoice: String

    var hasLLMKey: Bool { !agentLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasMemKey: Bool { !agentMemAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(
        agentLLMBaseURL: URL,
        agentLLMAPIKey: String,
        agentLLMModel: String,
        agentLLMMaxTokens: Int = HerAppConfig.defaultAgentLLMMaxTokens,
        agentMemBaseURL: URL,
        agentMemAPIKey: String,
        agentCode: String,
        userID: String,
        pluginDirectory: String,
        speakAssistantReplies: Bool = false,
        speechVoiceIdentifier: String = "",
        speechRecognitionProvider: String = "apple",
        agentLLMASRModel: String = "fun-asr-realtime",
        speechSynthesisProvider: String = "apple",
        agentLLMTTSModel: String = "doubao-tts",
        agentLLMTTSVoice: String = "zh_female_cancan_mars_bigtts"
    ) {
        self.agentLLMBaseURL = agentLLMBaseURL
        self.agentLLMAPIKey = agentLLMAPIKey
        self.agentLLMModel = agentLLMModel
        self.agentLLMMaxTokens = agentLLMMaxTokens
        self.agentMemBaseURL = agentMemBaseURL
        self.agentMemAPIKey = agentMemAPIKey
        self.agentCode = agentCode
        self.userID = userID
        self.pluginDirectory = pluginDirectory
        self.speakAssistantReplies = speakAssistantReplies
        self.speechVoiceIdentifier = speechVoiceIdentifier
        self.speechRecognitionProvider = speechRecognitionProvider
        self.agentLLMASRModel = agentLLMASRModel
        self.speechSynthesisProvider = speechSynthesisProvider
        self.agentLLMTTSModel = agentLLMTTSModel
        self.agentLLMTTSVoice = agentLLMTTSVoice
    }

    enum CodingKeys: String, CodingKey {
        case agentLLMBaseURL
        case agentLLMAPIKey
        case agentLLMModel
        case agentLLMMaxTokens
        case agentMemBaseURL
        case agentMemAPIKey
        case agentCode
        case userID
        case pluginDirectory
        case speakAssistantReplies
        case speechVoiceIdentifier
        case speechRecognitionProvider
        case agentLLMASRModel
        case speechSynthesisProvider
        case agentLLMTTSModel
        case agentLLMTTSVoice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentLLMBaseURL = try container.decode(URL.self, forKey: .agentLLMBaseURL)
        agentLLMAPIKey = try container.decode(String.self, forKey: .agentLLMAPIKey)
        agentLLMModel = try container.decode(String.self, forKey: .agentLLMModel)
        agentLLMMaxTokens = try container.decodeIfPresent(Int.self, forKey: .agentLLMMaxTokens) ?? HerAppConfig.defaultAgentLLMMaxTokens
        agentMemBaseURL = try container.decode(URL.self, forKey: .agentMemBaseURL)
        agentMemAPIKey = try container.decode(String.self, forKey: .agentMemAPIKey)
        agentCode = try container.decode(String.self, forKey: .agentCode)
        userID = try container.decode(String.self, forKey: .userID)
        pluginDirectory = try container.decode(String.self, forKey: .pluginDirectory)
        speakAssistantReplies = try container.decodeIfPresent(Bool.self, forKey: .speakAssistantReplies) ?? false
        speechVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .speechVoiceIdentifier) ?? ""
        speechRecognitionProvider = try container.decodeIfPresent(String.self, forKey: .speechRecognitionProvider) ?? "apple"
        let decodedASRModel = try container.decodeIfPresent(String.self, forKey: .agentLLMASRModel) ?? "fun-asr-realtime"
        // Migrate the obsolete default: the endpoint's ASR bridge speaks the
        // DashScope protocol, not OpenAI whisper.
        agentLLMASRModel = decodedASRModel == "whisper-1" ? "fun-asr-realtime" : decodedASRModel
        speechSynthesisProvider = try container.decodeIfPresent(String.self, forKey: .speechSynthesisProvider) ?? "apple"
        agentLLMTTSModel = try container.decodeIfPresent(String.self, forKey: .agentLLMTTSModel) ?? "doubao-tts"
        agentLLMTTSVoice = try container.decodeIfPresent(String.self, forKey: .agentLLMTTSVoice) ?? "zh_female_cancan_mars_bigtts"
    }

    static let empty = HerAppConfig(
        agentLLMBaseURL: URL(string: "https://agentllm.linkyun.co")!,
        agentLLMAPIKey: "",
        agentLLMModel: "linkyun-default",
        agentMemBaseURL: URL(string: "https://agentmem.oyii.ai")!,
        agentMemAPIKey: "",
        agentCode: "her-desktop",
        userID: NSUserName().isEmpty ? "local-user" : NSUserName(),
        pluginDirectory: ".her/plugins"
    )
}

struct HerAppConfigDraft: Equatable {
    var agentLLMBaseURL: String
    var agentLLMAPIKey: String
    var agentLLMModel: String
    var agentLLMMaxTokens: String
    var agentMemBaseURL: String
    var agentMemAPIKey: String
    var agentCode: String
    var userID: String
    var pluginDirectory: String
    var speakAssistantReplies: Bool
    var speechVoiceIdentifier: String
    var speechRecognitionProvider: String
    var agentLLMASRModel: String
    var speechSynthesisProvider: String
    var agentLLMTTSModel: String
    var agentLLMTTSVoice: String

    init(config: HerAppConfig) {
        self.agentLLMBaseURL = config.agentLLMBaseURL.absoluteString
        self.agentLLMAPIKey = config.agentLLMAPIKey
        self.agentLLMModel = config.agentLLMModel
        self.agentLLMMaxTokens = String(config.agentLLMMaxTokens)
        self.agentMemBaseURL = config.agentMemBaseURL.absoluteString
        self.agentMemAPIKey = config.agentMemAPIKey
        self.agentCode = config.agentCode
        self.userID = config.userID
        self.pluginDirectory = config.pluginDirectory
        self.speakAssistantReplies = config.speakAssistantReplies
        self.speechVoiceIdentifier = config.speechVoiceIdentifier
        self.speechRecognitionProvider = config.speechRecognitionProvider
        self.agentLLMASRModel = config.agentLLMASRModel
        self.speechSynthesisProvider = config.speechSynthesisProvider
        self.agentLLMTTSModel = config.agentLLMTTSModel
        self.agentLLMTTSVoice = config.agentLLMTTSVoice
    }

    func makeConfig() throws -> HerAppConfig {
        let llmURL = try parseServiceURL(agentLLMBaseURL)
        let memURL = try parseServiceURL(agentMemBaseURL)
        return HerAppConfig(
            agentLLMBaseURL: llmURL,
            agentLLMAPIKey: agentLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            agentLLMModel: agentLLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "linkyun-default" : agentLLMModel.trimmingCharacters(in: .whitespacesAndNewlines),
            agentLLMMaxTokens: Int(agentLLMMaxTokens.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil } ?? HerAppConfig.defaultAgentLLMMaxTokens,
            agentMemBaseURL: memURL,
            agentMemAPIKey: agentMemAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            agentCode: agentCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "her-desktop" : agentCode.trimmingCharacters(in: .whitespacesAndNewlines),
            userID: userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "local-user" : userID.trimmingCharacters(in: .whitespacesAndNewlines),
            pluginDirectory: pluginDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ".her/plugins" : pluginDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            speakAssistantReplies: speakAssistantReplies,
            speechVoiceIdentifier: speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
            speechRecognitionProvider: speechRecognitionProvider == "agentllm" ? "agentllm" : "apple",
            agentLLMASRModel: {
                let trimmed = agentLLMASRModel.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || trimmed == "whisper-1" ? "fun-asr-realtime" : trimmed
            }(),
            speechSynthesisProvider: speechSynthesisProvider == "agentllm" ? "agentllm" : "apple",
            agentLLMTTSModel: agentLLMTTSModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "doubao-tts"
                : agentLLMTTSModel.trimmingCharacters(in: .whitespacesAndNewlines),
            agentLLMTTSVoice: agentLLMTTSVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "zh_female_cancan_mars_bigtts"
                : agentLLMTTSVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func parseServiceURL(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            throw ConfigError.invalidURL
        }
        return url
    }

    enum ConfigError: LocalizedError {
        case invalidURL

        var errorDescription: String? {
            "AgentLLM and AgentMem base URLs must be valid URLs."
        }
    }
}

struct PluginManifest: Identifiable, Codable, Equatable {
    struct CapabilityAdapter: Codable, Equatable {
        var type: String
        var url: String? = nil
        var method: String? = nil
        var methodName: String? = nil
        var toolName: String? = nil
        var headers: [String: String]? = nil
        var bodyTemplate: String? = nil
        var skillFile: String? = nil
        var command: String? = nil
        var arguments: [String]? = nil
        var workingDirectory: String? = nil
        var timeoutSeconds: Double? = nil
    }

    struct Capability: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var kind: String
        var invocation: String
        var requiresApproval: Bool
        var description: String? = nil
        /// When-to-use guidance rendered into the system prompt. Lives in the
        /// manifest (single source of truth) instead of hand-maintained prose
        /// in SystemPromptBuilder that went stale when capabilities changed.
        var usageHint: String? = nil
        var inputSchema: [String: JSONValue]? = nil
        var adapter: CapabilityAdapter? = nil
    }

    /// Version of the manifest FORMAT itself (distinct from `version`, the
    /// plugin's own semver). Absent means 1. When the format evolves, readers
    /// can migrate v1→v2 instead of silently failing to decode and dropping
    /// the user's installed plugins.
    var manifestSchemaVersion: Int? = nil
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var systemPromptAddendum: String?
    var capabilities: [Capability]

    static let currentManifestSchemaVersion = 1

    var resolvedManifestSchemaVersion: Int {
        manifestSchemaVersion ?? 1
    }
}

struct PluginPackage: Codable, Equatable {
    struct FileItem: Codable, Equatable {
        var path: String
        var content: String
    }

    var manifest: PluginManifest
    var files: [FileItem]
}

struct GeneratedPluginDraft: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var package: PluginPackage
    var source: String
    var createdAt: Date = Date()

    var manifest: PluginManifest { package.manifest }
}

struct VibePluginComposerPreset: Identifiable, Equatable {
    var id: UUID = UUID()
    var pluginName: String = ""
    var pluginDescription: String = ""
    var pluginKind: String = "skill"
    var pluginRequiresApproval: Bool = true
    var pluginURL: String = ""
    var pluginMethod: String = "POST"
    var pluginMCPMethod: String = ""
    var pluginMCPToolName: String = ""
    var pluginMCPInputSchemaJSON: String = ""
    var pluginCommandPath: String = ""
    var pluginCommandArguments: String = ""
    var pluginPackageJSON: String = ""
    var pluginUpdateTargetID: String = ""
    var pluginExistingPackageContext: String = ""
}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.anyValue)
        case .array(let value): return value.map(\.anyValue)
        case .null: return NSNull()
        }
    }
}
