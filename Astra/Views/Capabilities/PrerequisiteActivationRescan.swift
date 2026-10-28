import AppKit
import SwiftUI

/// Prerequisite health reads state outside ASTRA: Docker Desktop stopping,
/// or `gh auth logout` and `gcloud auth revoke` in another Terminal, fire no
/// ASTRA event, so a mounted surface would keep its last reading. Coming back
/// to ASTRA is when such state may have changed, so the surface rescans then,
/// at most once per `minimumInterval`: a burst of focus flips runs one scan.
struct PrerequisiteActivationRescan: Equatable {
    static let minimumInterval: TimeInterval = 15

    private(set) var lastRescan: Date?

    /// Whether an activation at `now` rescans; one that does is recorded.
    mutating func shouldRescan(at now: Date) -> Bool {
        if let lastRescan, now.timeIntervalSince(lastRescan) < Self.minimumInterval { return false }
        lastRescan = now
        return true
    }
}

extension View {
    /// Runs `rescan` when ASTRA becomes active, throttled by
    /// `PrerequisiteActivationRescan`.
    func rescansPrerequisitesOnActivation(_ rescan: @escaping () -> Void) -> some View {
        modifier(PrerequisiteActivationRescanModifier(rescan: rescan))
    }
}

private struct PrerequisiteActivationRescanModifier: ViewModifier {
    let rescan: () -> Void
    @State private var throttle = PrerequisiteActivationRescan()

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if throttle.shouldRescan(at: Date()) { rescan() }
        }
    }
}
