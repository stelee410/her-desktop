import Foundation

final class WebServiceArtifactStore {
    private let cwd: String
    private let fileManager: FileManager

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
    }

    func loadAll(limit: Int = 24) throws -> [WebServiceArtifact] {
        let directory = HerWorkspacePaths.webServiceArtifactDirectory(cwd: cwd)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let manifests = files
            .filter { $0.lastPathComponent.hasSuffix("-manifest.json") }
            .sorted { lhs, rhs in
                modificationDate(lhs) > modificationDate(rhs)
            }

        var artifacts: [WebServiceArtifact] = []
        for manifest in manifests {
            guard let artifact = try? decodeManifest(at: manifest) else {
                continue
            }
            artifacts.append(artifact)
            if artifacts.count >= limit {
                break
            }
        }
        return artifacts
    }

    private func decodeManifest(at url: URL) throws -> WebServiceArtifact {
        let decoded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        return WebServiceArtifact(
            id: decoded.id,
            capabilityID: decoded.capabilityID,
            createdAt: decoded.createdAtDate,
            request: .init(
                method: decoded.request.method,
                url: decoded.request.url,
                status: decoded.request.status
            ),
            manifestPath: url.path,
            responseFile: decoded.responseFile,
            artifacts: decoded.artifacts.map {
                .init(index: $0.index, type: $0.type ?? "artifact", url: $0.url, file: $0.file)
            }
        )
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

private struct Manifest: Codable {
    struct Request: Codable {
        var method: String
        var url: String
        var status: Int
    }

    struct Item: Codable {
        var index: Int
        var type: String?
        var url: String?
        var file: String?
    }

    var id: String
    var capabilityID: String
    var createdAt: String
    var request: Request
    var responseFile: String
    var artifacts: [Item]

    var createdAtDate: Date {
        ISO8601DateFormatter().date(from: createdAt) ?? .distantPast
    }

    enum CodingKeys: String, CodingKey {
        case id
        case capabilityID = "capability_id"
        case createdAt = "created_at"
        case request
        case responseFile = "response_file"
        case artifacts
    }
}
