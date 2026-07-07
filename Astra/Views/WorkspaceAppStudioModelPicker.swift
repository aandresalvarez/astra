import SwiftUI
import ASTRACore

/// Compact provider + model picker for App Studio generation. Bound to the same
/// global default-runtime / default-model the task composer uses, so a builder can
/// route manifest generation to a working provider when the current one fails (e.g.
/// Claude returns 401) instead of being stuck on the deterministic template. Every
/// registered adapter implements one-shot utility prompts and self-resolves its
/// binary, so all registered providers are offered; the deterministic template
/// remains the graceful fallback when a chosen provider can't produce a manifest.
struct WorkspaceAppStudioModelPicker: View {
    @Binding var runtimeID: String
    @Binding var model: String
    /// Bumped when the cached model list changes, so the menu re-reads availability.
    var cacheRevision: Int

    private var runtime: AgentRuntimeID {
        AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
    }

    private var cache: RuntimeModelAvailabilityCache {
        RuntimeSettingsSnapshotStore.runtimeSnapshot().runtimeModelCache
    }

    private var runtimes: [AgentRuntimeID] {
        AgentRuntimeAdapterRegistry.runtimeIDs
    }

    private func presentation(_ candidate: String) -> RuntimeModelMenuOptionPresentation {
        RuntimeModelMenuOptionPresentation(model: candidate, runtime: runtime, cache: cache)
    }

    var body: some View {
        Menu {
            if runtimes.count > 1 {
                Menu {
                    ForEach(runtimes) { option in
                        Button {
                            runtimeID = option.rawValue
                            model = RuntimeModelAvailability.modelForRuntimeSwitch(
                                currentModel: model,
                                to: option,
                                cache: cache
                            )
                        } label: {
                            HStack {
                                Text(option.displayName)
                                if option == runtime { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Label("Provider: \(runtime.displayName)", systemImage: "cpu")
                }
            }

            let candidates = RuntimeModelAvailability.models(for: runtime, cache: cache)
            if candidates.isEmpty {
                Text("No models cached for \(runtime.displayName)")
            }
            ForEach(candidates, id: \.self) { candidate in
                Button { model = candidate } label: {
                    ModelMenuItemLabel(presentation: presentation(candidate), isSelected: model == candidate)
                }
            }
        } label: {
            Label(presentation(model).compactTitle, systemImage: "cpu")
                .font(Stanford.caption(12))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("Choose the provider and model App Studio uses to generate the app")
        // Re-evaluate the menu when the cached model list changes.
        .id(cacheRevision)
    }
}
