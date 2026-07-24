import XCTest
@testable import HerDesktop

final class AppUpdaterTests: XCTestCase {
    func testParseLatestReleasePicksDMGAsset() throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "Her Desktop 0.2.0",
          "html_url": "https://github.com/stelee410/her-desktop/releases/tag/v0.2.0",
          "body": "新增自动更新。",
          "assets": [
            {"name": "HerDesktop.zip", "browser_download_url": "https://example.com/HerDesktop.zip"},
            {"name": "HerDesktop-0.2.0.dmg", "browser_download_url": "https://example.com/HerDesktop-0.2.0.dmg"}
          ]
        }
        """
        let release = try XCTUnwrap(AppUpdater.parseLatestRelease(Data(json.utf8)))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.dmgURL.absoluteString, "https://example.com/HerDesktop-0.2.0.dmg")
        XCTAssertEqual(release.notes, "新增自动更新。")
    }

    func testParseLatestReleaseReturnsNilWithoutDMG() {
        let json = """
        {"tag_name":"v0.2.0","assets":[{"name":"HerDesktop.zip","browser_download_url":"https://example.com/a.zip"}]}
        """
        XCTAssertNil(AppUpdater.parseLatestRelease(Data(json.utf8)))
        XCTAssertNil(AppUpdater.parseLatestRelease(Data("not json".utf8)))
    }

    func testVersionCompare() {
        XCTAssertEqual(AppUpdater.compare("0.2.0", "0.1.0"), .orderedDescending)
        XCTAssertEqual(AppUpdater.compare("v0.1.0", "0.1.0"), .orderedSame)
        XCTAssertEqual(AppUpdater.compare("0.1.0", "0.1.1"), .orderedAscending)
        XCTAssertEqual(AppUpdater.compare("1.0.0", "1.0.0-beta"), .orderedDescending)
        XCTAssertEqual(AppUpdater.compare("0.10.0", "0.9.0"), .orderedDescending) // numeric, not lexical
        XCTAssertEqual(AppUpdater.compare("1.2", "1.2.0"), .orderedSame)
    }

    func testIsNewer() {
        XCTAssertTrue(AppUpdater.isNewer("v0.2.0", than: "0.1.0"))
        XCTAssertFalse(AppUpdater.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(AppUpdater.isNewer("0.0.9", than: "0.1.0"))
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(AppUpdater.shellQuote("/Applications/HerDesktop.app"), "'/Applications/HerDesktop.app'")
        XCTAssertEqual(AppUpdater.shellQuote("a'b"), "'a'\\''b'")
    }
}
