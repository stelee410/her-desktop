import Foundation

enum SecretRedactor {
    private static let replacement = "[redacted]"
    private static let tokenPatterns = [
        #"sk-[A-Za-z0-9_\-]{12,}"#,
        #"mem_[A-Za-z0-9_\-]{12,}"#
    ]
    private static let prefixedPatterns = [
        #"(?i)(Bearer\s+)[A-Za-z0-9_\-\.]{12,}"#,
        #"(?i)((?:api[_-]?key|token|secret|authorization)["'\s:=]+)[A-Za-z0-9_\-\./+=]{12,}"#
    ]

    static func redact(_ text: String, config: HerAppConfig? = nil) -> String {
        var redacted = text
        if let config {
            redacted = redactKnown(config.agentLLMAPIKey, in: redacted)
            redacted = redactKnown(config.agentMemAPIKey, in: redacted)
        }
        for pattern in tokenPatterns {
            redacted = replace(pattern: pattern, in: redacted, template: replacement)
        }
        for pattern in prefixedPatterns {
            redacted = replace(pattern: pattern, in: redacted, template: "$1\(replacement)")
        }
        return redacted
    }

    static func redact(_ error: Error, config: HerAppConfig? = nil) -> String {
        redact(error.localizedDescription, config: config)
    }

    private static func redactKnown(_ secret: String, in text: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return text }
        return text.replacingOccurrences(of: trimmed, with: replacement)
    }

    private static func replace(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
