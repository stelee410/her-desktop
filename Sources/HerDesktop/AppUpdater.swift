import Foundation

/// Self-update against GitHub Releases. The latest version is whatever
/// `releases/latest` reports for the repo; the downloadable build is the
/// notarized `.dmg` asset attached to that release.
///
/// Split into pure helpers (release parsing, semver compare — unit tested) and
/// the side-effecting flow (download → verify signature → stage → hand off to a
/// helper that swaps the bundle once we quit and relaunches).
enum AppUpdater {
    static let repo = "stelee410/her-desktop"
    /// Only a build signed by this Developer ID team is allowed to replace the
    /// running app — a hard gate so a spoofed download can't overwrite it.
    static let expectedTeamID = "83HFUV53VA"

    struct Release: Equatable {
        var version: String        // normalized, e.g. "0.2.0" (no leading v)
        var tagName: String        // raw tag, e.g. "v0.2.0"
        var name: String
        var htmlURL: URL
        var dmgURL: URL
        var notes: String
    }

    enum UpdateError: LocalizedError {
        case noRelease
        case noDMGAsset
        case badResponse(Int)
        case verificationFailed(String)
        case mountFailed(String)

        var errorDescription: String? {
            switch self {
            case .noRelease: return "GitHub 上还没有发布版本。"
            case .noDMGAsset: return "最新发布里没有找到 .dmg 安装包。"
            case .badResponse(let code): return "检查更新失败（HTTP \(code)）。"
            case .verificationFailed(let detail): return "下载的安装包校验未通过：\(detail)"
            case .mountFailed(let detail): return "挂载安装包失败：\(detail)"
            }
        }
    }

    // MARK: - Pure helpers

    /// Parse a GitHub `releases/latest` payload, picking the first `.dmg` asset.
    static func parseLatestRelease(_ data: Data) -> Release? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = root["tag_name"] as? String else {
            return nil
        }
        let assets = (root["assets"] as? [[String: Any]]) ?? []
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }),
              let dmgURLString = dmg["browser_download_url"] as? String,
              let dmgURL = URL(string: dmgURLString) else {
            return nil
        }
        let htmlURL = (root["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repo)/releases")!
        return Release(
            version: normalize(tag),
            tagName: tag,
            name: (root["name"] as? String) ?? tag,
            htmlURL: htmlURL,
            dmgURL: dmgURL,
            notes: (root["body"] as? String) ?? ""
        )
    }

    /// Strip a leading `v`/`V` and surrounding whitespace from a tag.
    static func normalize(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        return v
    }

    /// Semantic-ish compare. Compares dotted numeric components (missing = 0);
    /// on an equal numeric core, a plain release outranks a `-prerelease`.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func split(_ s: String) -> (core: [Int], pre: String) {
            let normalized = normalize(s)
            let dashSplit = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = dashSplit[0].split(separator: ".").map { Int($0) ?? 0 }
            let pre = dashSplit.count > 1 ? String(dashSplit[1]) : ""
            return (core, pre)
        }
        let a = split(lhs), b = split(rhs)
        let count = max(a.core.count, b.core.count)
        for i in 0..<count {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        if a.pre == b.pre { return .orderedSame }
        if a.pre.isEmpty { return .orderedDescending } // 1.0.0 > 1.0.0-beta
        if b.pre.isEmpty { return .orderedAscending }
        return a.pre < b.pre ? .orderedAscending : .orderedDescending
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    // MARK: - Network

    static func fetchLatestRelease(session: URLSession = .shared) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HerDesktop-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.badResponse(code) }
        guard let release = parseLatestRelease(data) else { throw UpdateError.noDMGAsset }
        return release
    }

    /// Download the DMG, streaming progress (0…1) back on each chunk.
    static func downloadDMG(
        _ release: Release,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: release.dmgURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.badResponse(code) }
        let expected = response.expectedContentLength
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerDesktop-\(release.version)-\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 { progress(min(Double(received) / Double(expected), 1)) }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        progress(1)
        return destination
    }

    // MARK: - Install

    /// Mount the DMG, verify the app inside is our notarized Developer ID build,
    /// stage a copy, and spawn a detached helper that waits for `appPID` to exit,
    /// swaps `destination`, and relaunches. Returns after the helper is launched;
    /// the caller must then terminate the app so the swap can proceed.
    static func stageAndScheduleInstall(dmgPath: URL, destination: URL, appPID: Int32) throws {
        let mountPoint = try mountDMG(dmgPath)
        var didDetach = false
        defer { if !didDetach { _ = try? detachDMG(mountPoint) } }

        let appInDMG = mountPoint.appendingPathComponent("HerDesktop.app")
        guard FileManager.default.fileExists(atPath: appInDMG.path) else {
            throw UpdateError.verificationFailed("DMG 里没有 HerDesktop.app")
        }

        // Stage a copy so we can detach the DMG before swapping.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerDesktop-staged-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let stagedApp = staged.appendingPathComponent("HerDesktop.app")
        try runTool("/usr/bin/ditto", [appInDMG.path, stagedApp.path])

        _ = try? detachDMG(mountPoint)
        didDetach = true

        try verifySignature(stagedApp)
        // Downloaded items are quarantined; strip it so the relaunch is silent.
        _ = try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path])

        let script = installerScript(appPID: appPID, staged: stagedApp, destination: destination)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Detached: reparented to launchd when we quit, so it survives to swap.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    static func verifySignature(_ app: URL) throws {
        try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let details = (try? toolOutput("/usr/bin/codesign", ["-dv", app.path])) ?? ""
        guard details.contains("TeamIdentifier=\(expectedTeamID)") else {
            throw UpdateError.verificationFailed("签名团队不匹配（期望 \(expectedTeamID)）")
        }
    }

    private static func installerScript(appPID: Int32, staged: URL, destination: URL) -> String {
        """
        #!/bin/bash
        # Wait for Her Desktop to quit, then swap in the new bundle and relaunch.
        APP_PID=\(appPID)
        STAGED=\(shellQuote(staged.path))
        DEST=\(shellQuote(destination.path))
        for _ in $(seq 1 120); do
          kill -0 "$APP_PID" 2>/dev/null || break
          sleep 0.5
        done
        sleep 1
        rm -rf "$DEST.old"
        if [ -d "$DEST" ]; then mv "$DEST" "$DEST.old"; fi
        if /usr/bin/ditto "$STAGED" "$DEST"; then
          rm -rf "$DEST.old" "$STAGED"
          open "$DEST"
        else
          # Restore the old bundle on failure so the user isn't left with nothing.
          rm -rf "$DEST"
          if [ -d "$DEST.old" ]; then mv "$DEST.old" "$DEST"; fi
          open "$DEST"
        fi
        """
    }

    // MARK: - Shell utilities

    private static func mountDMG(_ dmg: URL) throws -> URL {
        let output = try toolOutput("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noverify", "-noautoopen"])
        // Last whitespace-separated token on a line starting with /dev is the mount point.
        for line in output.split(separator: "\n").reversed() {
            if let range = line.range(of: "/Volumes/") {
                return URL(fileURLWithPath: String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        throw UpdateError.mountFailed(output)
    }

    private static func detachDMG(_ mountPoint: URL) throws {
        _ = try runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
    }

    @discardableResult
    private static func runTool(_ launchPath: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw UpdateError.verificationFailed("\(launchPath) 退出码 \(process.terminationStatus)")
        }
        return process.terminationStatus
    }

    private static func toolOutput(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        // codesign -dv writes to stderr; capture both streams.
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
