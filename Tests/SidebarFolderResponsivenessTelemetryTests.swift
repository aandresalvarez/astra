import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ASTRA

@MainActor
@Suite("Sidebar folder responsiveness traces")
struct SidebarFolderResponsivenessTelemetryTests {
    @Test("Seven seconds queued is separate from preparing two rows; reopen with unchanged counts logs again")
    func successiveOpens() throws {
        var events: [(String, [String: String])] = []
        let telemetry = SidebarFolderResponsivenessTelemetry { events.append(($0, $1)) }
        let workspace = UUID()
        var ids: Set<String> = []
        for (index, expanded) in [true, false, true].enumerated() {
            let handler = 100.0 + Double(index) * 10
            telemetry.begin(workspaceID: workspace,
                input: .init(handlerUptime: handler, eventUptime: handler - 7, source: "pointer"))
            telemetry.setTarget(expanded: expanded)
            telemetry.prepared(workspaceID: workspace, milliseconds: 4)
            let ready = try #require(telemetry.readiness(workspaceID: workspace, expanded: expanded,
                eligible: 2, displayed: 2, apps: 0, empty: false))
            ids.insert(ready.traceID)
            telemetry.ready(ready, at: handler + 0.020)
            telemetry.ready(ready, at: handler + 1) // Repeated lifecycle callbacks are ignored.
        }
        #expect(ids.count == 3)
        #expect(events.filter { $0.0 == "sidebar_folder_handler" }.count == 3)
        let readyEvents = events.filter { $0.0 == "sidebar_folder_view_ready" }.map(\.1)
        #expect(readyEvents.count == 3)
        #expect(readyEvents.map { $0["displayed_row_count"] } == ["2", "0", "2"])
        #expect(readyEvents.map { $0["action"] } == ["expand", "collapse", "expand"])
        for fields in readyEvents {
            #expect(fields["input_queue_ms"] == "7000.00")
            #expect(fields["handler_to_ready_ms"] == "20.00")
            #expect(fields["input_to_ready_ms"] == "7020.00")
            #expect(fields["drawer_preparation_ms"] == "4.00")
            #expect(fields["eligible_row_count"] == "2")
            #expect(fields["pixels_displayed"] == "not_measured")
        }
    }

    @Test("The existing diagnostic report keeps queue and preparation endpoints in separate summaries")
    func reportSeparatesQueueFromReadiness() {
        let report = UIResponsivenessDiagnostics.makeReport(entries: [
            LogEntry(level: .info, category: "Performance",
                message: "event=sidebar_folder_handler trace_id=folder-a input_queue_ms=7000.00"),
            LogEntry(level: .info, category: "Performance",
                message: "event=sidebar_folder_view_ready trace_id=folder-a action=expand duration_ms=20.00 input_queue_ms=7000.00"),
            LogEntry(level: .info, category: "Performance",
                message: "event=sidebar_folder_handler trace_id=folder-b input_queue_ms=unavailable")
        ])
        #expect(report.eventSummaries.count == 2)
        #expect(report.eventSummaries.first { $0.event == "sidebar_folder_input_queue" }?.maxMilliseconds == 7000)
        #expect(report.eventSummaries.first { $0.event == "sidebar_folder_handler_to_view_ready:expand" }?.maxMilliseconds == 20)
        #expect(report.eventSummaries.allSatisfy { $0.sampleCount == 1 })
    }

    @Test("Keyboard, missing event timestamps, empty drawers and superseded callbacks")
    func keyboardAndSuperseded() throws {
        var events: [(String, [String: String])] = []
        let telemetry = SidebarFolderResponsivenessTelemetry { events.append(($0, $1)) }
        let workspace = UUID()
        telemetry.begin(workspaceID: workspace, input: .init(handlerUptime: 100, eventUptime: 99, source: "keyboard"))
        telemetry.setTarget(expanded: true)
        let stale = try #require(telemetry.readiness(workspaceID: workspace, expanded: true,
            eligible: 0, displayed: 0, apps: 0, empty: true))
        telemetry.begin(workspaceID: workspace, input: .init(handlerUptime: 101, eventUptime: nil, source: "unavailable"))
        telemetry.setTarget(expanded: true)
        telemetry.ready(stale, at: 101.010)
        #expect(telemetry.pending != nil)
        telemetry.ready(telemetry.readiness(workspaceID: workspace, expanded: true,
            eligible: 0, displayed: 0, apps: 0, empty: true), at: 101.020)
        #expect(events.count == 4)
        #expect(events[1].0 == "sidebar_folder_unfinished")
        #expect(events[1].1["outcome"] == "superseded")
        #expect(events[1].1["input_source"] == "keyboard")
        #expect(events[1].1["handler_to_ready_ms"] == nil)
        #expect(events.last?.1["ready_state"] == "empty")
        #expect(events.last?.1["input_queue_ms"] == "unavailable")
        #expect(SidebarFolderInput(handlerUptime: 1, eventUptime: 2, source: "keyboard").queueMilliseconds == nil)
    }

    @Test("The AppKit adapter accepts keyboard activation and rejects unrelated events")
    func eventAdapter() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime - 0.1, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49))
        let input = SidebarFolderInput.capture(event: event)
        #expect(input.source == "keyboard")
        #expect(try #require(input.queueMilliseconds) >= 100)
        #expect(SidebarFolderInput.capture(event: nil).queueMilliseconds == nil)
    }

    @Test("A stable SwiftUI group delivers readiness on two opens with identical counts")
    func lifecycleProbe() throws {
        var events: [String] = []
        let telemetry = SidebarFolderResponsivenessTelemetry { event, _ in events.append(event) }
        let workspace = UUID()
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for expanded in [true, false, true] {
            telemetry.begin(workspaceID: workspace, input: .capture(event: nil))
            telemetry.setTarget(expanded: expanded)
            let ready = telemetry.readiness(workspaceID: workspace, expanded: expanded,
                eligible: 2, displayed: 2, apps: 0, empty: false)
            host.rootView = AnyView(VStack {
                Text("Synthetic folder")
                if expanded { Text("Synthetic row 1"); Text("Synthetic row 2") }
            }.modifier(SidebarFolderReadinessProbe(readiness: ready, telemetry: telemetry)))
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        #expect(events.filter { $0 == "sidebar_folder_view_ready" }.count == 3)
    }

    @Test("Toggles coalesced before a SwiftUI update finish only the latest trace")
    func coalescedToggles() throws {
        var events: [String] = []
        let telemetry = SidebarFolderResponsivenessTelemetry { event, _ in events.append(event) }
        let driver = SyntheticFolderToggleDriver()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CoalescedFolderProbe(telemetry: telemetry, driver: driver))
        window.contentView = host
        defer { driver.activate = nil; window.contentView = nil; window.close() }
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let activate = try #require(driver.activate)
        activate()
        activate() // Back to the initial state before a view update can run.
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        #expect(events.filter { $0 == "sidebar_folder_unfinished" }.count == 1)
        #expect(events.filter { $0 == "sidebar_folder_view_ready" }.count == 1)
        #expect(telemetry.pending == nil)
    }
}

@MainActor
private final class SyntheticFolderToggleDriver {
    var activate: (() -> Void)?
}

private struct CoalescedFolderProbe: View {
    @State private var expanded = false
    let telemetry: SidebarFolderResponsivenessTelemetry
    let driver: SyntheticFolderToggleDriver
    private let workspace = UUID()

    var body: some View {
        let ready = telemetry.readiness(workspaceID: workspace, expanded: expanded,
            eligible: 2, displayed: 2, apps: 0, empty: false)
        Text(expanded ? "Synthetic rows" : "Synthetic collapsed folder")
            .modifier(SidebarFolderReadinessProbe(readiness: ready, telemetry: telemetry))
            .onAppear {
                driver.activate = {
                    telemetry.begin(workspaceID: workspace, input: .capture(event: nil))
                    telemetry.setTarget(expanded: !expanded)
                    expanded.toggle()
                }
            }
    }
}
