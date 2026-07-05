import Foundation

struct WebAppRuntime: Codable, Equatable {
    /// "node" or "python"
    var type: String
    /// App-directory-relative entry script, e.g. "backend/server.py".
    var entry: String
}

struct WebAppWidget: Codable, Equatable {
    /// `www`-relative entry page for the compact card view, e.g. "widget.html".
    var entry: String
    /// Preferred card height in points.
    var height: Double?
}

struct WebAppManifest: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var description: String
    var entry: String
    var createdAt: Date
    var updatedAt: Date
    var runtime: WebAppRuntime?
    var widget: WebAppWidget?
    /// Optional for backward compatibility with manifests written before
    /// pinning existed; use `isPinned`.
    var pinned: Bool?

    var isPinned: Bool { pinned ?? false }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case entry
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case runtime
        case widget
        case pinned
    }
}

/// Persists locally generated mini web apps under `.her/webapps/<id>/`.
/// Each app owns its directory: `webapp.json` manifest, `www/` static
/// files, and `data.db` SQLite database. IDs are file-safe slugs so the
/// HTTP layer can never escape the webapps directory.
/// Holds only immutable configuration; FileManager is thread-safe for
/// these path-scoped operations, so the store is safe to share with the
/// server queue.
final class WebAppStore: @unchecked Sendable {
    enum StoreError: LocalizedError {
        case invalidAppID(String)
        case appNotFound(String)
        case emptyHTML
        case unsupportedRuntime(String)

        var errorDescription: String? {
            switch self {
            case .invalidAppID(let id):
                return "Invalid web app id: \(id)"
            case .appNotFound(let id):
                return "Web app not found: \(id)"
            case .emptyHTML:
                return "The web app HTML content is empty."
            case .unsupportedRuntime(let type):
                return "Unsupported backend runtime: \(type). Use node or python."
            }
        }
    }

    static let supportedRuntimes: Set<String> = ["node", "python"]

    private let cwd: String
    private let fileManager: FileManager

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
    }

    var directoryURL: URL {
        HerWorkspacePaths.webAppsDirectory(cwd: cwd)
    }

    func appDirectory(id: String) -> URL {
        directoryURL.appendingPathComponent(Self.slug(from: id), isDirectory: true)
    }

    func wwwDirectory(id: String) -> URL {
        appDirectory(id: id).appendingPathComponent("www", isDirectory: true)
    }

    func databaseURL(id: String) -> URL {
        appDirectory(id: id).appendingPathComponent("data.db")
    }

    func backendDirectory(id: String) -> URL {
        appDirectory(id: id).appendingPathComponent("backend", isDirectory: true)
    }

    /// LLM-facing description of the app: what it stores, table schemas,
    /// meaningful queries, and backend routes. Lives at the app root, not
    /// under `www/`, so it is never served over HTTP.
    func llmsTxtURL(id: String) -> URL {
        appDirectory(id: id).appendingPathComponent("llms.txt")
    }

    func llmsTxt(id: String) -> String? {
        guard let data = try? Data(contentsOf: llmsTxtURL(id: id)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeLLMsTxt(id: String, content: String) throws {
        guard manifest(id: id) != nil else { throw StoreError.appNotFound(id) }
        try Data(content.utf8).write(to: llmsTxtURL(id: id), options: .atomic)
    }

    private func manifestURL(id: String) -> URL {
        appDirectory(id: id).appendingPathComponent("webapp.json")
    }

    func loadAll() -> [WebAppManifest] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .compactMap { manifest(id: $0.lastPathComponent) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func manifest(id: String) -> WebAppManifest? {
        let url = manifestURL(id: id)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? Self.decoder().decode(WebAppManifest.self, from: data)
    }

    @discardableResult
    func create(
        name: String,
        description: String,
        html: String,
        backendType: String? = nil,
        backendCode: String? = nil,
        widgetHTML: String? = nil,
        widgetHeight: Double? = nil,
        llmsTxt: String? = nil,
        idHint: String = "",
        now: Date = Date()
    ) throws -> WebAppManifest {
        let trimmedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHTML.isEmpty else { throw StoreError.emptyHTML }
        let base = Self.slug(from: idHint.isEmpty ? name : idHint)
        var id = base
        var suffix = 2
        while fileManager.fileExists(atPath: appDirectory(id: id).path) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        var manifest = WebAppManifest(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty(id),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            entry: "index.html",
            createdAt: now,
            updatedAt: now
        )
        try fileManager.createDirectory(at: wwwDirectory(id: id), withIntermediateDirectories: true)
        try Data(trimmedHTML.utf8).write(to: wwwDirectory(id: id).appendingPathComponent("index.html"), options: .atomic)
        manifest.runtime = try writeBackendIfRequested(id: id, type: backendType, code: backendCode)
        manifest.widget = try writeWidgetIfRequested(id: id, html: widgetHTML, height: widgetHeight)
        try save(manifest)
        if let llmsTxt = llmsTxt?.trimmingCharacters(in: .whitespacesAndNewlines), !llmsTxt.isEmpty {
            try writeLLMsTxt(id: id, content: llmsTxt)
        }
        return manifest
    }

    @discardableResult
    func update(
        id: String,
        html: String? = nil,
        name: String? = nil,
        description: String? = nil,
        backendType: String? = nil,
        backendCode: String? = nil,
        widgetHTML: String? = nil,
        widgetHeight: Double? = nil,
        llmsTxt: String? = nil,
        now: Date = Date()
    ) throws -> WebAppManifest {
        guard var manifest = manifest(id: id) else { throw StoreError.appNotFound(id) }
        if let html {
            let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw StoreError.emptyHTML }
            try Data(trimmed.utf8).write(
                to: wwwDirectory(id: id).appendingPathComponent(manifest.entry),
                options: .atomic
            )
        }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifest.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let description {
            manifest.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let runtime = try writeBackendIfRequested(id: id, type: backendType, code: backendCode) {
            manifest.runtime = runtime
        }
        if let widget = try writeWidgetIfRequested(id: id, html: widgetHTML, height: widgetHeight) {
            manifest.widget = widget
        }
        manifest.updatedAt = now
        try save(manifest)
        if let llmsTxt = llmsTxt?.trimmingCharacters(in: .whitespacesAndNewlines), !llmsTxt.isEmpty {
            try writeLLMsTxt(id: id, content: llmsTxt)
        }
        return manifest
    }

    private func writeWidgetIfRequested(id: String, html: String?, height: Double?) throws -> WebAppWidget? {
        guard let html = html?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty else {
            return nil
        }
        try fileManager.createDirectory(at: wwwDirectory(id: id), withIntermediateDirectories: true)
        try Data(html.utf8).write(to: wwwDirectory(id: id).appendingPathComponent("widget.html"), options: .atomic)
        let clamped = height.map { min(max($0, 80), 480) }
        return WebAppWidget(entry: "widget.html", height: clamped)
    }

    private func writeBackendIfRequested(id: String, type: String?, code: String?) throws -> WebAppRuntime? {
        guard let type = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !type.isEmpty,
              let code = code?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            return nil
        }
        guard Self.supportedRuntimes.contains(type) else {
            throw StoreError.unsupportedRuntime(type)
        }
        let fileName = type == "node" ? "server.js" : "server.py"
        try fileManager.createDirectory(at: backendDirectory(id: id), withIntermediateDirectories: true)
        try Data(code.utf8).write(to: backendDirectory(id: id).appendingPathComponent(fileName), options: .atomic)
        return WebAppRuntime(type: type, entry: "backend/\(fileName)")
    }

    @discardableResult
    func togglePin(id: String) throws -> WebAppManifest {
        guard var manifest = manifest(id: id) else { throw StoreError.appNotFound(id) }
        manifest.pinned = !manifest.isPinned
        try save(manifest)
        return manifest
    }

    func remove(id: String) throws {
        let directory = appDirectory(id: id)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw StoreError.appNotFound(id)
        }
        try fileManager.removeItem(at: directory)
    }

    /// Resolves a request path inside an app's `www` directory, rejecting
    /// any path that escapes it.
    func staticFileURL(appID: String, requestPath: String) -> URL? {
        let www = wwwDirectory(id: appID).standardizedFileURL
        let cleaned = requestPath.removingPercentEncoding ?? requestPath
        let relative = cleaned.isEmpty || cleaned == "/" ? "index.html" : cleaned
        let candidate = www.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(www.path + "/") || candidate.path == www.path else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            let index = candidate.appendingPathComponent("index.html")
            return fileManager.fileExists(atPath: index.path) ? index : nil
        }
        return candidate
    }

    static func slug(from raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        var slug = ""
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                slug.append(Character(scalar))
            } else if scalar == " " || scalar == "_" || scalar == "." {
                slug.append("-")
            }
        }
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "app-\(UUID().uuidString.prefix(8).lowercased())" : String(slug.prefix(48))
    }

    private func save(_ manifest: WebAppManifest) throws {
        try fileManager.createDirectory(at: appDirectory(id: manifest.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL(id: manifest.id), options: .atomic)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
