import Foundation
import Testing
@testable import ASTRA

/// The stall monitor's reports say a wedge happened but not what wedged, which
/// is why each one has cost a `sample` and a symbolication pass. These pin the
/// properties that make the published phase trustworthy enough to act on: it
/// names the *unfinished* scope, it never names a background one, and reading
/// it can never park the watchdog inside the stall it exists to report.
@Suite("Main-thread phase marker", .serialized)
struct MainThreadPhaseTests {
    @MainActor
    @Test("The innermost open scope is what a stall would name")
    func innermostScopeIsReported() {
        MainThreadPhase.resetForTesting()
        defer { MainThreadPhase.resetForTesting() }

        #expect(MainThreadPhase.snapshot() == .idle)

        MainThreadPhase.tracking("render_task_thread") {
            #expect(MainThreadPhase.snapshot() == .inside(label: "render_task_thread", depth: 1))
            MainThreadPhase.tracking("build_thread_snapshot") {
                // The scope that never returns is the innermost one, so that is
                // the one worth naming — the outer frame is still recoverable
                // from `phase_depth` being greater than one.
                #expect(MainThreadPhase.snapshot() == .inside(label: "build_thread_snapshot", depth: 2))
            }
            #expect(MainThreadPhase.snapshot() == .inside(label: "render_task_thread", depth: 1))
        }

        #expect(MainThreadPhase.snapshot() == .idle)
    }

    @MainActor
    @Test("A scope that throws still unwinds the phase")
    func throwingScopeUnwinds() {
        MainThreadPhase.resetForTesting()
        defer { MainThreadPhase.resetForTesting() }

        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try MainThreadPhase.tracking("build_thread_snapshot") { throw Failure() }
        }
        // A leaked phase outlives its scope and would be reported as the
        // culprit by the next unrelated stall.
        #expect(MainThreadPhase.snapshot() == .idle)
    }

    @Test("Background scopes never publish a phase")
    func backgroundScopesAreIgnored() async {
        await MainActor.run { MainThreadPhase.resetForTesting() }

        await Task.detached {
            MainThreadPhase.tracking("persist_provider_event") {
                // Most instrumented scopes run on both threads. A background one
                // publishing here would name a phase the main thread was never
                // in, and a stall report that points at the wrong code is worse
                // than one that admits it does not know.
                #expect(MainThreadPhase.snapshot() == .idle)
            }
        }.value

        let afterward = await MainActor.run { MainThreadPhase.snapshot() }
        #expect(afterward == .idle)
    }

    @MainActor
    @Test("Nesting past the cap drops the deepest scopes rather than growing")
    func depthIsBounded() {
        MainThreadPhase.resetForTesting()
        defer { MainThreadPhase.resetForTesting() }

        var pushed: [Bool] = []
        for index in 0..<(MainThreadPhase.maximumDepth + 4) {
            pushed.append(MainThreadPhase.push("scope_\(index)"))
        }
        #expect(pushed.prefix(MainThreadPhase.maximumDepth).allSatisfy { $0 })
        #expect(pushed.suffix(4).allSatisfy { !$0 })
        #expect(
            MainThreadPhase.snapshot()
                == .inside(label: "scope_\(MainThreadPhase.maximumDepth - 1)", depth: MainThreadPhase.maximumDepth)
        )

        // Only the accepted pushes are owed a pop; the refused ones must not
        // unwind a frame they never added.
        for _ in 0..<MainThreadPhase.maximumDepth {
            MainThreadPhase.pop()
        }
        #expect(MainThreadPhase.snapshot() == .idle)
        // Popping an empty stack is a no-op rather than an underflow.
        MainThreadPhase.pop()
        #expect(MainThreadPhase.snapshot() == .idle)
    }

    @MainActor
    @Test("A held lock is reported, not waited on")
    func snapshotNeverBlocks() {
        MainThreadPhase.resetForTesting()
        defer { MainThreadPhase.resetForTesting() }

        // The thread this contends with is the one that is, by hypothesis,
        // wedged. Waiting for it would park the watchdog inside the stall it
        // exists to report, so an unavailable lock has to come back as a fact.
        let snapshot = MainThreadPhase.withLockHeldForTesting { MainThreadPhase.snapshot() }
        #expect(snapshot == .unavailable)
        #expect(snapshot.telemetryFields["phase"] == "unavailable")
    }

    @MainActor
    @Test("Every snapshot carries a phase field a log search can filter on")
    func telemetryFieldsAreAlwaysPresent() {
        MainThreadPhase.resetForTesting()
        defer { MainThreadPhase.resetForTesting() }

        #expect(MainThreadPhase.Snapshot.idle.telemetryFields == ["phase": "none"])
        #expect(
            MainThreadPhase.Snapshot.inside(label: "render_task_thread", depth: 2).telemetryFields
                == ["phase": "render_task_thread", "phase_depth": "2"]
        )
        // `none` rather than an absent key: a stall outside every instrumented
        // scope is a real answer (SwiftUI or AppKit internals, not app code),
        // and a missing field reads as a monitor that failed to record one.
        #expect(MainThreadPhase.Snapshot.idle.telemetryFields["phase"] == "none")
    }

    @MainActor
    @Test("Measured scopes publish themselves without extra instrumentation")
    func measurePublishesThePhase() {
        MainThreadPhase.resetForTesting()
        defer { MainThreadPhase.resetForTesting() }

        var observed: MainThreadPhase.Snapshot = .idle
        PerformanceTelemetry.measure("task_open_phase", thresholdMilliseconds: .greatestFiniteMagnitude) {
            observed = MainThreadPhase.snapshot()
        }
        // The point of hooking `measure` rather than adding call sites: the
        // scopes already worth timing are the scopes worth naming, and they are
        // instrumented app-wide already.
        #expect(observed == .inside(label: "task_open_phase", depth: 1))
        #expect(MainThreadPhase.snapshot() == .idle)
    }
}
