import Foundation

final class PluginRegistry {
    enum InstallError: LocalizedError, Equatable {
        case unsafePath(String)
        case protectedPlugin(String)
        case missingPlugin(String)
        case unsupportedFile(String)

        var errorDescription: String? {
            switch self {
            case .unsafePath(let path):
                return "Unsafe plugin file path: \(path)"
            case .protectedPlugin(let pluginID):
                return "Built-in plugin \(pluginID) is read-only."
            case .missingPlugin(let pluginID):
                return "Plugin \(pluginID) is not installed."
            case .unsupportedFile(let path):
                return "Plugin file is not a UTF-8 text file: \(path)"
            }
        }
    }

    private let config: HerAppConfig
    private let baseDirectory: String
    private let fileManager: FileManager
    private let loadBundledBuiltInResources: Bool

    init(
        config: HerAppConfig,
        baseDirectory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default,
        loadBundledBuiltInResources: Bool = true
    ) {
        self.config = config
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        self.loadBundledBuiltInResources = loadBundledBuiltInResources
    }

    func loadPlugins() -> [PluginManifest] {
        let directory = pluginDirectoryURL()
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return builtInPlugins()
        }

        let decoder = JSONDecoder()
        let loaded = items.compactMap { item -> PluginManifest? in
            let manifest = item.appendingPathComponent("plugin.json")
            guard fileManager.fileExists(atPath: manifest.path) else { return nil }
            do {
                return try decoder.decode(PluginManifest.self, from: Data(contentsOf: manifest))
            } catch {
                print("Failed to load plugin \(manifest.path): \(error)")
                return nil
            }
        }
        return builtInPlugins() + loaded
    }

    func install(manifest: PluginManifest) throws {
        try install(package: PluginPackage(manifest: manifest, files: []))
    }

    func install(package: PluginPackage, replacingExisting: Bool = false) throws {
        let root = pluginDirectoryURL().appendingPathComponent(package.manifest.id, isDirectory: true)
        if replacingExisting, fileManager.fileExists(atPath: root.path) {
            guard package.manifest.id.hasPrefix("local.") else {
                throw InstallError.protectedPlugin(package.manifest.id)
            }
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(package.manifest)
        try data.write(to: root.appendingPathComponent("plugin.json"), options: .atomic)

        for file in package.files {
            let destination = try safeDestination(for: file.path, under: root)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    func remove(pluginID: String) throws {
        guard pluginID.hasPrefix("local.") else {
            throw InstallError.protectedPlugin(pluginID)
        }
        guard pluginID.range(of: #"^local\.[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw InstallError.unsafePath(pluginID)
        }

        let root = pluginRootURL(pluginID: pluginID)
        guard fileManager.fileExists(atPath: root.path) else {
            throw InstallError.missingPlugin(pluginID)
        }
        try fileManager.removeItem(at: root)
    }

    func package(pluginID: String) throws -> PluginPackage {
        guard pluginID.hasPrefix("local.") else {
            throw InstallError.protectedPlugin(pluginID)
        }
        let root = pluginRootURL(pluginID: pluginID)
        let manifestURL = root.appendingPathComponent("plugin.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw InstallError.missingPlugin(pluginID)
        }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
        let files = try pluginPackageFiles(under: root)
        return PluginPackage(manifest: manifest, files: files)
    }

    func capability(id: String, in manifests: [PluginManifest]? = nil) -> PluginManifest.Capability? {
        let source = manifests ?? loadPlugins()
        return source.flatMap(\.capabilities).first { $0.id == id }
    }

    func manifest(containing capabilityID: String, in manifests: [PluginManifest]? = nil) -> PluginManifest? {
        let source = manifests ?? loadPlugins()
        return source.first { manifest in
            manifest.capabilities.contains { $0.id == capabilityID }
        }
    }

    func readPluginFile(pluginID: String, path: String) throws -> String {
        if pluginID.hasPrefix("builtin."), let bundled = bundledPluginFile(pluginID: pluginID, path: path) {
            return bundled
        }
        let root = pluginRootURL(pluginID: pluginID)
        let source = try safeDestination(for: path, under: root)
        return try String(contentsOf: source, encoding: .utf8)
    }

    private func pluginPackageFiles(under root: URL) throws -> [PluginPackage.FileItem] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [PluginPackage.FileItem] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                continue
            }
            let relativePath = relativePluginPath(for: url, under: root)
            if relativePath == "plugin.json" {
                continue
            }
            let safeURL = try safeDestination(for: relativePath, under: root)
            guard let content = try? String(contentsOf: safeURL, encoding: .utf8) else {
                throw InstallError.unsupportedFile(relativePath)
            }
            files.append(.init(path: relativePath, content: content))
        }
        return files.sorted { $0.path < $1.path }
    }

    private func relativePluginPath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func pluginDirectoryURL() -> URL {
        HerWorkspacePaths.pluginDirectory(config: config, cwd: baseDirectory)
    }

    private func pluginRootURL(pluginID: String) -> URL {
        pluginDirectoryURL().appendingPathComponent(pluginID, isDirectory: true)
    }

    private func safeDestination(for relativePath: String, under root: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains(".."),
              !trimmed.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw InstallError.unsafePath(relativePath)
        }
        let destination = root.appendingPathComponent(trimmed)
        let standardizedRoot = root.standardizedFileURL.path
        let standardizedDestination = destination.standardizedFileURL.path
        guard standardizedDestination.hasPrefix(standardizedRoot + "/") else {
            throw InstallError.unsafePath(relativePath)
        }
        return destination
    }

    private func builtInPlugins() -> [PluginManifest] {
        guard loadBundledBuiltInResources else {
            // Tests opt out of built-ins entirely.
            return []
        }
        let bundled = bundledBuiltInPlugins()
        if bundled.isEmpty {
            // No silent hand-written fallback anymore: it was a second copy
            // of every manifest + inputSchema that inevitably drifted from
            // the JSON. The bundled .plugin.json files are the single source
            // of truth; a bundle without them is a broken build and should
            // be loud, not quietly degraded.
            print("PluginRegistry: FATAL — no bundled built-in plugin manifests found; the app bundle is missing processed resources.")
        }
        return bundled
    }

    private func bundledBuiltInPlugins() -> [PluginManifest] {
        if let directory = Bundle.module.url(
            forResource: "BuiltinPlugins",
            withExtension: nil
        ) {
            let plugins = decodePluginManifests(in: directory)
            if !plugins.isEmpty {
                return plugins
            }
        }
        return bundledFlatPluginManifests()
    }

    private func decodePluginManifests(in directory: URL) -> [PluginManifest] {
        let items = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return decodePluginManifests(from: items)
    }

    private func bundledFlatPluginManifests() -> [PluginManifest] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return decodePluginManifests(from: urls)
    }

    private func decodePluginManifests(from urls: [URL]) -> [PluginManifest] {
        let decoder = JSONDecoder()
        return urls
            .filter { $0.lastPathComponent.hasSuffix(".plugin.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { item in
                do {
                    return try decoder.decode(PluginManifest.self, from: Data(contentsOf: item))
                } catch {
                    print("Failed to load bundled plugin \(item.path): \(error)")
                    return nil
                }
            }
    }

    private func bundledPluginFile(pluginID: String, path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard (try? safeDestination(for: trimmed, under: URL(fileURLWithPath: "/tmp/her-builtin-plugin", isDirectory: true))) != nil else {
            return nil
        }

        let candidates = [
            trimmed,
            "\(pluginID).\(trimmed)"
        ]
        for candidate in candidates {
            if let content = readBundledResource(candidate) {
                return content
            }
        }
        return nil
    }

    private func readBundledResource(_ name: String) -> String? {
        let url: URL?
        if let dot = name.lastIndex(of: ".") {
            let base = String(name[..<dot])
            let ext = String(name[name.index(after: dot)...])
            url = Bundle.module.url(forResource: base, withExtension: ext)
        } else {
            url = Bundle.module.url(forResource: name, withExtension: nil)
        }
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

}
