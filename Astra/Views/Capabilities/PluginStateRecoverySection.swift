import SwiftUI
import SwiftData

/// A read-only view of receipt-owned recovery. Reopening or another window's
/// completion refreshes it; the action finishes recovery without replaying input.
struct PluginStateRecoverySection: View {
    var onChanged: () -> Void
    var onError: (String) -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var items: [PluginStateRecovery.Item] = []

    var body: some View {
        ForEach(items) { item in
            HStack(alignment: .top) {
                Text(item.message)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.statusError)
                Spacer()
                Button("Finish recovery") { finish(item.id) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(Stanford.lagunita)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .capabilityCatalogPersistenceChanged)) { _ in refresh() }
    }

    private func refresh() {
        do { items = try CapabilityCatalogActionService().pendingStateRecoveries(modelContext: modelContext) }
        catch { onError("ASTRA couldn't read plugin recovery. Reopen Plugins before making another change.") }
    }

    private func finish(_ id: UUID) {
        do { try CapabilityCatalogActionService().finishStateRecovery(id, modelContext: modelContext) }
        catch { onError(error.localizedDescription) }
        refresh()
        onChanged()
    }
}
