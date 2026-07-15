import AppKit
import Foundation
import PDFKit

/// Office 文档能力：PDF 读取/合并走 PDFKit（原生、零依赖）；
/// pptx/docx/xlsx 走 OfficeToolRunner 的 Python sidecar。
/// 生成的文件落在 workspace 的 office-exports/ 下并在访达中显示。
extension AppViewModel {
    private var officeExportDirectory: URL {
        HerWorkspacePaths.workspaceDirectory(cwd: runtimeCwd)
            .appendingPathComponent("office-exports", isDirectory: true)
    }

    // MARK: - PDF（原生 PDFKit）

    func readPDFCapability(arguments: [String: Any]) -> CapabilityResult {
        guard let url = resolveOfficeInputPath(arguments["path"] as? String) else {
            return officeFailure("需要 path 参数：要读取的 PDF 文件路径。")
        }
        guard let document = PDFDocument(url: url) else {
            return officeFailure("读不出这个 PDF：\(url.path)")
        }
        if document.isLocked {
            return officeFailure("PDF 有密码保护，暂不支持解锁读取。")
        }
        let maxChars = (arguments["max_chars"] as? Int).map { max(500, $0) } ?? 20000
        var parts: [String] = []
        var total = 0
        for index in 0..<document.pageCount {
            guard total < maxChars, let page = document.page(at: index) else { break }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            parts.append("— 第 \(index + 1) 页 —\n\(text)")
            total += text.count
        }
        var content = parts.joined(separator: "\n\n")
        var truncated = false
        if content.count > maxChars {
            content = String(content.prefix(maxChars))
            truncated = true
        }
        if content.isEmpty {
            content = "（没有可提取的文本层——可能是扫描件，需要 OCR。）"
        }
        return CapabilityResult(
            title: "PDF · \(url.lastPathComponent)",
            content: "共 \(document.pageCount) 页\(truncated ? "（文本已截断）" : "")\n\n\(content)",
            requiresUserApproval: false
        )
    }

    func mergePDFCapability(arguments: [String: Any]) -> CapabilityResult {
        let rawPaths = (arguments["paths"] as? [Any])?.compactMap { $0 as? String } ?? []
        let inputs = rawPaths.compactMap(resolveOfficeInputPath)
        guard inputs.count >= 2, inputs.count == rawPaths.count else {
            return officeFailure("需要 paths 参数：至少两个存在的 PDF 文件路径。")
        }
        let merged = PDFDocument()
        for url in inputs {
            guard let document = PDFDocument(url: url), !document.isLocked else {
                return officeFailure("读不出或被密码保护：\(url.path)")
            }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        guard let output = officeOutputURL(arguments["output_name"] as? String, fallback: "合并", ext: "pdf"),
              merged.write(to: output) else {
            return officeFailure("合并结果写入失败。")
        }
        revealOfficeExport(output)
        return CapabilityResult(
            title: "PDF 已合并",
            content: "共 \(merged.pageCount) 页 → \(output.path)",
            requiresUserApproval: false
        )
    }

    // MARK: - pptx / docx / xlsx（Python sidecar）

    func generatePPTCapability(arguments: [String: Any]) async -> CapabilityResult {
        guard let slides = arguments["slides"] as? [[String: Any]], !slides.isEmpty else {
            return officeFailure("需要 slides 参数：[{title, bullets[], notes?}, …]，可另附 title/subtitle 作为封面。")
        }
        guard let output = officeOutputURL(arguments["output_name"] as? String, fallback: "演示文稿", ext: "pptx") else {
            return officeFailure("输出路径无效。")
        }
        var payload: [String: Any] = ["slides": slides, "output_path": output.path]
        payload["title"] = arguments["title"] as? String ?? ""
        payload["subtitle"] = arguments["subtitle"] as? String ?? ""
        return await runOfficeTool("ppt-generate", payload: payload) { result in
            self.revealOfficeExport(output)
            let count = (result["slide_count"] as? Int).map(String.init) ?? "?"
            return CapabilityResult(
                title: "PPT 已生成",
                content: "\(count) 张幻灯片 → \(output.path)",
                requiresUserApproval: false
            )
        }
    }

    func generateDocxCapability(arguments: [String: Any]) async -> CapabilityResult {
        guard let markdown = arguments["markdown"] as? String,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return officeFailure("需要 markdown 参数：文档正文（支持 #标题、- 列表、**加粗**）。")
        }
        guard let output = officeOutputURL(arguments["output_name"] as? String, fallback: "文档", ext: "docx") else {
            return officeFailure("输出路径无效。")
        }
        let payload: [String: Any] = [
            "markdown": markdown,
            "title": arguments["title"] as? String ?? "",
            "output_path": output.path
        ]
        return await runOfficeTool("docx-generate", payload: payload) { _ in
            self.revealOfficeExport(output)
            return CapabilityResult(title: "Word 文档已生成", content: output.path, requiresUserApproval: false)
        }
    }

    func readDocxCapability(arguments: [String: Any]) async -> CapabilityResult {
        guard let url = resolveOfficeInputPath(arguments["path"] as? String) else {
            return officeFailure("需要 path 参数：要读取的 .docx 文件路径。")
        }
        let payload: [String: Any] = [
            "path": url.path,
            "max_chars": arguments["max_chars"] as? Int ?? 20000
        ]
        return await runOfficeTool("docx-read", payload: payload) { result in
            let text = result["text"] as? String ?? ""
            let truncated = (result["truncated"] as? Bool) == true
            return CapabilityResult(
                title: "Word · \(url.lastPathComponent)",
                content: text.isEmpty ? "（文档没有可提取的文本）" : text + (truncated ? "\n\n（已截断）" : ""),
                requiresUserApproval: false
            )
        }
    }

    func readXlsxCapability(arguments: [String: Any]) async -> CapabilityResult {
        guard let url = resolveOfficeInputPath(arguments["path"] as? String) else {
            return officeFailure("需要 path 参数：要读取的 .xlsx 文件路径。")
        }
        var payload: [String: Any] = [
            "path": url.path,
            "max_rows": arguments["max_rows"] as? Int ?? 60
        ]
        if let sheet = arguments["sheet"] as? String, !sheet.isEmpty { payload["sheet"] = sheet }
        return await runOfficeTool("xlsx-read", payload: payload) { result in
            let sheet = result["sheet"] as? String ?? ""
            let sheets = (result["sheets"] as? [String])?.joined(separator: ", ") ?? ""
            let total = result["total_rows"] as? Int ?? 0
            let truncated = (result["truncated"] as? Bool) == true
            let text = result["text"] as? String ?? ""
            return CapabilityResult(
                title: "Excel · \(url.lastPathComponent)",
                content: "工作表 \(sheet)（全部：\(sheets)）· \(total) 行\(truncated ? "，仅显示前若干行" : "")\n\n\(text)",
                requiresUserApproval: false
            )
        }
    }

    func writeXlsxCapability(arguments: [String: Any]) async -> CapabilityResult {
        guard let rows = arguments["rows"] as? [[Any]], !rows.isEmpty else {
            return officeFailure("需要 rows 参数：二维数组，第一行建议是表头。")
        }
        guard let output = officeOutputURL(arguments["output_name"] as? String, fallback: "表格", ext: "xlsx") else {
            return officeFailure("输出路径无效。")
        }
        let payload: [String: Any] = [
            "rows": rows,
            "sheet_name": arguments["sheet_name"] as? String ?? "Sheet1",
            "output_path": output.path
        ]
        return await runOfficeTool("xlsx-write", payload: payload) { result in
            self.revealOfficeExport(output)
            let count = (result["row_count"] as? Int).map(String.init) ?? "?"
            return CapabilityResult(title: "Excel 已生成", content: "\(count) 行 → \(output.path)", requiresUserApproval: false)
        }
    }

    // MARK: - Helpers

    private func runOfficeTool(
        _ tool: String,
        payload: [String: Any],
        onSuccess: ([String: Any]) -> CapabilityResult
    ) async -> CapabilityResult {
        if !officeToolRunner.isBootstrapped {
            messages.append(ChatMessage(
                role: .assistant,
                content: "首次使用 Office 工具，正在准备运行环境（约需 1 分钟）…",
                localOnly: true
            ))
        }
        do {
            let payloadJSON = try JSONSerialization.data(withJSONObject: payload)
            let resultData = try await officeToolRunner.run(tool: tool, payloadJSON: payloadJSON)
            guard let result = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any] else {
                return officeFailure("工具输出不是有效 JSON。")
            }
            if let error = result["error"] as? String {
                return officeFailure(error)
            }
            return onSuccess(result)
        } catch {
            return officeFailure(error.localizedDescription)
        }
    }

    private func officeFailure(_ message: String) -> CapabilityResult {
        CapabilityResult(title: "Office 工具失败", content: message, requiresUserApproval: false)
    }

    /// 输入路径：绝对路径、~、或相对当前 workspace。
    private func resolveOfficeInputPath(_ raw: String?) -> URL? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        path = (path as NSString).expandingTildeInPath
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: runtimeCwd).appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
    }

    private func officeOutputURL(_ rawName: String?, fallback: String, ext: String) -> URL? {
        try? FileManager.default.createDirectory(at: officeExportDirectory, withIntermediateDirectories: true)
        var name = (rawName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            name = "\(fallback)-\(stamp.string(from: Date()))"
        }
        // 只保留文件名，去掉路径分隔符，防止逃出导出目录。
        name = name.components(separatedBy: "/").last ?? name
        if !name.lowercased().hasSuffix(".\(ext)") { name += ".\(ext)" }
        return officeExportDirectory.appendingPathComponent(name)
    }

    private func revealOfficeExport(_ url: URL) {
        // 测试环境不弹访达窗口。
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
