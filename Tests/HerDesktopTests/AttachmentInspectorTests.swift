import XCTest
import AppKit
import CoreGraphics
@testable import HerDesktop

final class AttachmentInspectorTests: XCTestCase {
    func testInspectTextAttachmentUnderHerAttachments() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-attachment-inspector-\(UUID().uuidString)", isDirectory: true)
        let attachments = HerWorkspacePaths.attachmentDirectory(cwd: root.path)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let file = attachments.appendingPathComponent("note.txt")
        try "Imported attachment content".write(to: file, atomically: true, encoding: .utf8)

        let result = try AttachmentInspector(cwd: root.path).inspect(path: file.path, maxCharacters: 12)

        XCTAssertTrue(result.contains("Attachment Inspected") == false)
        XCTAssertTrue(result.contains("kind: text"))
        XCTAssertTrue(result.contains("content_type: utf8_text"))
        XCTAssertTrue(result.contains("Imported att"))
        XCTAssertTrue(result.contains("truncated: true"))
    }

    func testRejectsPathsOutsideAttachmentDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-attachment-inspector-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("outside.txt")
        try "outside".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AttachmentInspector(cwd: root.path).inspect(path: file.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains(".her/attachments"))
        }
    }

    func testInspectImageAttachmentReturnsVisualMetadata() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-attachment-inspector-image-\(UUID().uuidString)", isDirectory: true)
        let attachments = HerWorkspacePaths.attachmentDirectory(cwd: root.path)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let file = attachments.appendingPathComponent("mock.png")
        try writePNG(width: 5, height: 2, to: file)

        let result = try AttachmentInspector(cwd: root.path).inspect(path: file.path)

        XCTAssertTrue(result.contains("kind: image"))
        XCTAssertTrue(result.contains("content_type: image_metadata"))
        XCTAssertTrue(result.contains("pixel_width: 5"))
        XCTAssertTrue(result.contains("pixel_height: 2"))
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
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
