import SwiftUI

extension GitPullRequestPublishProposal: Identifiable {
    var id: String { proposalID }
}

struct GitPullRequestPublishReviewField: Equatable, Identifiable {
    let id: String
    let label: String
    let value: String
    let isMonospaced: Bool
}

enum GitPullRequestPublishReviewPresentation {
    static func fields(for proposal: GitPullRequestPublishProposal) -> [GitPullRequestPublishReviewField] {
        [
            GitPullRequestPublishReviewField(
                id: "repository",
                label: "Repository",
                value: proposal.repositoryPath,
                isMonospaced: true
            ),
            GitPullRequestPublishReviewField(
                id: "remote-name",
                label: "Remote name",
                value: proposal.remote,
                isMonospaced: true
            ),
            GitPullRequestPublishReviewField(
                id: "remote-url",
                label: "Remote URL",
                value: proposal.remoteURL,
                isMonospaced: true
            ),
            GitPullRequestPublishReviewField(
                id: "branch",
                label: "Branch",
                value: "\(proposal.headBranch) → \(proposal.baseBranch)",
                isMonospaced: true
            ),
            GitPullRequestPublishReviewField(
                id: "starting-commit",
                label: "Starting commit",
                value: proposal.expectedHeadSHA,
                isMonospaced: true
            ),
            GitPullRequestPublishReviewField(
                id: "commit",
                label: "Commit",
                value: proposal.commitMessage,
                isMonospaced: false
            ),
            GitPullRequestPublishReviewField(
                id: "pull-request-title",
                label: "Pull request title",
                value: proposal.pullRequestTitle,
                isMonospaced: false
            ),
            GitPullRequestPublishReviewField(
                id: "pull-request-body",
                label: "Pull request body",
                value: proposal.pullRequestBody,
                isMonospaced: false
            )
        ]
    }
}

struct GitPullRequestPublishReviewSheet: View {
    let proposal: GitPullRequestPublishProposal
    let onPublish: () async throws -> GitPullRequestPublishReceipt
    let onCancel: () -> Void

    @State private var isPublishing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                    .foregroundStyle(Stanford.poppy)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review draft pull request")
                        .font(Stanford.heading(20).weight(.semibold))
                    Text("This approval applies only to proposal \(proposal.proposalID.prefix(12)). Any repository change requires a new review.")
                        .font(Stanford.body(13))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(GitPullRequestPublishReviewPresentation.fields(for: proposal)) { field in
                        labeledValue(field.label, field.value, monospaced: field.isMonospaced)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Files (\(proposal.selectedPaths.count))")
                            .font(Stanford.caption(12).weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(proposal.selectedPaths, id: \.self) { path in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "doc")
                                    .foregroundStyle(Stanford.coolGrey)
                                Text(path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
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

            HStack {
                Label("Draft pull request", systemImage: "doc.badge.ellipsis")
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .disabled(isPublishing)

                Button {
                    publish()
                } label: {
                    if isPublishing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Publish draft PR", systemImage: "arrow.up.doc.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.paloAltoGreen)
                .disabled(isPublishing)
                .accessibilityIdentifier("PublishReviewedDraftPullRequestButton")
            }
        }
        .padding(22)
        .frame(minWidth: 680, minHeight: 640)
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
