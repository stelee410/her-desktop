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
}
