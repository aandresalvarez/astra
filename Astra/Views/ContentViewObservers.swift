import SwiftUI

extension View {
    func shelfBoundaryOverlay() -> some View {
        modifier(ShelfBoundaryOverlayModifier())
    }

    /// Keeps the credential failure alert's expression graph outside ContentView.
    func workspaceCapabilityEnableFailureAlert(isPresented: Binding<Bool>) -> some View {
        modifier(WorkspaceCapabilityEnableFailureAlertModifier(isPresented: isPresented))
    }
}

private struct WorkspaceCapabilityEnableFailureAlertModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert("Some credentials couldn't be saved", isPresented: $isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your workspace was created, but one or more capability credentials could not be saved to Keychain. Add them later in Configure > Connectors.")
        }
    }
}

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

    func body(content: Content) -> some View {
        content
            .task(id: signature) {
                onRefresh("trigger_signature")
            }
            .onReceive(NotificationCenter.default.publisher(for: .capabilityApprovalsChanged)) { _ in
                onRefresh("capability_approvals_changed")
            }
    }
}
