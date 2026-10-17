import Foundation
import Testing
@testable import MacViewer

@Test func updateVersionsCompareNumerically() {
    #expect(UpdateChecker.isVersion("0.3.2", newerThan: "0.3.1"))
    #expect(UpdateChecker.isVersion("0.10.0", newerThan: "0.9.9"))
    #expect(UpdateChecker.isVersion("1.0", newerThan: "0.99.99"))
    #expect(UpdateChecker.isVersion("0.3.1.1", newerThan: "0.3.1"))
    #expect(!UpdateChecker.isVersion("0.3.1", newerThan: "0.3.1"))
    #expect(!UpdateChecker.isVersion("0.3", newerThan: "0.3.0"))
    #expect(!UpdateChecker.isVersion("0.3.0", newerThan: "0.3.1"))
    #expect(!UpdateChecker.isVersion("0.3.2-beta", newerThan: "0.3.2"))
}

@Test func updateReleaseParsingPicksTheDMGAndStripsTheTagPrefix() throws {
    let json = """
    {"tag_name": "v0.3.2", "html_url": "https://github.com/DeanOpen/MacViewer/releases/tag/v0.3.2",
     "draft": false, "prerelease": false,
     "assets": [
       {"name": "MacViewer-0.3.2.zip", "browser_download_url": "https://github.com/DeanOpen/MacViewer/releases/download/v0.3.2/MacViewer-0.3.2.zip"},
       {"name": "MacViewer-0.3.2.dmg", "browser_download_url": "https://github.com/DeanOpen/MacViewer/releases/download/v0.3.2/MacViewer-0.3.2.dmg"},
       {"name": "SHA256SUMS.txt", "browser_download_url": "https://github.com/DeanOpen/MacViewer/releases/download/v0.3.2/SHA256SUMS.txt"}
     ]}
    """
    let release = try UpdateChecker.parseRelease(Data(json.utf8))
    #expect(release.version == "0.3.2")
    #expect(release.dmgURL?.lastPathComponent == "MacViewer-0.3.2.dmg")
    #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v0.3.2"))
}

@Test func updateReleaseParsingRejectsPrereleasesAndForeignDownloadHosts() {
    let prerelease = """
    {"tag_name": "v0.4.0-beta", "html_url": "https://github.com/DeanOpen/MacViewer/releases/tag/v0.4.0-beta",
     "prerelease": true, "assets": []}
    """
    #expect(throws: (any Error).self) { try UpdateChecker.parseRelease(Data(prerelease.utf8)) }
    let foreign = """
    {"tag_name": "v0.3.2", "html_url": "https://github.com/DeanOpen/MacViewer/releases/tag/v0.3.2",
     "assets": [{"name": "MacViewer-0.3.2.dmg", "browser_download_url": "https://example.com/MacViewer-0.3.2.dmg"}]}
    """
    #expect(throws: (any Error).self) { try UpdateChecker.parseRelease(Data(foreign.utf8)) }
}

@MainActor
@Test func automaticUpdateChecksRespectTheSetting() throws {
    let suite = "UpdateCheckerTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let checker = UpdateChecker(currentVersion: "0.3.2", defaults: defaults)
    defaults.set(false, forKey: UpdateChecker.automaticKey)
    checker.checkAutomatically()
    #expect(checker.state == .idle)
}

@Test func updateNotesDropTheInstallSection() {
    let body = """
    ## Install
    1. Download the DMG.
    2. Drag MacViewer to Applications.

    ## What's Changed
    * Close connections when quitting
    """
    #expect(UpdateChecker.releaseNotes(body) == "## What's Changed\n* Close connections when quitting")
    #expect(UpdateChecker.releaseNotes("") == "")
}
