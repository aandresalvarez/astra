import SwiftUI
import Observation

/// A single, cancellable UI intent while eligibility catches up with typing.
/// The durable turn still belongs to ExecutionRequestSubmissionService; no
/// text is cleared or provider work started until the exact request is allowed.
@MainActor
@Observable
final class ComposerSubmissionIntent {
    private(set) var signature: String?

    /// All provider-backed composer paths, including Plan, share this gate.
    func canSubmitOrWait(
        request: RuntimeEligibilityPreviewRequest,
        state: RuntimeEligibilityPreviewState,
        canExecute: Bool
    ) -> Bool {
        if canExecute {
            cancel()
            return true
        }
        requestIfUnresolved(request: request, state: state)
        return false
    }

    func requestIfUnresolved(request: RuntimeEligibilityPreviewRequest, state: RuntimeEligibilityPreviewState) {
        guard state.currentSnapshot(for: request.signature) == nil,
              !state.isUnavailable(for: request.signature) else { return }
        if signature != request.submissionSignature { signature = request.submissionSignature }
    }

    func matches(_ signature: String) -> Bool { self.signature == signature }

    func invalidate(unless signature: String) {
        if self.signature != signature { cancel() }
    }

    func cancel() {
        if signature != nil { signature = nil }
    }

    /// Consume before invoking Send so repeated Return and late evaluations
    /// cannot submit twice. A changed composer must never inherit this intent.
    func consume(
        evaluatedRequest: RuntimeEligibilityPreviewRequest,
        currentRequest: RuntimeEligibilityPreviewRequest,
        allowed: Bool
    ) -> Bool {
        // Read the live request at the owning composer: an old async pass may
        // finish before SwiftUI cancels its task after a history/readiness update.
        guard evaluatedRequest.signature == currentRequest.signature,
              matches(currentRequest.submissionSignature) else { return false }
        cancel()
        return allowed
    }
}

struct ComposerSubmissionStatus: View {
    let intent: ComposerSubmissionIntent

    var body: some View {
        if intent.signature != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing to send…")
                Button("Cancel") { intent.cancel() }
                    .buttonStyle(.plain)
            }
            .font(Stanford.caption(12))
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
        }
    }
}

extension View {
    /// Consume Return before TextField's native commit selects its contents.
    /// Shift-Return remains the composer's existing multiline editing gesture.
    func onComposerSubmit(_ action: @escaping () -> Void) -> some View {
        onSubmit(action)
            .onKeyPress(.return, phases: .down) { press in
                guard !press.modifiers.contains(.shift) else { return .ignored }
                action()
                return .handled
            }
    }
}
