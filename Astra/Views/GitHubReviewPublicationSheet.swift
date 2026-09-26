import SwiftUI

struct GitHubReviewPublicationSheet: View {
    let proposal: GitHubReviewProposal
    let onPublish: () async throws -> GitHubReviewPublicationRecord
    let onCancel: () -> Void

    @State private var isPublishing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review GitHub comments")
                    .font(Stanford.heading(20).weight(.semibold))
                Text("ASTRA will post this exact review after you approve it. A changed file or PR head requires a new review.")
                    .font(Stanford.body(13))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Pull request", proposal.pullRequestURL)
                    field("Commit", proposal.payload.commitId, monospaced: true)
                    field("Review type", proposal.payload.event == "REQUEST_CHANGES" ? "Request changes" : "Comment")
                    field("Summary", proposal.payload.body.isEmpty ? "No summary" : proposal.payload.body)
                    Text("Inline comments (\(proposal.payload.comments.count))")
                        .font(Stanford.caption(12).weight(.semibold))
                    ForEach(proposal.payload.comments.indices, id: \.self) { index in
                        let comment = proposal.payload.comments[index]
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(comment.path):\(comment.line) · \(comment.side)")
                                .font(.system(size: 12, design: .monospaced).weight(.semibold))
                            Text(comment.body)
                                .font(Stanford.body(13))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if index < proposal.payload.comments.count - 1 {
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.failed)
            }

            HStack {
                Text("\(proposal.payload.comments.count) inline comments · 1 GitHub review")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isPublishing)
                Button {
                    publish()
                } label: {
                    if isPublishing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Post review", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.paloAltoGreen)
                .disabled(isPublishing)
                .accessibilityIdentifier("PostReviewedGitHubReviewButton")
            }
        }
        .padding(22)
        .frame(minWidth: 700, minHeight: 640)
    }

    private func field(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
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

    private func publish() {
        guard !isPublishing else { return }
        isPublishing = true
        errorMessage = nil
        Task { @MainActor in
            do {
                _ = try await onPublish()
            } catch {
                errorMessage = error.localizedDescription
                isPublishing = false
            }
        }
    }
}
