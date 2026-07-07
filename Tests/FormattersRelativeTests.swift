import Testing
import Foundation
import ASTRAPersistence
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Pin the `relativeShort` formatter behavior — Kanban cards rely on
/// it for compact, scannable timestamps. Boundary tests catch off-by-one
/// regressions (e.g., a 23-hour-old task should still read "23h", not
/// jump to "1d").
@Suite("Formatters.relativeShort")
struct FormattersRelativeTests {
    /// Fixed reference instant so tests don't drift with wall-clock.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func date(secondsAgo: TimeInterval) -> Date {
        now.addingTimeInterval(-secondsAgo)
    }

    @Test("Sub-minute renders as 'now'")
    func subMinute() {
        #expect(Formatters.relativeShort(date(secondsAgo: 5),  now: now) == "now")
        #expect(Formatters.relativeShort(date(secondsAgo: 59), now: now) == "now")
    }

    @Test("Minutes render as Nm up to the hour boundary")
    func minutes() {
        #expect(Formatters.relativeShort(date(secondsAgo: 60),    now: now) == "1m")
        #expect(Formatters.relativeShort(date(secondsAgo: 600),   now: now) == "10m")
        #expect(Formatters.relativeShort(date(secondsAgo: 3_599), now: now) == "59m")
    }

    @Test("Hours render as Nh up to the day boundary")
    func hours() {
        #expect(Formatters.relativeShort(date(secondsAgo: 3_600),  now: now) == "1h")
        #expect(Formatters.relativeShort(date(secondsAgo: 82_800), now: now) == "23h")
    }

    @Test("Days render as Nd up to the week boundary")
    func days() {
        #expect(Formatters.relativeShort(date(secondsAgo: 86_400),  now: now) == "1d")
        #expect(Formatters.relativeShort(date(secondsAgo: 604_799), now: now) == "6d")
    }

    @Test("Older than a week falls back to 'MMM d' format")
    func olderThanWeek() {
        let result = Formatters.relativeShort(date(secondsAgo: 1_209_600), now: now) // ~2 weeks
        // Format is locale-dependent; we just check it isn't a day-string
        #expect(!result.hasSuffix("d"), "Should have switched to absolute date, got \(result)")
        #expect(!result.hasSuffix("h"))
        #expect(!result.hasSuffix("m"))
    }

    @Test("Older than a year includes the year")
    func olderThanYear() {
        let result = Formatters.relativeShort(date(secondsAgo: 63_072_000), now: now) // ~2 years
        // Year-bearing format includes a comma in the en_US default
        // formatter ("MMM d, yyyy") — accept either pattern by checking
        // length is > 7 chars to rule out the short MMM-d variant.
        #expect(result.count > 7, "Year not included: \(result)")
    }

    @Test("fullDate produces a long-form string")
    func fullDateLongForm() {
        let s = Formatters.fullDate(now)
        #expect(s.count > 10, "fullDate too short to be the long format")
    }
}
