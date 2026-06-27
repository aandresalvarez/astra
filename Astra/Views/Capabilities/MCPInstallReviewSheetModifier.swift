import SwiftUI

struct MCPInstallReviewSheetModifier: ViewModifier {
    @Binding var request: MCPInstallChatRequest?
    let workspace: Workspace?
    let onInstalled: (String) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            if let workspace {
                CapabilityMCPInstallReviewSheet(
                    request: request,
                    workspace: workspace,
                    onCancel: { self.request = nil },
                    onInstalled: { package in
                        self.request = nil
                        onInstalled(package.id)
                    }
                )
            } else {
                Text("Select a workspace first.")
                    .padding()
            }
        }
    }
}

extension View {
    func mcpInstallReviewSheet(
        request: Binding<MCPInstallChatRequest?>,
        workspace: Workspace?,
        onInstalled: @escaping (String) -> Void
    ) -> some View {
        modifier(MCPInstallReviewSheetModifier(
            request: request,
            workspace: workspace,
            onInstalled: onInstalled
        ))
    }
}
