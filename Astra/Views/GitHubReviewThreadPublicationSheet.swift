import SwiftUI

struct GitHubReviewThreadPublicationSheet: View {
    let proposal: GitHubReviewThreadProposal
    let onPublish: () async throws -> GitHubReviewThreadReceipt
    let onCancel: () -> Void
    let onDismiss: () throws -> Void
    @State private var isPublishing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Review GitHub thread changes").font(Stanford.heading(20))
            Text(proposal.payload.pullRequestUrl).font(Stanford.body(13)).textSelection(.enabled)
            Text("Commit \(proposal.payload.commitId)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(proposal.payload.threads.indices, id: \.self) { index in
                        let action = proposal.payload.threads[index]
                        let thread = proposal.snapshots[index]
                        VStack(alignment: .leading, spacing: 8) {
                            Text(thread.path + (thread.line.map { ":\($0)" } ?? ""))
                                .font(Stanford.body(13).weight(.semibold))
                            Text(thread.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            ForEach(thread.comments.indices, id: \.self) { commentIndex in
                                let comment = thread.comments[commentIndex]
                                Text("\(comment.author?.login ?? "Deleted account"): \(comment.body)")
                                    .font(Stanford.body(12)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let reply = action.reply {
                                Text("Reply").font(Stanford.caption(12).weight(.semibold))
                                Text(reply).font(Stanford.body(13)).textSelection(.enabled)
                            }
                            Text(action.resolve ? "Mark thread resolved" : "Keep thread open")
                                .font(Stanford.caption(12).weight(.semibold))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }.padding(12)
            }
            if let errorMessage {
                Text(errorMessage).font(Stanford.body(13)).foregroundStyle(Stanford.failed).textSelection(.enabled)
            }
            HStack {
                Text("\(proposal.payload.threads.count) threads · ASTRA sends these changes after approval")
                    .font(Stanford.caption(12)).foregroundStyle(.secondary)
                Spacer()
                Button("Not now", action: onCancel).disabled(isPublishing)
                Button("Don't send") { dismiss() }.disabled(isPublishing)
                    .accessibilityIdentifier("DismissGitHubThreadChangesButton")
                Button("Send thread changes") { publish() }
                    .buttonStyle(.borderedProminent).tint(Stanford.paloAltoGreen).disabled(isPublishing)
                    .accessibilityIdentifier("SendGitHubThreadChangesButton")
                if isPublishing { ProgressView().controlSize(.small) }
            }
        }.padding(22).frame(minWidth: 700, minHeight: 640)
    }

    private func dismiss() {
        do { try onDismiss() } catch { errorMessage = error.localizedDescription }
    }

    private func publish() {
        guard !isPublishing else { return }
        isPublishing = true; errorMessage = nil
        Task { @MainActor in
            do { _ = try await onPublish() }
            catch { errorMessage = error.localizedDescription; isPublishing = false }
        }
    }
}
