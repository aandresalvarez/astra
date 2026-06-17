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
        #expect(BrandMark.resolve(id: "x", name: "Microsoft 365 Mail") == .microsoft365)
        #expect(BrandMark.resolve(id: "security-auditor", name: "Security Auditor") == nil)
        #expect(BrandMark.resolve(id: "redcap-workflow", name: "REDCap Workflow") == nil)
        // The bare "gh" alias matches only as a standalone token, never inside
        // ordinary words ending in "gh".
        #expect(BrandMark.resolve(id: "x", name: "gh — GitHub CLI") == .github)
        #expect(BrandMark.resolve(id: "x", name: "gh helper") == .github)
        #expect(BrandMark.resolve(id: "x", name: "High priority sync") == nil)
        #expect(BrandMark.resolve(id: "x", name: "Walkthrough recorder") == nil)
    }

    @Test("catalog brand icons map onto shared, parseable marks")
    func catalogBrandIconsMapOntoSharedMarks() {
        // The presentation-layer enum delegates artwork to BrandMark. Iterating
        // allCases means a future CapabilityBrandIcon case is covered here
        // automatically: its mapped mark must parse to real geometry.
        for icon in CapabilityBrandIcon.allCases {
            #expect(!icon.brandMark.path.isEmpty, "\(icon) maps to an unparseable mark")
        }
    }

    @Test("parser rejects unsupported commands so callers can fall back")
    func parserRejectsUnsupportedCommands() {
        // All standard path commands are supported; a non-command letter (here
        // "B") is genuinely unknown and must fall back to nil.
        #expect(SVGPathParser.parse("M0 0 B1 1") == nil)
        #expect(SVGPathParser.parse("") == nil)
    }

    @Test("parser handles implicit line-tos and a second decimal point")
    func parserHandlesSvgNumberQuirks() {
        // "M1 1 2 2" → move then implicit line; ".5.5" → 0.5, 0.5.
        let path = SVGPathParser.parse("M1 1 2 2L.5.5Z")
        #expect(path != nil)
        #expect(path?.isEmpty == false)
    }

    @Test("smooth-cubic S reflects only when preceded by a cubic")
    func smoothCubicReflectionRespectsPreviousCommand() {
        // C → S: the S reflects the prior control point; the run stays in bounds.
        let reflected = SVGPathParser.parse("M0 0C0 1 1 1 1 0S2 -1 2 0")
        let rb = try! #require(reflected).boundingRect
        #expect(rb.minX >= -0.01 && rb.maxX <= 2.01)

        // S NOT preceded by a cubic must use the current point as the first
        // control (no reflection), so a flat S on the axis stays on the axis.
        let flat = SVGPathParser.parse("M0 0S1 0 2 0")
        let fb = try! #require(flat).boundingRect
        #expect(abs(fb.minY) < 0.01 && abs(fb.maxY) < 0.01)
        #expect(abs(fb.maxX - 2) < 0.01)
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
