import AppKit
import Foundation
import SwiftUI
import ASTRACore

/// NSEvent timestamps and systemUptime share the boot clock. A missing or
/// unrelated current event is unknown, never a zero-length queue delay.
struct SidebarFolderInput: Equatable {
    let handlerUptime: TimeInterval
    let eventUptime: TimeInterval?
    let source: String

    @MainActor
    static func capture() -> Self { capture(event: NSApp.currentEvent) }

    @MainActor
    static func capture(event: NSEvent?) -> Self {
        let now = ProcessInfo.processInfo.systemUptime
        switch event?.type {
        case .leftMouseDown, .leftMouseUp:
            return Self(handlerUptime: now, eventUptime: event?.timestamp, source: "pointer")
        case .keyDown, .keyUp:
            return Self(handlerUptime: now, eventUptime: event?.timestamp, source: "keyboard")
        default:
            return Self(handlerUptime: now, eventUptime: nil, source: "unavailable")
        }
    }

    var queueMilliseconds: Double? {
        guard let eventUptime, eventUptime > 0, eventUptime <= handlerUptime else { return nil }
        return (handlerUptime - eventUptime) * 1000
    }
}

struct SidebarFolderTrace {
    let id: String
    let workspaceID: UUID
    let input: SidebarFolderInput
    var expands: Bool?
    var preparationMilliseconds: Double = 0

    func fields(at uptime: TimeInterval) -> [String: String] {
        [
            "trace_id": id,
            "workspace_id": workspaceID.uuidString,
            "input_source": input.source,
            "input_queue_ms": input.queueMilliseconds.map { String(format: "%.2f", $0) } ?? "unavailable",
            "handler_to_ready_ms": String(format: "%.2f", max(0, uptime - input.handlerUptime) * 1000),
            "drawer_preparation_ms": String(format: "%.2f", preparationMilliseconds),
            "action": expands.map { $0 ? "expand" : "collapse" } ?? "pending",
            "handler_launch_age_ms": LaunchDiagnosticClock.ageMilliseconds(at: input.handlerUptime),
            "launch_age_ms": LaunchDiagnosticClock.ageMilliseconds(at: uptime),
            "pixels_displayed": "not_measured"
        ]
    }
}

/// One transient diagnostic owner per sidebar instance; no domain/UI state is
/// changed here. Every activation gets a fresh ID, independent of row counts.
@MainActor
final class SidebarFolderResponsivenessTelemetry {
    struct Ready: Equatable {
        let traceID: String
        let workspaceID: UUID
        let expanded: Bool
        let eligibleRows: Int
        let displayedRows: Int
        let appRows: Int
        let empty: Bool
    }

    private(set) var pending: SidebarFolderTrace?
    private let emit: (String, [String: String]) -> Void

    init(emit: @escaping (String, [String: String]) -> Void = {
        PerformanceTelemetry.log($0, level: .info, fields: $1)
    }) { self.emit = emit }

    func begin(workspaceID: UUID, input: SidebarFolderInput) {
        cancel(reason: "superseded", at: input.handlerUptime)
        pending = SidebarFolderTrace(id: AuditTrace.make("folder"), workspaceID: workspaceID, input: input)
        if let pending {
            var fields = pending.fields(at: input.handlerUptime)
            fields.removeValue(forKey: "handler_to_ready_ms")
            emit("sidebar_folder_handler", fields)
        }
    }

    func setTarget(expanded: Bool) { pending?.expands = expanded }

    func prepared(workspaceID: UUID, milliseconds: Double) {
        guard pending?.workspaceID == workspaceID else { return }
        pending?.preparationMilliseconds += milliseconds
    }

    func readiness(workspaceID: UUID, expanded: Bool, eligible: Int, displayed: Int,
                   apps: Int, empty: Bool) -> Ready? {
        guard let pending, pending.workspaceID == workspaceID, pending.expands == expanded else { return nil }
        return Ready(traceID: pending.id, workspaceID: workspaceID, expanded: expanded,
                     eligibleRows: eligible, displayedRows: expanded ? displayed : 0,
                     appRows: expanded ? apps : 0, empty: expanded && empty)
    }

    /// Called by the stable group's SwiftUI lifecycle callback after its row
    /// values were prepared. This is neither a compositor nor a display fence.
    func ready(_ ready: Ready?, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let ready, let trace = pending, trace.id == ready.traceID else { return }
        pending = nil
        var fields = trace.fields(at: uptime)
        fields["duration_ms"] = fields["handler_to_ready_ms"]
        fields["input_to_ready_ms"] = trace.input.queueMilliseconds.map {
            String(format: "%.2f", $0 + max(0, uptime - trace.input.handlerUptime) * 1000)
        } ?? "unavailable"
        fields["eligible_row_count"] = String(ready.eligibleRows)
        fields["displayed_row_count"] = String(ready.displayedRows)
        fields["displayed_app_count"] = String(ready.appRows)
        fields["ready_state"] = !ready.expanded ? "collapsed" : ready.empty ? "empty"
            : ready.displayedRows + ready.appRows == 0 ? "no_eligible_rows" : "rows"
        fields["readiness_basis"] = "swiftui_lifecycle"
        fields["outcome"] = "ready"
        emit("sidebar_folder_view_ready", fields)
    }

    func cancel(reason: String, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let trace = pending else { return }
        pending = nil
        var fields = trace.fields(at: uptime)
        fields["outcome"] = reason
        // An unfinished trace has elapsed handler time, not a ready duration.
        fields["handler_elapsed_ms"] = fields.removeValue(forKey: "handler_to_ready_ms")
        emit("sidebar_folder_unfinished", fields)
    }
}

/// A stable group can survive collapse/reopen with identical counts. Watching
/// the trace-bearing value (rather than counts or just onAppear) covers that
/// case, and a late callback carries the old ID so it cannot finish a new open.
struct SidebarFolderReadinessProbe: ViewModifier {
    let readiness: SidebarFolderResponsivenessTelemetry.Ready?
    let telemetry: SidebarFolderResponsivenessTelemetry

    func body(content: Content) -> some View {
        content.onChange(of: readiness, initial: true) { _, value in telemetry.ready(value) }
    }
}
