import SwiftUI

struct SidebarLayoutObserver: ViewModifier {
    let hasRightSidePanel: Bool
    let onWidthChanged: (CGFloat) -> Void
    let onRightSidePanelChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            onWidthChanged(proxy.size.width)
                            onRightSidePanelChanged(hasRightSidePanel)
                        }
                        .onChange(of: proxy.size.width) {
                            onWidthChanged(proxy.size.width)
                        }
                        .onChange(of: hasRightSidePanel) {
                            onRightSidePanelChanged(hasRightSidePanel)
                        }
                }
            }
    }
}

struct UpdateSafetyObserver: View {
    let taskQueue: TaskQueue
    let runningTaskCount: Int
    let onChange: () -> Void

    private var signature: String {
        [
            String(taskQueue.isProcessing),
            String(taskQueue.activeCount),
            String(taskQueue.activeTasks.count),
            String(runningTaskCount)
        ].joined(separator: "|")
    }

    var body: some View {
        Color.clear
            .onChange(of: signature) { onChange() }
    }
}

struct BrowserSessionPolicyObserver: ViewModifier {
    let signature: String
    let onRefresh: (String) -> Void
    let onTaskEventInserted: (DurableTaskEventInsertion) -> Void

    func body(content: Content) -> some View {
        content
            .task(id: signature) {
                onRefresh("trigger_signature")
            }
            .onReceive(NotificationCenter.default.publisher(for: .capabilityApprovalsChanged).receive(on: RunLoop.main)) { _ in
                onRefresh("capability_approvals_changed")
            }
            .onReceive(NotificationCenter.default.publisher(for: .capabilityPackagesChanged).receive(on: RunLoop.main)) { _ in
                onRefresh("capability_packages_changed")
            }
            .onReceive(NotificationCenter.default.publisher(for: .durableTaskEventInserted).receive(on: RunLoop.main)) { notification in
                guard let insertion = notification.object as? DurableTaskEventInsertion else { return }
                onTaskEventInserted(insertion)
            }
    }
}
