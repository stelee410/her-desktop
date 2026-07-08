import AppKit
import XCTest
@testable import HerDesktop

@MainActor
final class PasteAttachmentTests: XCTestCase {
    private func makeModel(_ label: String) -> AppViewModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-paste-\(label)-\(UUID().uuidString)", isDirectory: true)
        return AppViewModel(cwd: root.path)
    }

    private func makePasteboard(_ label: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("her-test-\(label)-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func tinyPNGData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testPastedPNGDataBecomesImageAttachment() throws {
        let model = makeModel("png")
        let pasteboard = makePasteboard("png")
        pasteboard.setData(try tinyPNGData(), forType: .png)

        XCTAssertTrue(model.attachFromPasteboard(pasteboard))
        XCTAssertEqual(model.pendingAttachments.count, 1)
        let attachment = try XCTUnwrap(model.pendingAttachments.first)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertTrue(attachment.originalName.hasSuffix(".png"))
    }

    func testPastedTIFFIsConvertedToPNGAttachment() throws {
        let model = makeModel("tiff")
        let pasteboard = makePasteboard("tiff")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try tinyPNGData()))
        pasteboard.setData(try XCTUnwrap(bitmap.tiffRepresentation), forType: .tiff)

        XCTAssertTrue(model.attachFromPasteboard(pasteboard))
        XCTAssertEqual(model.pendingAttachments.first?.kind, .image)
    }

    func testPastedFileURLsAttachDirectly() throws {
        let model = makeModel("file")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-paste-source-\(UUID().uuidString).txt")
        try "hello paste".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let pasteboard = makePasteboard("file")
        pasteboard.writeObjects([file as NSURL])

        XCTAssertTrue(model.attachFromPasteboard(pasteboard))
        XCTAssertEqual(model.pendingAttachments.first?.originalName, file.lastPathComponent)
    }

    func testPlainTextPastePassesThrough() {
        let model = makeModel("text")
        let pasteboard = makePasteboard("text")
        pasteboard.setString("只是文字", forType: .string)

        XCTAssertFalse(model.attachFromPasteboard(pasteboard),
                       "text paste stays with the system text field behavior")
        XCTAssertTrue(model.pendingAttachments.isEmpty)
    }
}
