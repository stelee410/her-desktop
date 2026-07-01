import XCTest
@testable import HerDesktop

final class PresenceCopyTests: XCTestCase {
    func testReadyGreetingUsesProfileNameAndDaypart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 6, day: 30, hour: 9).date!
        let profile = AgentProfile(
            displayName: "Her",
            userDisplayName: "Steven",
            relationship: "Stage: companion",
            memoryID: "",
            known: true
        )

        let greeting = PresenceCopy.greeting(
            connectionState: .ready,
            agentProfile: profile,
            now: morning,
            calendar: calendar
        )

        XCTAssertEqual(greeting, "早上好，Steven。\n今天我们从哪里开始？")
    }

    func testGreetingReflectsActiveRuntimeStates() {
        let profile = AgentProfile.empty(userID: "stelee")

        XCTAssertEqual(PresenceCopy.greeting(connectionState: .thinking, agentProfile: profile), "我在整理上下文。")
        XCTAssertEqual(PresenceCopy.greeting(connectionState: .working, agentProfile: profile), "我在执行工具。")
        XCTAssertEqual(PresenceCopy.greeting(connectionState: .listening, agentProfile: profile), "我在听。")
        XCTAssertEqual(PresenceCopy.greeting(connectionState: .speaking, agentProfile: profile), "我在说给你听。")
        XCTAssertEqual(PresenceCopy.greeting(connectionState: .error, agentProfile: profile), "连接有点不稳。")
        XCTAssertEqual(PresenceCopy.greeting(connectionState: .offline, agentProfile: profile), "配置好服务后，我就能接上工作。")
    }

    func testServiceStatusSummarizesRemoteHealth() {
        XCTAssertEqual(PresenceCopy.serviceStatus([
            service(id: "agentllm", state: .online),
            service(id: "agentmem", state: .online)
        ]), PresenceStatus(title: "Synced", systemImage: "checkmark.circle", tone: .healthy))

        XCTAssertEqual(PresenceCopy.serviceStatus([
            service(id: "agentllm", state: .checking),
            service(id: "agentmem", state: .unknown)
        ]), PresenceStatus(title: "Checking", systemImage: "arrow.triangle.2.circlepath", tone: .active))

        XCTAssertEqual(PresenceCopy.serviceStatus([
            service(id: "agentllm", state: .online),
            service(id: "agentmem", state: .offline)
        ]), PresenceStatus(title: "Partial", systemImage: "exclamationmark.circle", tone: .warning))

        XCTAssertEqual(PresenceCopy.serviceStatus([
            service(id: "agentllm", state: .offline),
            service(id: "agentmem", state: .offline)
        ]), PresenceStatus(title: "Setup Needed", systemImage: "exclamationmark.circle", tone: .warning))
    }

    private func service(id: String, state: ServiceHealthState) -> ServiceHealth {
        ServiceHealth(
            id: id,
            name: id,
            kind: "test",
            baseURL: nil,
            state: state,
            summary: state.rawValue,
            checkedAt: nil
        )
    }
}
