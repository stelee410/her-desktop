import XCTest
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
}
