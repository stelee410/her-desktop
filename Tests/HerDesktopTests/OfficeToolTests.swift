import PDFKit
import XCTest
@testable import HerDesktop

@MainActor
final class OfficeToolTests: XCTestCase {
    private func makeModel() -> AppViewModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-office-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppViewModel(config: .empty, cwd: directory.path)
    }

    private func makeTestPDF(text: String, pages: Int = 1) throws -> URL {
        let document = PDFDocument()
        for index in 0..<pages {
            let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
            let renderer = NSImage(size: bounds.size, flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                ("\(text) 第\(index + 1)页" as NSString).draw(
                    at: NSPoint(x: 40, y: 200),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 20)]
                )
                return true
            }
            guard let page = PDFPage(image: renderer) else {
                throw XCTSkip("PDFPage creation failed")
            }
            document.insert(page, at: document.pageCount)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-office-test-\(UUID().uuidString).pdf")
        guard document.write(to: url) else { throw XCTSkip("PDF write failed") }
        return url
    }

    func testReadPDFRequiresValidPath() {
        let model = makeModel()
        let missing = model.readPDFCapability(arguments: ["path": "/nonexistent/definitely-not-here.pdf"])
        XCTAssertTrue(missing.content.contains("path"))
        let empty = model.readPDFCapability(arguments: [:])
        XCTAssertTrue(empty.content.contains("path"))
    }

    func testReadPDFReportsPageCount() throws {
        let model = makeModel()
        let url = try makeTestPDF(text: "hello", pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = model.readPDFCapability(arguments: ["path": url.path])
        XCTAssertTrue(result.content.contains("共 2 页"), result.content)
    }

    func testMergePDFCombinesPages() throws {
        let model = makeModel()
        let first = try makeTestPDF(text: "one", pages: 2)
        let second = try makeTestPDF(text: "two", pages: 1)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let result = model.mergePDFCapability(arguments: [
            "paths": [first.path, second.path],
            "output_name": "merged-test"
        ])
        XCTAssertTrue(result.content.contains("共 3 页"), result.content)
        let outputPath = result.content.components(separatedBy: "→ ").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: outputPath))?.pageCount, 3)
    }

    func testMergePDFRejectsSingleInput() throws {
        let model = makeModel()
        let only = try makeTestPDF(text: "solo")
        defer { try? FileManager.default.removeItem(at: only) }
        let result = model.mergePDFCapability(arguments: ["paths": [only.path]])
        XCTAssertTrue(result.content.contains("至少两个"), result.content)
    }
}
