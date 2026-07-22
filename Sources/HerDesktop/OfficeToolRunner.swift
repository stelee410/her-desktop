import Foundation

/// Office 文档工具的 Python sidecar：pptx/docx/xlsx 没有可用的系统框架，
/// 用 `.her/office/venv`（python-pptx / python-docx / openpyxl）+ 打包的
/// office_tool.py 完成。venv 首次使用时自举，模式与 browser sidecar 一致。
/// PDF 读取/合并不经这里——PDFKit 原生就够（见 AppViewModel+Office）。
/// actor：并发的首次调用只自举一次，工具执行天然串行。
actor OfficeToolRunner {
    /// 依赖清单变化时递增：标记文件不匹配会触发重新 pip install。
    private static let depsMarker = "deps-v1"
    private static let packages = ["python-pptx", "python-docx", "openpyxl"]

    private let officeDirectory: URL

    init(cwd: String) {
        officeDirectory = HerWorkspacePaths.localAgentDirectory(cwd: cwd)
            .appendingPathComponent("office", isDirectory: true)
    }

    private var venvPython: URL {
        officeDirectory.appendingPathComponent("venv/bin/python")
    }

    private var markerFile: URL {
        officeDirectory.appendingPathComponent("\(Self.depsMarker).ok")
    }

    enum OfficeError: LocalizedError {
        case pythonNotFound
        case bootstrapFailed(String)
        case scriptMissing
        case toolFailed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound:
                return "没有找到可用的 Python 3。请安装（例如 brew install python@3.13）后重试。"
            case .bootstrapFailed(let message):
                return "Office 工具环境安装失败：\(message)"
            case .scriptMissing:
                return "office_tool.py 脚本资源缺失，请重新安装应用。"
            case .toolFailed(let message):
                return message
            }
        }
    }

    nonisolated var isBootstrapped: Bool {
        let base = officeDirectory
        return FileManager.default.fileExists(atPath: base.appendingPathComponent("\(Self.depsMarker).ok").path)
            && FileManager.default.isExecutableFile(atPath: base.appendingPathComponent("venv/bin/python").path)
    }

    /// 跑一个子工具：payload 走临时 JSON 文件（命令行长度安全），
    /// 返回脚本 stdout 的 JSON 对象字节（调用方自行解析）。
    func run(tool: String, payloadJSON: Data, timeout: TimeInterval = 90) async throws -> Data {
        try await ensureReady()
        guard let script = Bundle.herResources.url(forResource: "office_tool", withExtension: "py") else {
            throw OfficeError.scriptMissing
        }
        let payloadFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-office-\(UUID().uuidString).json")
        try payloadJSON.write(to: payloadFile)
        defer { try? FileManager.default.removeItem(at: payloadFile) }

        let process = Process()
        process.executableURL = venvPython
        process.arguments = [script.path, tool, payloadFile.path]
        let output = try await ChildProcessRunner.run(process, timeout: timeout)
        guard output.status == 0 else {
            let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
            let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
            throw OfficeError.toolFailed(String((stderr.isEmpty ? stdout : stderr).suffix(400)))
        }
        return output.stdout
    }

    private func ensureReady() async throws {
        if isBootstrapped { return }
        guard let python = await MainActor.run(body: { BrowserController.resolveBootstrapPython() }) else {
            throw OfficeError.pythonNotFound
        }
        try FileManager.default.createDirectory(at: officeDirectory, withIntermediateDirectories: true)
        try await runToCompletion(python, ["-m", "venv", officeDirectory.appendingPathComponent("venv").path])
        try await runToCompletion(venvPython.path, ["-m", "pip", "install", "--quiet", "--upgrade", "pip"])
        try await runToCompletion(venvPython.path, ["-m", "pip", "install", "--quiet"] + Self.packages)
        try Data().write(to: markerFile)
    }

    private func runToCompletion(_ executable: String, _ args: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let output = try await ChildProcessRunner.run(proc, timeout: 600)
        guard output.status == 0 else {
            let err = String(data: output.stderr, encoding: .utf8) ?? ""
            throw OfficeError.bootstrapFailed(String(err.suffix(300)))
        }
    }
}
