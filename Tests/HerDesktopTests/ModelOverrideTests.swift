import XCTest
@testable import HerDesktop

@MainActor
final class ModelOverrideTests: XCTestCase {
    func testCatalogFiltersToAvailableIDsInCuratedOrder() {
        let options = AgentLLMModelCatalog.options(
            availableIDs: ["gemini-3.5-flash", "whisper-1", "claude-sonnet", "unknown-model"]
        )
        XCTAssertEqual(options.map(\.id), ["claude-sonnet", "gemini-3.5-flash"])
        XCTAssertFalse(options[0].tagline.isEmpty)
    }

    func testCatalogEmptyWhenNothingMatches() {
        XCTAssertTrue(AgentLLMModelCatalog.options(availableIDs: ["whisper-1"]).isEmpty)
    }

    func testSummaryDecodesLegacyIndexWithoutModelOverride() throws {
        let json = #"{"id":"abc","title":"t","pinned":false,"created_at":700000000,"updated_at":700000000}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let summary = try decoder.decode(ConversationSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.modelOverride)
    }

    func testActiveModelOverrideIgnoresBlankValues() {
        let model = makeModel()
        XCTAssertNil(model.activeModelOverride)
        model.setModelOverride("  ")
        XCTAssertNil(model.activeModelOverride)
        model.setModelOverride("gemini-3.5-flash")
        XCTAssertEqual(model.activeModelOverride, "gemini-3.5-flash")
        model.setModelOverride(nil)
        XCTAssertNil(model.activeModelOverride)
    }

    private func makeModel() -> AppViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-model-override-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppViewModel(config: .empty, cwd: root.path)
    }
}
