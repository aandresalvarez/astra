import SwiftUI
import ASTRACore

/// The one place a runtime switch can be held for a PHI acknowledgement.
///
/// Every surface that switches an existing task's runtime (the composer's
/// selector, the decision dock's "Switch to …" suggestion) asks this object
/// first, so no path reaches an unapproved provider without the alert and the
/// recorded acknowledgement. The view only installs the alert.
@MainActor
@Observable
final class RuntimeSensitiveDataSwitchPrompt {
    struct Pending {
        let request: RuntimeSensitiveDataSwitchRequest
        let confirm: () -> Void
    }

    fileprivate(set) var pending: Pending?

    /// Runs `apply` now, or holds it until the user acknowledges the risk.
    /// Returns whether the switch is waiting on the alert.
    @discardableResult
    func request(
        _ request: RuntimeSensitiveDataSwitchRequest,
        guard switchGuard: RuntimeSensitiveDataSwitchGuard?,
        isApproved: (AgentRuntimeID) -> Bool = { RuntimeProviderSettingsStore.isSensitiveDataApproved(for: $0) },
        apply: @escaping () -> Void
    ) -> Bool {
        guard let switchGuard,
              RuntimeSensitiveDataSwitchPolicy.requiresAcknowledgement(
                  from: request.previous,
                  to: request.next,
                  hasConversation: switchGuard.hasConversation(),
                  isApproved: isApproved
              ) else {
            apply()
            return false
        }
        pending = Pending(request: request) {
            switchGuard.recordAcknowledgement(request.previous, request.next, request.model)
            apply()
        }
        return true
    }

    func confirm() {
        guard let pending else { return }
        self.pending = nil
        pending.confirm()
    }

    func cancel() {
        guard let pending else { return }
        self.pending = nil
        AppLogger.breadcrumb(action: "task_sensitive_data_switch_cancelled", category: "UI", fields: [
            "runtime": pending.request.previous.rawValue,
            "declined_runtime": pending.request.next.rawValue
        ])
    }
}

extension View {
    /// Installs the acknowledgement alert for switches `prompt` holds back.
    func runtimeSensitiveDataSwitchAlert(_ prompt: RuntimeSensitiveDataSwitchPrompt) -> some View {
        modifier(RuntimeSensitiveDataSwitchAlertModifier(prompt: prompt))
    }
}

private struct RuntimeSensitiveDataSwitchAlertModifier: ViewModifier {
    let prompt: RuntimeSensitiveDataSwitchPrompt

    func body(content: Content) -> some View {
        let request = prompt.pending?.request
        content.alert(
            request.map { RuntimeSensitiveDataSwitchPolicy.alertTitle(to: $0.next) } ?? "",
            isPresented: Binding(
                get: { prompt.pending != nil },
                // Deferred: SwiftUI may clear the binding before it runs the
                // tapped button, and a pressed "Switch Anyway" must still find
                // its pending switch. Anything left after that was a dismissal.
                set: { isPresented in
                    guard !isPresented else { return }
                    DispatchQueue.main.async { prompt.cancel() }
                }
            ),
            presenting: request
        ) { request in
            Button(RuntimeSensitiveDataSwitchPolicy.confirmTitle, role: .destructive) {
                prompt.confirm()
            }
            Button(RuntimeSensitiveDataSwitchPolicy.cancelTitle(keeping: request.previous), role: .cancel) {
                prompt.cancel()
            }
        } message: { request in
            Text(RuntimeSensitiveDataSwitchPolicy.alertMessage(from: request.previous, to: request.next))
        }
    }
}
