import SwiftUI

/// What the transcript shows between "the task's shell is on screen" and "its
/// first snapshot has been applied".
///
/// On a large thread that gap is 1–1.5 s (`task_open_apply_to_ready` on the
/// 2026-09-16 production profile), and it used to render as the goal bubble
/// over an empty column — indistinguishable from a thread with nothing in it.
/// The indicator waits 150 ms before appearing so a small thread, whose
/// snapshot lands within a frame or two, never flashes it.
struct TaskThreadLoadingGate<Content: View>: View {
    let isLoading: Bool
    @ViewBuilder let content: () -> Content

    @State private var showsIndicator = false

    var body: some View {
        if isLoading {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Loading conversation…")
                    .font(Stanford.chatMeta(11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .opacity(showsIndicator ? 1 : 0)
            .accessibilityLabel("Loading conversation")
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                showsIndicator = true
            }
        } else {
            content()
        }
    }
}
