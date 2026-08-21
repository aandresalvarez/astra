import SwiftUI

/// The review the whole propose/commit split exists to make possible.
///
/// Shows the friendly fields *and* the exact request body, because those are two
/// different claims. The fields say what ASTRA understood the proposal to be; the
/// body is what will actually be sent. If they ever disagree, the user needs to be
/// able to see it — so the payload is shown verbatim rather than summarised.
struct ConnectorMutationReviewSheet: View {
    let proposal: ConnectorMutationProposal
    let onSend: () async throws -> ConnectorMutationReceipt
    let onDecline: () throws -> Void
    let onCancel: () -> Void

    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(proposal.fields) { field in
                        labeledValue(field.label, field.value, monospaced: field.isMonospaced)
                    }
                    requestBody
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.025))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                        )
                )
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.failed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(22)
        .frame(minWidth: 680, minHeight: 640)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "paperplane.fill")
                .font(.title2)
                .foregroundStyle(Stanford.poppy)
            VStack(alignment: .leading, spacing: 4) {
                Text("Review before ASTRA sends this")
                    .font(Stanford.heading(20).weight(.semibold))
                // Says who holds the credential, because that is the reason this
                // sheet exists rather than the agent just doing the write.
                Text("The agent composed this but could not send it — the connector "
                    + "credential stays in ASTRA. This approval covers only payload "
                    + "\(proposal.requestDigest.prefix(12)); a changed payload needs a new review.")
                    .font(Stanford.body(13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var requestBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Request body (\(proposal.byteCount) bytes)")
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(proposal.requestBodyText)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ConnectorMutationRequestBody")
        }
    }

    private var footer: some View {
        HStack {
            Label("Nothing has been sent yet", systemImage: "lock.fill")
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                onCancel()
            }
            .disabled(isSending)

            // Declining is a first-class outcome, not the absence of one. Cancel
            // leaves the proposal pending for later; this retires it.
            Button("Don't send") {
                decline()
            }
            .disabled(isSending)
            .accessibilityIdentifier("DeclineConnectorMutationButton")

            Button {
                send()
            } label: {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Send with connector", systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Stanford.paloAltoGreen)
            .disabled(isSending)
            .accessibilityIdentifier("SendReviewedConnectorMutationButton")
        }
    }

    private func labeledValue(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : Stanford.body(13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func send() {
        guard !isSending else { return }
        isSending = true
        errorMessage = nil
        Task { @MainActor in
            do {
                _ = try await onSend()
            } catch {
                // Stays open on failure. The proposal is still pending and still
                // reviewable, so closing the sheet would hide a decision the user
                // has not finished making.
                errorMessage = error.localizedDescription
                isSending = false
            }
        }
    }

    private func decline() {
        guard !isSending else { return }
        errorMessage = nil
        do {
            try onDecline()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
