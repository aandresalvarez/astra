import SwiftUI

/// Compact transcript-level control for paging older durable history. It keeps
/// loading and recovery chrome out of the already-large task detail surface.
struct TaskThreadHistoryControl: View {
    let state: TaskThreadHistoryLoadState
    let onLoad: () -> Void
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .idle:
            Button(action: onLoad) {
                Label("Load earlier messages", systemImage: "arrow.up")
                    .font(Stanford.chatMeta(11))
                    .foregroundStyle(Stanford.lagunita)
            }
            .buttonStyle(.plain)
            .help("Load the previous page of this conversation")
        case .loading:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Loading earlier messages…")
                    .font(Stanford.chatMeta(11))
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text("Earlier messages couldn’t be loaded.")
                    .font(Stanford.chatMeta(11))
                    .foregroundStyle(.secondary)
                Button("Retry", action: onRetry)
                    .buttonStyle(.link)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(message)
            }
        }
    }
}
