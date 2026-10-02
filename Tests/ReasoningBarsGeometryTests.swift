import CoreGraphics
import Testing
@testable import ASTRA

@Suite("Reasoning bars geometry")
struct ReasoningBarsGeometryTests {
    @Test("Bars climb evenly and a lone bar is full height")
    func heightsClimb() {
        let heights = (0..<8).map { ReasoningBarsGeometry.height(at: $0, count: 8) }
        #expect(heights.first == ReasoningBarsGeometry.minBarHeight)
        #expect(heights.last == ReasoningBarsGeometry.maxBarHeight)
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 < $1 })
        #expect(ReasoningBarsGeometry.height(at: 0, count: 1) == ReasoningBarsGeometry.maxBarHeight)
    }

    @Test("Width is bars plus the gaps between them")
    func widthCountsGaps() {
        #expect(ReasoningBarsGeometry.width(count: 0) == 0)
        #expect(ReasoningBarsGeometry.width(count: 1) == ReasoningBarsGeometry.barWidth)
        let expected: CGFloat = 8 * 9 + 7 * 3
        let actual = ReasoningBarsGeometry.width(count: 8)
        #expect(actual == expected, "width was \(actual)")
    }

    @Test("A position lands on its bar, the gap after it belongs to it, and ends clamp")
    func hitTesting() {
        #expect(ReasoningBarsGeometry.index(atX: 0, count: 8) == 0)
        #expect(ReasoningBarsGeometry.index(atX: 8.9, count: 8) == 0)
        #expect(ReasoningBarsGeometry.index(atX: 10, count: 8) == 0)
        #expect(ReasoningBarsGeometry.index(atX: 12, count: 8) == 1)
        #expect(ReasoningBarsGeometry.index(atX: 12 * 7 + 4, count: 8) == 7)
        #expect(ReasoningBarsGeometry.index(atX: -30, count: 8) == 0)
        #expect(ReasoningBarsGeometry.index(atX: 500, count: 8) == 7)
        #expect(ReasoningBarsGeometry.index(atX: 5, count: 0) == 0)
    }

    @Test("A stale hover or drag index is dropped once the levels shrink")
    func staleIndexIsDropped() {
        #expect(ReasoningBarsGeometry.valid(7, count: 8) == 7)
        #expect(ReasoningBarsGeometry.valid(7, count: 2) == nil)
        #expect(ReasoningBarsGeometry.valid(-1, count: 8) == nil)
        #expect(ReasoningBarsGeometry.valid(0, count: 0) == nil)
        #expect(ReasoningBarsGeometry.valid(nil, count: 8) == nil)
    }

    @Test("Arrow keys step one level, stop at the ends, and start from the default when nothing is selected")
    func adjustedStepsAndStarts() {
        #expect(ReasoningBarsGeometry.adjusted(from: 3, by: 1, count: 8) == 4)
        #expect(ReasoningBarsGeometry.adjusted(from: 3, by: -1, count: 8) == 2)
        #expect(ReasoningBarsGeometry.adjusted(from: 0, by: -1, count: 8) == nil)
        #expect(ReasoningBarsGeometry.adjusted(from: 7, by: 1, count: 8) == nil)
        #expect(ReasoningBarsGeometry.adjusted(from: nil, by: 1, count: 8) == 0)
        #expect(ReasoningBarsGeometry.adjusted(from: nil, by: -1, count: 8) == 0)
        #expect(ReasoningBarsGeometry.adjusted(from: nil, by: 1, count: 0) == nil)
    }
}
