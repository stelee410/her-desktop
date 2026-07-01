import XCTest
@testable import HerDesktop

final class AgentProfileTests: XCTestCase {
    func testParsesAgentMemRelationshipPayload() {
        let profile = AgentProfile.fromRelationshipPayload(
            [
                "known": true,
                "display_name": "her",
                "user_display_name": "Steven",
                "relationship_summary": "Long-running collaborator",
                "memory_id": "mem_123"
            ],
            fallbackUserID: "fallback"
        )

        XCTAssertEqual(profile.displayName, "her")
        XCTAssertEqual(profile.userDisplayName, "Steven")
        XCTAssertEqual(profile.relationship, "Long-running collaborator")
        XCTAssertEqual(profile.memoryID, "mem_123")
        XCTAssertTrue(profile.known)
    }

    func testFallsBackForSparsePayload() {
        let profile = AgentProfile.fromRelationshipPayload(["known": "false"], fallbackUserID: "stelee")

        XCTAssertEqual(profile.displayName, "Her")
        XCTAssertEqual(profile.userDisplayName, "stelee")
        XCTAssertEqual(profile.relationship, "Getting acquainted")
        XCTAssertFalse(profile.known)
    }

    func testParsesCurrentAgentMemRelationshipViewPayload() {
        let profile = AgentProfile.fromRelationshipPayload(
            [
                "user_id": "stelee",
                "stage": "companion",
                "bond": [
                    "trust": 1.5,
                    "familiarity": 2.25,
                    "affection": 3
                ]
            ],
            fallbackUserID: "fallback"
        )

        XCTAssertEqual(profile.displayName, "Her")
        XCTAssertEqual(profile.userDisplayName, "stelee")
        XCTAssertEqual(profile.relationship, "Stage: companion · trust 1.50 · familiarity 2.25 · affection 3.00")
        XCTAssertTrue(profile.known)
    }

    func testBuildsMemorySignalFromAgentMemV7RelationshipAndEmotion() {
        let signal = MemorySignal.fromAgentMemV7(
            relationship: [
                "memory_id": "mem_123",
                "stage": "acquaintance",
                "stage_label": "相识",
                "bond": [
                    "trust": 3.1,
                    "familiarity": 5.6,
                    "affection": 4.2
                ]
            ],
            emotion: [
                "mood": [
                    "label": "焦虑警觉",
                    "mean_valence": -1.8,
                    "mean_arousal": 6.4
                ],
                "state": [
                    "current": "Anxiety",
                    "label": "焦虑"
                ]
            ]
        )

        XCTAssertEqual(signal.trust, 0.31, accuracy: 0.001)
        XCTAssertEqual(signal.confidence, 0.56, accuracy: 0.001)
        XCTAssertEqual(signal.moodLabel, "焦虑警觉")
        XCTAssertEqual(
            signal.relationshipSummary,
            "relationship 相识 · affection 4.20/10 · recent mood 焦虑警觉 · valence -1.80 · arousal 6.40"
        )

        let merged = signal.mergedWithRetrieval(count: 2, firstScore: 0.82)
        XCTAssertEqual(merged.trust, 0.82, accuracy: 0.001)
        XCTAssertEqual(merged.moodLabel, "焦虑警觉")
        XCTAssertTrue(merged.relationshipSummary.hasPrefix("2 memories nearby · relationship 相识"))
    }
}
