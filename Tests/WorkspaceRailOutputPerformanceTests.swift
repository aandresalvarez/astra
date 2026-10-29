import Darwin
import Foundation
import Testing
@testable import ASTRA

@Suite("Rail output presentation cost", .serialized)
@MainActor
struct WorkspaceRailOutputPerformanceTests {
    @Test("Precomputed sort dates preserve ordering and reduce presentation CPU at 2000 files")
    func sortCost() {
        let items = (0..<2_000).map { index in
            TaskFileItem(path: "/tmp/astra-synthetic-outputs/part-\(index)/../file-\(index).md", source: "output")
        }
        let dates = Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
            (TaskHeaderFilesReader.Facts.pathIdentity(item.path), Date(timeIntervalSince1970: Double(index % 37)))
        })
        let facts = TaskHeaderFilesReader.Facts(items: items, activityDates: dates)
        var legacyPaths: [String] = []
        var outputs = WorkspaceRailSectionPresentation.OutputFacts()
        func measured(_ body: () -> Void) -> Double {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            body()
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
        }
        let before = measured {
            for _ in 0..<4 {
                // The previous body path normalized both paths for every
                // comparison, including ties, on every SwiftUI evaluation.
                legacyPaths = facts.items.sorted {
                    let left = facts.activityDates[TaskHeaderFilesReader.Facts.pathIdentity($0.path)] ?? .distantPast
                    let right = facts.activityDates[TaskHeaderFilesReader.Facts.pathIdentity($1.path)] ?? .distantPast
                    return left == right ? $0.path < $1.path : left > right
                }.map(\.path)
            }
        }
        let after = measured {
            for _ in 0..<4 { outputs = WorkspaceRailOutputPresentation.facts(from: facts) }
        }
        #expect(outputs.files.map(\.path) == legacyPaths)
        #expect(after < before * 0.75)
        print("[rail-output-sort] files=2000 repetitions=4 before_cpu_ms=\(before) after_cpu_ms=\(after)")
    }
}
