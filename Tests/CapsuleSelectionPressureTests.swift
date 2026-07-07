import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

@Suite("Capsule selection pressure")
@MainActor
struct CapsuleSelectionPressureTests {
    @Test("analyzer counts per-section eviction past the render caps")
    func analyzerCountsEviction() {
        var state = CapsuleSnapshotTests.richState() // within every cap
        #expect(!CapsuleSelectionPressure.measure(state).anyEviction)

        state.turns = (0..<7).map {
            TaskContextState.Turn(turn: $0, ask: "a", summary: "s", filesChanged: [], blockers: [],
                                  outputFile: nil, runStatus: "completed", completedAt: nil)
        }
        let pressure = CapsuleSelectionPressure.measure(state)
        #expect(pressure.anyEviction)
        #expect(pressure.evictingSections.map(\.name) == ["turns"])
        #expect(pressure.sections.first { $0.name == "turns" }?.evicted == 3) // 7 - cap 4
        #expect(pressure.totalEvicted == 3)
    }

    @Test("prompt notice surfaces eviction and stays silent under caps")
    func promptNoticeSurfacesEviction() {
        var state = CapsuleSnapshotTests.richState() // within every cap
        #expect(CapsuleSelectionPressure.promptNotice(for: state) == nil)

        state.turns = (0..<7).map {
            TaskContextState.Turn(turn: $0, ask: "a", summary: "s", filesChanged: [], blockers: [],
                                  outputFile: nil, runStatus: "completed", completedAt: nil)
        }
        let notice = CapsuleSelectionPressure.promptNotice(for: state)
        #expect(notice?.contains("Capsule eviction notice") == true)
        #expect(notice?.contains("turns (3 dropped)") == true)
    }

    /// One-shot measurement over real on-disk capsules. Renders each through the exact
    /// production prompt path and reports the budget-bind + eviction distribution.
    /// Env-gated so CI never depends on machine-local data:
    ///   ASTRA_CAPSULE_SCAN_DIR="/path/a:/path/b" swift test --filter scanRealCapsules
    @Test("scan real capsules for selection pressure")
    func scanRealCapsules() throws {
        guard let dirs = ProcessInfo.processInfo.environment["ASTRA_CAPSULE_SCAN_DIR"], !dirs.isEmpty else {
            print("CAPSULE-SCAN: skipped (set ASTRA_CAPSULE_SCAN_DIR to run)")
            return
        }
        let fileManager = FileManager.default
        var paths: [String] = []
        for root in dirs.split(separator: ":").map(String.init) {
            guard let walker = fileManager.enumerator(atPath: root) else { continue }
            for case let relative as String in walker where (relative as NSString).lastPathComponent == "current_state.json" {
                paths.append((root as NSString).appendingPathComponent(relative))
            }
        }
        guard !paths.isEmpty else { print("CAPSULE-SCAN: 0 capsules found"); return }

        // One in-memory task whose folder we overwrite per capsule, so each real state
        // renders through the unmodified promptContext path.
        let container = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let workspaceRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("capsule-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }
        let workspace = Workspace(name: "Scan", primaryPath: workspaceRoot)
        let task = AgentTask(title: "Scan", goal: "scan", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let destination = (folder as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName)

        var bound = 0, anyEvict = 0, decoded = 0
        var blockChars: [Int] = []
        var evictBySection: [String: Int] = [:]
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            try? data.write(to: URL(fileURLWithPath: destination))
            guard let block = TaskContextStateManager.promptContext(for: task) else { continue }
            decoded += 1
            blockChars.append(block.count)
            if block.contains("... (thread intent truncated)") { bound += 1 }
            if let state = TaskContextStateManager.load(taskFolder: folder) {
                let pressure = CapsuleSelectionPressure.measure(state)
                if pressure.anyEviction { anyEvict += 1 }
                for section in pressure.evictingSections { evictBySection[section.name, default: 0] += 1 }
            }
        }
        let sorted = blockChars.sorted()
        func percentile(_ quantile: Double) -> Int {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * quantile))]
        }
        print("""
        CAPSULE-SCAN found=\(paths.count) rendered=\(decoded)
          budget_bound=\(bound) (\(decoded == 0 ? 0 : 100 * bound / decoded)%)
          any_eviction=\(anyEvict) (\(decoded == 0 ? 0 : 100 * anyEvict / decoded)%)
          block_chars min/median/p90/max = \(sorted.first ?? 0)/\(percentile(0.5))/\(percentile(0.9))/\(sorted.last ?? 0)
          evicting_sections=\(evictBySection)
        """)
        #expect(decoded > 0)
    }
}
