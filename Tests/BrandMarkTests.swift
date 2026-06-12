import Testing
import SwiftUI
@testable import ASTRA

@Suite("Brand marks")
struct BrandMarkTests {
    @Test("every bundled brand mark parses to a non-empty, in-bounds glyph")
    func everyMarkParsesWithinViewBox() {
        for mark in BrandMark.allCases {
            let path = mark.path
            #expect(!path.isEmpty, "\(mark) failed to parse")

            // The marks live on a 24×24 viewBox; arc conversion can overshoot a
            // hair, so allow a small tolerance rather than demanding exact bounds.
            let bounds = path.boundingRect
            #expect(bounds.minX >= -0.5 && bounds.minY >= -0.5)
            #expect(bounds.maxX <= 24.5 && bounds.maxY <= 24.5)
            // A real glyph fills a meaningful share of the box, not a stray dot.
            #expect(bounds.width >= 8 && bounds.height >= 8, "\(mark) bounds too small: \(bounds)")
        }
    }

    @Test("brand resolves from capability id and name")
    func resolvesKnownBrands() {
        #expect(BrandMark.resolve(id: "github-workflow", name: "GitHub Workflow") == .github)
        #expect(BrandMark.resolve(id: "jira-workflow", name: "Jira Agent") == .jira)
        #expect(BrandMark.resolve(id: "gcloud-workflow", name: "Google Cloud") == .googleCloud)
        #expect(BrandMark.resolve(id: "x", name: "BigQuery Analyst") == .googleCloud)
        #expect(BrandMark.resolve(id: "google-drive-browser", name: "Google Drive Browser") == .googleDrive)
        #expect(BrandMark.resolve(id: "security-auditor", name: "Security Auditor") == nil)
        #expect(BrandMark.resolve(id: "redcap-workflow", name: "REDCap Workflow") == nil)
    }

    @Test("parser rejects unsupported commands so callers can fall back")
    func parserRejectsUnsupportedCommands() {
        // Quadratic curves are not in the bundled marks and are unsupported.
        #expect(SVGPathParser.parse("M0 0 Q1 1 2 2") == nil)
        #expect(SVGPathParser.parse("") == nil)
    }

    @Test("parser handles implicit line-tos and a second decimal point")
    func parserHandlesSvgNumberQuirks() {
        // "M1 1 2 2" → move then implicit line; ".5.5" → 0.5, 0.5.
        let path = SVGPathParser.parse("M1 1 2 2L.5.5Z")
        #expect(path != nil)
        #expect(path?.isEmpty == false)
    }

    @Test("arc converts to the correct centre, radius, and sweep direction")
    func arcGeometryIsCorrect() {
        // Half-circle from (0,0) to (2,0), unit radii (centre at (1,0)). In SVG's
        // y-down space, sweep=1 is clockwise-on-screen, so a left→right chord
        // bulges UP — its midpoint is (1,-1); sweep=0 bulges DOWN to (1,1). These
        // bounds would be wrong if the centre, radius, or sweep flag were
        // mishandled, and they pin the arc to standard SVG semantics (which is
        // what the bundled marks were drawn against).
        let sweep1 = SVGPathParser.parse("M0 0A1 1 0 0 1 2 0")
        let s1 = try! #require(sweep1).boundingRect
        #expect(abs(s1.minX) < 0.05 && abs(s1.maxX - 2) < 0.05)
        #expect(s1.minY < -0.9 && s1.minY > -1.1)  // bulges up
        #expect(abs(s1.maxY) < 0.05)

        let sweep0 = SVGPathParser.parse("M0 0A1 1 0 0 0 2 0")
        let s0 = try! #require(sweep0).boundingRect
        #expect(s0.maxY > 0.9 && s0.maxY < 1.1)     // bulges down
        #expect(abs(s0.minY) < 0.05)
    }
}
