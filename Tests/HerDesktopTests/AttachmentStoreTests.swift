import XCTest
import AppKit
import CoreGraphics
@testable import HerDesktop

final class AttachmentStoreTests: XCTestCase {
    func testImportTextFileCopiesAttachmentAndBuildsPreview() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-attachment-store-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("brief.txt")
        try "Her Desktop launch plan".write(to: source, atomically: true, encoding: .utf8)

        let store = AttachmentStore(cwd: root.path)
        let attachment = try store.importFile(source)

        XCTAssertEqual(attachment.originalName, "brief.txt")
        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertTrue(attachment.textPreview?.contains("launch plan") == true)
        XCTAssertTrue(attachment.storedPath.contains("/.her/attachments/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.storedPath))
        XCTAssertTrue(attachment.contextDescription.contains("Attached files") == false)
        XCTAssertTrue([attachment].contextDescription.contains("Attached files:"))
    }

    func testImportPDFBuildsSelectableTextPreview() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-attachment-pdf-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("brief.pdf")
        try writeSimplePDF(text: "Her Desktop PDF launch brief", to: source)

        let store = AttachmentStore(cwd: root.path)
        let attachment = try store.importFile(source)

        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertTrue(attachment.summary.contains("PDF text preview included"))
        XCTAssertTrue(attachment.textPreview?.contains("PDF launch brief") == true)
    }

    func testImportImageBuildsVisualMetadataPreview() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-attachment-image-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("mock.png")
        try writePNG(width: 4, height: 3, to: source)

        let store = AttachmentStore(cwd: root.path)
        let attachment = try store.importFile(source)

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertTrue(attachment.summary.contains("Image metadata preview included"))
        XCTAssertTrue(attachment.textPreview?.contains("content_type: image_metadata") == true)
        XCTAssertTrue(attachment.textPreview?.contains("pixel_width: 4") == true)
        XCTAssertTrue(attachment.textPreview?.contains("pixel_height: 3") == true)
        XCTAssertTrue(attachment.contextDescription.contains("visual_metadata:"))
        XCTAssertFalse(attachment.contextDescription.contains("text_preview:"))
    }

    func testRejectsDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-attachment-directory-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = AttachmentStore(cwd: root.path)

        XCTAssertThrowsError(try store.importFile(directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Folders are not supported"))
        }
    }

    private func writeSimplePDF(text: String, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 120)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.black
        ]
        NSString(string: text).draw(in: CGRect(x: 24, y: 52, width: 252, height: 40), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
