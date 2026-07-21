import ASTRACore
import Foundation
import Testing

@Suite("Canonical JSON date bounds")
struct ASTRACanonicalJSONBoundsTests {
    /// `Double(Int64.max)` rounds up to exactly 2^63, so a date at that
    /// millisecond value passed an inclusive upper-bound guard and then
    /// trapped in the `Int64` conversion. The guard must be strict.
    @Test("A date at the unrepresentable Int64 millisecond bound throws instead of trapping")
    func upperBoundDateThrows() {
        let boundary = Date(timeIntervalSince1970: Double(Int64.max) / 1_000)
        #expect(throws: (any Error).self) {
            _ = try ASTRACanonicalJSON.encode(["date": boundary])
        }
    }

    @Test("Ordinary dates still encode canonically")
    func ordinaryDateEncodes() throws {
        let data = try ASTRACanonicalJSON.encode(["date": Date(timeIntervalSince1970: 1_700_000_000)])
        #expect(String(decoding: data, as: UTF8.self).contains("1700000000000"))
    }
}
