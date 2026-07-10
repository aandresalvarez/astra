import SwiftUI
import Observation

/// Per-window owner for generic in-window transition telemetry. The generation
/// gate ensures a yielded callback from an obsolete transition cannot complete
/// a newer transition to the same destination.
@Observable @MainActor
final class ScreenTransitionCoordinator {
    private(set) var generation = 0
    private(set) var destination = "none"
    private let scope = UUID()

    func begin(destination: String, source: String, taskID: UUID?) {
        generation += 1
        self.destination = destination
        ScreenTransitionTelemetry.begin(
            destination: destination,
            source: source,
            taskID: taskID,
            scope: scope
        )
    }

    func completeIfCurrent(destination: String, generation: Int) {
        guard self.destination == destination, self.generation == generation else { return }
        ScreenTransitionTelemetry.viewBecameReady(destination: destination, scope: scope)
    }

    func cancelForViewDisappearance() {
        ScreenTransitionTelemetry.cancel(scope: scope, reason: "content_view_disappeared")
    }
}

struct ScreenTransitionReadinessObserver: ViewModifier {
    let coordinator: ScreenTransitionCoordinator

    func body(content: Content) -> some View {
        @Bindable var coordinator = coordinator
        let destination = coordinator.destination
        let generation = coordinator.generation
        content.task(id: "\(destination):\(generation)") {
            await Task.yield()
            guard !Task.isCancelled else { return }
            coordinator.completeIfCurrent(destination: destination, generation: generation)
        }
    }
}
