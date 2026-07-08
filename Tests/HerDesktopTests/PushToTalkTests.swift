import AppKit
import XCTest
@testable import HerDesktop

@MainActor
final class PushToTalkTests: XCTestCase {
    final class FakeDictation: NativeSpeechDictating {
        var started = 0
        var stopped = 0
        private var continuation: CheckedContinuation<String, Error>?

        func start(localeIdentifier: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
            started += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func stop() {
            stopped += 1
            continuation?.resume(returning: "识别结果")
            continuation = nil
        }
    }

    private var fakeDictation = FakeDictation()

    private func makeModel() -> AppViewModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-ptt-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "k"
        fakeDictation = FakeDictation()
        let model = AppViewModel(config: config, cwd: root.path, speechDictation: fakeDictation)
        model.selectedSection = .today
        model.composerFocused = true
        return model
    }

    private func spaceEvent(_ type: NSEvent.EventType, isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: isARepeat,
            keyCode: 49
        )!
    }

    func testShortTapInsertsExactlyOneSpace() {
        let model = makeModel()
        XCTAssertTrue(model.consumeSpaceEvent(spaceEvent(.keyDown)), "keyDown deferred")
        XCTAssertTrue(model.consumeSpaceEvent(spaceEvent(.keyUp)), "keyUp handled")
        XCTAssertEqual(model.draft, " ", "short tap types one space")
        XCTAssertFalse(model.isPushToTalking)
    }

    func testKeyRepeatsNeverFloodSpaces() {
        let model = makeModel()
        _ = model.consumeSpaceEvent(spaceEvent(.keyDown))
        for _ in 0..<10 {
            XCTAssertTrue(model.consumeSpaceEvent(spaceEvent(.keyDown, isARepeat: true)),
                          "repeats are always swallowed")
        }
        XCTAssertEqual(model.draft, "", "no spaces leaked while holding")
        _ = model.consumeSpaceEvent(spaceEvent(.keyUp))
        XCTAssertEqual(model.draft, " ", "release before threshold = one space")
    }

    func testHoldStartsDictationAndReleaseStops() async {
        let model = makeModel()
        _ = model.consumeSpaceEvent(spaceEvent(.keyDown))
        // Wait past the 0.8s hold threshold.
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertTrue(model.isPushToTalking, "long hold engages push-to-talk")
        XCTAssertEqual(model.connectionState, .listening)
        XCTAssertEqual(model.draft, "", "no space typed when talking")

        XCTAssertTrue(model.consumeSpaceEvent(spaceEvent(.keyUp)))
        XCTAssertFalse(model.isPushToTalking, "release ends push-to-talk")
        XCTAssertEqual(fakeDictation.stopped, 1)
        // The recognized text lands in the composer.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.draft, "识别结果")
    }

    func testOtherKeyWhilePendingFlushesTheSpaceFirst() {
        let model = makeModel()
        _ = model.consumeSpaceEvent(spaceEvent(.keyDown))
        let other = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0
        )!
        XCTAssertFalse(model.consumeSpaceEvent(other), "the other key passes through")
        XCTAssertEqual(model.draft, " ", "the deferred space flushed before it")
        XCTAssertFalse(model.isPushToTalking)
    }

    func testIgnoredOutsideTodaySection() {
        let model = makeModel()
        model.selectedSection = .tools
        XCTAssertFalse(model.consumeSpaceEvent(spaceEvent(.keyDown)),
                       "space is untouched outside the conversation")
        XCTAssertEqual(model.draft, "")
    }
}
