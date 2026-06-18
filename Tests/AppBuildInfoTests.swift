import Foundation
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
        ], bundlePath: "/tmp/Current/dist/ASTRA.app", executablePath: "/tmp/Current/dist/ASTRA.app/Contents/MacOS/ASTRA")

        #expect(info.displayName == "ASTRA")
        #expect(info.version == "0.1.1")
        #expect(info.build == "12")
        #expect(info.gitCommit == "83768b3a1234")
        #expect(info.buildDate == "2026-06-17T18:22:17Z")
        #expect(info.bundlePath == "/tmp/Current/dist/ASTRA.app")
        #expect(info.executablePath == "/tmp/Current/dist/ASTRA.app/Contents/MacOS/ASTRA")
        #expect(info.channelDisplayName == "ASTRA")
        #expect(info.installedBuildSummary == "ASTRA 0.1.1 (12)")
        #expect(info.provenanceSummary == "ASTRA 0.1.1 (12), commit 83768b3a1234, built 2026-06-17T18:22:17Z, bundle /tmp/Current/dist/ASTRA.app")
        #expect(info.auditFields["app_bundle_path"] == "/tmp/Current/dist/ASTRA.app")
        #expect(info.auditFields["app_executable_path"] == "/tmp/Current/dist/ASTRA.app/Contents/MacOS/ASTRA")
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
        #expect(info.bundlePath == "unknown")
        #expect(info.executablePath == "unknown")
    }

    @Test("redacts home directory paths in diagnostics fields")
    func redactsHomeDirectoryPathsInDiagnosticsFields() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundlePath = "\(home)/Applications/ASTRA Dev.app"
        let executablePath = "\(bundlePath)/Contents/MacOS/ASTRA Dev"
        let info = AppBuildInfo(infoDictionary: [
            "CFBundleDisplayName": "ASTRA Dev",
            "CFBundleShortVersionString": "0.1.1",
            "CFBundleVersion": "13",
            "ASTRAChannel": "dev",
            "ASTRAGitCommit": "83768b3a1234",
            "ASTRABuildDate": "2026-06-17T18:22:17Z"
        ], bundlePath: bundlePath, executablePath: executablePath)

        #expect(info.bundlePath == "$HOME/Applications/ASTRA Dev.app")
        #expect(info.executablePath == "$HOME/Applications/ASTRA Dev.app/Contents/MacOS/ASTRA Dev")
        #expect(info.provenanceSummary.contains("bundle $HOME/Applications/ASTRA Dev.app"))
        #expect(info.auditFields["app_bundle_path"] == "$HOME/Applications/ASTRA Dev.app")
        #expect(info.auditFields["app_executable_path"] == "$HOME/Applications/ASTRA Dev.app/Contents/MacOS/ASTRA Dev")
        #expect(!info.provenanceSummary.contains(home))
        #expect(!info.auditFields.values.contains { $0.contains(home) })
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
