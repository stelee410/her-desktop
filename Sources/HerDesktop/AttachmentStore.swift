import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AttachmentStoreError: LocalizedError {
    case missingFile(String)
    case unreadableFile(String)
    case directoryNotSupported(String)
    case fileTooLarge(String, Int64)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "Attachment file does not exist: \(path)"
        case .unreadableFile(let path):
            return "Attachment file is not readable: \(path)"
        case .directoryNotSupported(let path):
            return "Folders are not supported as attachments yet: \(path)"
        case .fileTooLarge(let name, let bytes):
            return "\(name) is too large to attach (\(bytes) bytes)."
        }
    }
}

final class AttachmentStore {
    private let cwd: String
    private let fileManager: FileManager
    private let maxStoredBytes: Int64
    private let maxPreviewBytes: Int

    init(
        cwd: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default,
        maxStoredBytes: Int64 = 250 * 1024 * 1024,
        maxPreviewBytes: Int = 12 * 1024
    ) {
        self.cwd = cwd
        self.fileManager = fileManager
        self.maxStoredBytes = maxStoredBytes
        self.maxPreviewBytes = maxPreviewBytes
    }

    func importFile(_ sourceURL: URL) throws -> MessageAttachment {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let source = sourceURL.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw AttachmentStoreError.missingFile(source.path)
        }
        guard !isDirectory.boolValue else {
            throw AttachmentStoreError.directoryNotSupported(source.path)
        }
        guard fileManager.isReadableFile(atPath: source.path) else {
            throw AttachmentStoreError.unreadableFile(source.path)
        }

        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if byteCount > maxStoredBytes {
            throw AttachmentStoreError.fileTooLarge(source.lastPathComponent, byteCount)
        }

        let destination = try destinationURL(for: source)
        try fileManager.copyItem(at: source, to: destination)
        let kind = Self.kind(for: source)
        let textPreview = try preview(kind: kind, source: destination, byteCount: byteCount)

        return MessageAttachment(
            originalName: source.lastPathComponent,
            storedPath: destination.path,
            kind: kind,
            mimeType: Self.mimeType(for: source),
            byteCount: byteCount,
            summary: Self.summary(for: kind, byteCount: byteCount, hasPreview: textPreview != nil),
            textPreview: textPreview
        )
    }

    private func destinationURL(for source: URL) throws -> URL {
        let directory = HerWorkspacePaths.attachmentDirectory(cwd: cwd)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = Self.safeFileName(source.lastPathComponent)
        return directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
    }

    private func preview(kind: MessageAttachment.Kind, source: URL, byteCount: Int64) throws -> String? {
        if kind == .image {
            return AttachmentMetadataExtractor.imageMetadata(for: source)
        }
        guard kind == .text || kind == .pdf else { return nil }
        if kind == .pdf {
            guard let document = PDFDocument(url: source) else {
                return "PDF text extraction could not open this file. The file is attached for reference."
            }
            let text = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return "PDF text extraction found no selectable text. The file is attached for reference."
            }
            if text.count > maxPreviewBytes {
                return String(text.prefix(maxPreviewBytes)) + "\n...(preview truncated; original \(text.count) characters, \(document.pageCount) pages)"
            }
            return text
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: min(maxPreviewBytes, Int(max(0, byteCount)))) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if byteCount > Int64(maxPreviewBytes) {
            return trimmed + "\n...(preview truncated; original \(byteCount) bytes)"
        }
        return trimmed
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

    private static func mimeType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    private static func summary(for kind: MessageAttachment.Kind, byteCount: Int64, hasPreview: Bool) -> String {
        switch kind {
        case .text:
            return hasPreview ? "UTF-8 text preview included." : "Text-like file attached; no UTF-8 preview was available."
        case .image:
            return hasPreview ? "Image metadata preview included." : "Image attached for multimodal or plugin processing."
        case .video:
            return "Video attached for future media processing; metadata is available now."
        case .audio:
            return "Audio attached for future transcription or plugin processing."
        case .pdf:
            return hasPreview ? "PDF text preview included." : "PDF attached; no selectable text preview was available."
        case .archive:
            return "Archive attached; contents are not expanded automatically."
        case .other:
            return "File attached; Her can reason over metadata and route it to tools."
        }
    }

    private static func safeFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "attachment" : collapsed
    }
}
