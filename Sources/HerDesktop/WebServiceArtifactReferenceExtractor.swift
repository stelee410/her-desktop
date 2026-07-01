import Foundation

enum WebServiceArtifactReferenceExtractor {
    static func manifestPaths(in text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("artifact_manifest:") else { return nil }
                let path = trimmed
                    .dropFirst("artifact_manifest:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
    }
}
