import SwiftUI
import SwiftData

/// What a workspace setup surface has to tell or ask the person about the
/// capabilities they selected. Derived from one creation attempt; the
/// surface holds it only while its alert is up.
enum WorkspaceCapabilityNotice: Equatable {
    /// The workspace exists; these capabilities were not added, and why.
    case enableFailures([String])
    /// Nothing was created yet. See `WorkspaceCreationOutcome.needsCredentialRecovery`.
    case needsCredentialRecovery
    /// The recovery the person asked for did not finish. Nothing was created.
    case recoveryFailed(String)

    init?(_ outcome: WorkspaceCreationOutcome) {
        switch outcome {
        case .createdWithCapabilityIssues(let failures): self = .enableFailures(failures)
        case .needsCredentialRecovery: self = .needsCredentialRecovery
        case .notCreated, .created: return nil
        }
    }

    var enableFailureMessage: String? {
        guard case .enableFailures(let failures) = self else { return nil }
        let shown = failures.prefix(3).joined(separator: "\n\n")
        let more = failures.count > 3 ? "\n\n…and \(failures.count - 3) more." : ""
        return "Your workspace was created, but these capabilities were not added:\n\n\(shown)\(more)\n\n"
            + "Add them from Manage Capabilities."
    }

    var isRecoveryPrompt: Bool {
        switch self {
        case .needsCredentialRecovery, .recoveryFailed: return true
        case .enableFailures: return false
        }
    }
}

extension View {
    /// After creation: which selected capabilities were not added, in the
    /// installer's own words. Attached where the setup surface was, since it
    /// may already be closing.
    func workspaceCapabilityEnableFailureAlert(_ notice: Binding<WorkspaceCapabilityNotice?>) -> some View {
        modifier(WorkspaceCapabilityEnableFailureAlertModifier(notice: notice))
    }

    /// Before creation: offers the explicit credential-editing recovery, then
    /// runs `retry` with the draft untouched. Attached inside the setup
    /// surface, which stays open — a window that already shows a sheet
    /// queues an alert attached behind it until that sheet closes.
    func workspaceCredentialRecoveryAlert(_ notice: Binding<WorkspaceCapabilityNotice?>, retry: @escaping () -> Void) -> some View {
        modifier(WorkspaceCredentialRecoveryAlertModifier(notice: notice, retry: retry))
    }
}

private struct WorkspaceCapabilityEnableFailureAlertModifier: ViewModifier {
    @Binding var notice: WorkspaceCapabilityNotice?

    func body(content: Content) -> some View {
        content.alert("Some capabilities couldn't be added", isPresented: Binding(
            get: { notice?.enableFailureMessage != nil },
            set: { if !$0, notice?.isRecoveryPrompt == false { notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice?.enableFailureMessage ?? "")
        }
    }
}

private struct WorkspaceCredentialRecoveryAlertModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Binding var notice: WorkspaceCapabilityNotice?
    let retry: () -> Void

    private var failure: String? {
        if case .recoveryFailed(let message) = notice { return message }
        return nil
    }

    func body(content: Content) -> some View {
        content.alert(failure == nil ? "Recover credential editing first?" : "Couldn't recover credential editing",
                      isPresented: Binding(
                        get: { notice?.isRecoveryPrompt == true },
                        set: { if !$0, notice?.isRecoveryPrompt == true { notice = nil } }
                      )) {
            if failure == nil {
                Button("Recover and Create") { recoverThenRetry() }
                Button("Back", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(failure ?? "ASTRA can't verify its account credential recovery record for this store, so it can't "
                + "add accounts for the capabilities you selected. Recovering keeps every saved secret. "
                + "Nothing has been created yet, and what you entered here is kept.")
        }
    }

    /// Deferred past the alert's own dismissal: that clears `notice`, and
    /// would take a failure, or the retry's own notice, with it.
    private func recoverThenRetry() {
        Task { @MainActor in
            do {
                try CapabilityCatalogActionService().recoverCredentialEditing(modelContext: modelContext)
                retry()
            } catch {
                notice = .recoveryFailed(error.localizedDescription)
            }
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
            String(taskQueue.hasProcessingLoop || taskQueue.isStopping),
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
