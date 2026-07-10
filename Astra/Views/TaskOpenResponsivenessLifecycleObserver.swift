import SwiftUI
import ASTRAModels

/// Owns task-open telemetry work that must be cancelled with the displayed
/// task view: shell readiness, bounded main-actor probes, the stuck-open
/// watchdog, and disappearance cancellation.
struct TaskOpenResponsivenessLifecycleObserver: ViewModifier {
    let task: AgentTask
    let scope: UUID

    func body(content: Content) -> some View {
        content
            .task(id: task.id) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                TaskOpenResponsivenessTelemetry.shellBecameVisible(task: task, scope: scope)
            }
            .task(id: task.id) {
                var previousProbeAt = DispatchTime.now().uptimeNanoseconds
                while !Task.isCancelled,
                      TaskOpenResponsivenessTelemetry.isActive(task: task, scope: scope) {
                    do {
                        try await Task.sleep(nanoseconds: 16_000_000)
                    } catch {
                        return
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    TaskOpenResponsivenessTelemetry.recordMainActorProbe(
                        task: task,
                        observedIntervalMilliseconds: Double(now - previousProbeAt) / 1_000_000,
                        scope: scope
                    )
                    previousProbeAt = now
                }
            }
            .task(id: task.id) {
                do {
                    try await Task.sleep(nanoseconds: TaskOpenResponsivenessTelemetry.timeoutNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                TaskOpenResponsivenessTelemetry.timeout(task: task, scope: scope)
            }
            .onDisappear {
                TaskOpenResponsivenessTelemetry.cancel(
                    task: task,
                    reason: "task_view_disappeared",
                    scope: scope
                )
            }
    }
}
