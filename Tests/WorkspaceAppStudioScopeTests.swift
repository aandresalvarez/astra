import Foundation
import Testing
@testable import ASTRA

/// App Studio's honest scope guard: content/marketing-site intents (which the
/// data-app schema can't express) are flagged so the UI declines instead of
/// silently shipping a mislabeled Data Entry shell — while genuine data apps,
/// including ones that mention pages, are NOT flagged (no false positives).
@Suite("Workspace App Studio Scope")
struct WorkspaceAppStudioScopeTests {
    @Test("website / landing-page / marketing intents are flagged out of scope")
    func contentSiteIntentsFlagged() {
        #expect(WorkspaceAppStudioScope.isLikelyOutOfScope("write a landing page for the med13 foundation"))
        #expect(WorkspaceAppStudioScope.isLikelyOutOfScope("build a website for my startup"))
        #expect(WorkspaceAppStudioScope.isLikelyOutOfScope("a marketing page for our product launch"))
        #expect(WorkspaceAppStudioScope.isLikelyOutOfScope("a personal portfolio site"))
        #expect(WorkspaceAppStudioScope.outOfScopeNotice(for: "a landing page") != nil)
    }

    @Test("genuine data / workflow intents are in scope")
    func dataAppIntentsInScope() {
        #expect(!WorkspaceAppStudioScope.isLikelyOutOfScope("track lab samples by status and location"))
        #expect(!WorkspaceAppStudioScope.isLikelyOutOfScope("a review queue for incoming tickets"))
        #expect(!WorkspaceAppStudioScope.isLikelyOutOfScope("a dashboard of campaign metrics"))
        #expect(!WorkspaceAppStudioScope.isLikelyOutOfScope("a volunteer intake form"))
        #expect(!WorkspaceAppStudioScope.isLikelyOutOfScope("orchestrate an AI agent to review records"))
        #expect(WorkspaceAppStudioScope.outOfScopeNotice(for: "track donors and donations") == nil)
    }

    @Test("a data app that merely mentions pages is not a false positive")
    func dataAppAboutPagesNotFlagged() {
        // "track landing page performance" is a data app ABOUT pages, not a website.
        #expect(!WorkspaceAppStudioScope.isLikelyOutOfScope("track landing page performance by week"))
        #expect(!WorkspaceAppStudioScope.isLikelyOutOfScope("a dashboard of website traffic metrics"))
    }

    @Test("word-boundary matching keeps catalog/log from misfiring")
    func wordBoundaryMatching() {
        // "blog" is a content token → flagged (no data verb present).
        #expect(WorkspaceAppStudioScope.isLikelyOutOfScope("a blog for the foundation"))
        // "catalog" contains the substring "log" but is matched as a whole word and is
        // a data verb, so a "product catalog website" stays in scope (it's a data app).
        #expect(!WorkspaceAppStudioScope.isLikelyOutOfScope("a product catalog website"))
    }
}
