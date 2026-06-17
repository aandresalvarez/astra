import Testing
@testable import ASTRA

@Suite("App Build Info")
struct AppBuildInfoTests {
    @Test("reads app identity from bundle dictionary")
    func readsAppIdentityFromDictionary() {
        let info = AppBuildInfo(infoDictionary: [
            "CFBundleDisplayName": "ASTRA",
            "CFBundleShortVersionString": "0.1.1",
            "CFBundleVersion": "12",
            "ASTRAChannel": "prod",
            "ASTRAGitCommit": "83768b3a1234",
            "ASTRABuildDate": "2026-06-17T18:22:17Z"
        ])

        #expect(info.displayName == "ASTRA")
        #expect(info.version == "0.1.1")
        #expect(info.build == "12")
        #expect(info.gitCommit == "83768b3a1234")
        #expect(info.buildDate == "2026-06-17T18:22:17Z")
        #expect(info.channelDisplayName == "ASTRA")
        #expect(info.installedBuildSummary == "ASTRA 0.1.1 (12)")
        #expect(info.provenanceSummary == "ASTRA 0.1.1 (12), commit 83768b3a1234, built 2026-06-17T18:22:17Z")
    }

    @Test("falls back when bundle values are missing or blank")
    func fallsBackForMissingValues() {
        let info = AppBuildInfo(infoDictionary: [
            "CFBundleDisplayName": "  ",
            "CFBundleShortVersionString": "",
            "CFBundleVersion": "\n"
        ])

        #expect(!info.displayName.isEmpty)
        #expect(info.version == "0.0.0")
        #expect(info.build == "0")
        #expect(info.gitCommit == "unknown")
        #expect(info.buildDate == "unknown")
    }

    @Test("maps development channel to display name")
    func mapsDevelopmentChannel() {
        let info = AppBuildInfo(infoDictionary: [
            "CFBundleDisplayName": "ASTRA Dev",
            "CFBundleShortVersionString": "0.1.1",
            "CFBundleVersion": "13",
            "ASTRAChannel": "dev"
        ])

        #expect(info.channelDisplayName == "ASTRA Dev")
        #expect(info.installedBuildSummary == "ASTRA Dev 0.1.1 (13)")
    }

    @Test("about text includes README product positioning")
    func aboutTextIncludesProductPositioning() {
        let text = AstraAboutInfo.creditsPlainText

        #expect(text.contains("Agent Routines for Tasks, Runs, and Automation"))
        #expect(text.contains("supervising delegated AI work"))
        #expect(text.contains("durable workspaces"))
        #expect(text.contains("https://github.com/susom/astra"))
    }
}
