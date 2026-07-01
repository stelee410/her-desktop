import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AttachmentInspectorError: LocalizedError {
    case missingPath
    case outsideAttachmentDirectory(String)
    case missingFile(String)
    case directoryNotSupported(String)
    case unsupportedTextEncoding(String)
    case pdfUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .missingPath:
            return "Missing attachment path."
        case .outsideAttachmentDirectory(let path):
            return "Attachment inspection is limited to .her/attachments: \(path)"
        case .missingFile(let path):
            return "Attachment file does not exist: \(path)"
        case .directoryNotSupported(let path):
            return "Attachment path is a directory: \(path)"
        case .unsupportedTextEncoding(let path):
            return "Attachment is not valid UTF-8 text: \(path)"
        case .pdfUnreadable(let path):
            return "PDF could not be opened or contained no extractable text: \(path)"
        }
    }
}

final class AttachmentInspector {
    private let cwd: String
    private let fileManager: FileManager

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
    }

    func inspect(path rawPath: String, maxCharacters: Int = 20_000) throws -> String {
        let url = try resolveAttachmentPath(rawPath)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let kind = Self.kind(for: url)
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let maxCharacters = min(max(maxCharacters, 1), 80_000)

        let extracted: String
        switch kind {
        case .text:
            extracted = try inspectText(url: url, maxCharacters: maxCharacters)
        case .pdf:
            extracted = try inspectPDF(url: url, maxCharacters: maxCharacters)
        case .image:
            extracted = inspectImage(url: url)
        default:
            extracted = "No content extractor is available for \(kind.rawValue) attachments yet. The metadata below is still available for routing to a plugin or external processor."
        }

        return """
        attachment: \(url.lastPathComponent)
        path: \(url.path)
        kind: \(kind.rawValue)
        mime_type: \(mimeType)
        bytes: \(byteCount)

        \(extracted)
        """
    }

    private func resolveAttachmentPath(_ rawPath: String) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AttachmentInspectorError.missingPath }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded)
        } else {
            candidate = HerWorkspacePaths.attachmentDirectory(cwd: cwd)
                .appendingPathComponent(expanded)
        }

        let standardized = candidate.standardizedFileURL
        let root = HerWorkspacePaths.attachmentDirectory(cwd: cwd).standardizedFileURL
        guard standardized.path == root.path || standardized.path.hasPrefix(root.path + "/") else {
            throw AttachmentInspectorError.outsideAttachmentDirectory(standardized.path)
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            throw AttachmentInspectorError.missingFile(standardized.path)
        }
        guard !isDirectory.boolValue else {
            throw AttachmentInspectorError.directoryNotSupported(standardized.path)
        }
        return standardized
    }

    private func inspectText(url: URL, maxCharacters: Int) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AttachmentInspectorError.unsupportedTextEncoding(url.path)
        }
        let truncated = text.count > maxCharacters
        return """
        content_type: utf8_text
        characters_returned: \(min(text.count, maxCharacters))
        truncated: \(truncated)

        \(String(text.prefix(maxCharacters)))
        """
    }

    private func inspectPDF(url: URL, maxCharacters: Int) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw AttachmentInspectorError.pdfUnreadable(url.path)
        }
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AttachmentInspectorError.pdfUnreadable(url.path)
        }
        let truncated = text.count > maxCharacters
        return """
        content_type: pdf_text
        pages: \(document.pageCount)
        characters_returned: \(min(text.count, maxCharacters))
        truncated: \(truncated)

        \(String(text.prefix(maxCharacters)))
        """
    }

    private func inspectImage(url: URL) -> String {
        AttachmentMetadataExtractor.imageMetadata(for: url)
            ?? "content_type: image_metadata\nmetadata: unavailable"
    }

    private static func kind(for url: URL) -> MessageAttachment.Kind {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return .other
        }
        if type.conforms(to: .plainText) || type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) {
            return .text
        }
        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        if type.conforms(to: .audio) {
            return .audio
        }
        if type.conforms(to: .pdf) {
            return .pdf
        }
        if type.conforms(to: .archive) {
            return .archive
        }
        return .other
    }
}
