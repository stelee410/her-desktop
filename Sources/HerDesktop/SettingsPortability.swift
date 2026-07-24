import Foundation

/// Export / import of Her's settings so they can be carried to another Mac.
///
/// The payload is the full `HerAppConfig` (API keys included — that's the point
/// of moving settings) wrapped in a small versioned envelope, so import can
/// tell a real Her settings file from an unrelated JSON and refuse a file that
/// was written by a newer app version.
enum SettingsPortability {
    static let fileType = "her-desktop-settings"
    static let currentVersion = 1

    struct Envelope: Codable, Equatable {
        var type: String
        var version: Int
        var exportedAt: Date
        var appVersion: String
        var config: HerAppConfig
    }

    /// Serialize the current configuration into a shareable JSON document.
    static func exportData(
        config: HerAppConfig,
        exportedAt: Date,
        appVersion: String = SettingsPortability.appVersion
    ) throws -> Data {
        let envelope = Envelope(
            type: fileType,
            version: currentVersion,
            exportedAt: exportedAt,
            appVersion: appVersion,
            config: config
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// Decode a settings document produced by `exportData`. Also accepts a bare
    /// `HerAppConfig` JSON (e.g. someone copied their local config.json), so
    /// long as it carries the LLM base URL — that key gates the fallback so a
    /// random or empty JSON isn't silently imported as a blank config.
    static func importConfig(from data: Data) throws -> HerAppConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? decoder.decode(Envelope.self, from: data),
           envelope.type == fileType {
            guard envelope.version <= currentVersion else {
                throw PortabilityError.tooNew(envelope.version)
            }
            return envelope.config
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["agentLLMBaseURL"] != nil,
           let config = try? decoder.decode(HerAppConfig.self, from: data) {
            return config
        }

        throw PortabilityError.unrecognized
    }

    /// Suggested filename for the export panel, e.g. `Her-Settings-2026-07-24.json`.
    static func suggestedFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Her-Settings-\(formatter.string(from: date)).json"
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    enum PortabilityError: LocalizedError {
        case unrecognized
        case tooNew(Int)

        var errorDescription: String? {
            switch self {
            case .unrecognized:
                return "这不是 Her 的设置文件（无法识别其格式）。"
            case .tooNew(let version):
                return "设置文件版本（v\(version)）比当前应用更新，请先升级 Her Desktop 再导入。"
            }
        }
    }
}
