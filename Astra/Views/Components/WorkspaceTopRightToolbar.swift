import SwiftUI
import AppKit

struct WorkspaceTopRightActions: Equatable {
    let hasWorkspace: Bool
    let canShowPlanShelf: Bool
    let canShowTextShelf: Bool
    let canShowBrowserShelf: Bool
    let canShowQueryShelf: Bool
    let canShowAppPreviewShelf: Bool
    let activeCanvasItem: WorkspaceCanvasItem?
    let browserEngine: ShelfBrowserEngine
    let isRightRailVisible: Bool

    var isPlanShelfVisible: Bool { activeCanvasItem == .plan }
    var isTextShelfVisible: Bool { activeCanvasItem == .markdown }
    var isBrowserShelfVisible: Bool { activeCanvasItem == .browser }
    var isQueryShelfVisible: Bool { activeCanvasItem == .query }
    var isAppPreviewShelfVisible: Bool { activeCanvasItem == .appPreview }

    var hasShelfControls: Bool {
        canShowPlanShelf || canShowTextShelf || canShowQueryShelf || canShowBrowserShelf || canShowAppPreviewShelf
    }

    /// The shelf pill is the Files shelf's only dismiss affordance (that
    /// panel carries no in-panel close button), so the toolbar must render
    /// whenever any shelf control is available - even in workspace-less task
    /// contexts where the context-rail cluster hides.
    var showsToolbar: Bool {
        hasWorkspace || hasShelfControls
    }
}

struct WorkspaceTopRightToolbar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let actions: WorkspaceTopRightActions
    let onToggleBrowser: () -> Void
    let onOpenBrowserEngine: (ShelfBrowserEngine) -> Void
    let onTogglePlan: () -> Void
    let onToggleText: () -> Void
    let onToggleQuery: () -> Void
    let onToggleAppPreview: () -> Void
    let onToggleControlPanel: () -> Void

    @State private var browserMenuAnchor: NSView?

    var body: some View {
        HStack(spacing: 18) {
            AstraToolbarCommandCluster {
                shelfControls
            }
            .background(alignment: .leading) {
                shelfActiveIndicator
            }
            .frame(width: shelfClusterWidth, alignment: .trailing)
            .clipped()
            .allowsHitTesting(actions.hasShelfControls)
            .accessibilityHidden(!actions.hasShelfControls)
            .animation(commandAnimation, value: shelfClusterWidth)
            .animation(commandAnimation, value: activeShelfIndicator?.key)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Shelf controls")

            if actions.hasWorkspace {
                AstraToolbarContextCommandCluster {
                    toolbarButton(
                        title: actions.isRightRailVisible ? "Hide Workspace Context" : "Show Workspace Context",
                        systemImage: "sidebar.right",
                        isActive: actions.isRightRailVisible,
                        action: onToggleControlPanel
                    )
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(actions.isRightRailVisible ? "Hide Workspace Context (⌥⌘I)" : "Show Workspace Context (⌥⌘I)")
                    .accessibilityIdentifier("ControlPanelToolbarButton")
                }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Workspace Context")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var shelfControls: some View {
        if actions.canShowAppPreviewShelf {
            shelfToolbarButton(
                title: actions.isAppPreviewShelfVisible ? "Hide Live Preview" : "Show Live Preview",
                label: "Preview",
                systemImage: "play.rectangle",
                isActive: actions.isAppPreviewShelfVisible,
                action: onToggleAppPreview
            )
            .accessibilityLabel("Live preview shelf")
        }

        if actions.canShowPlanShelf {
            shelfToolbarButton(
                title: actions.isPlanShelfVisible ? "Hide Plan Shelf" : "Show Plan Shelf",
                label: "Plan",
                systemImage: "list.bullet.clipboard",
                isActive: actions.isPlanShelfVisible,
                action: onTogglePlan
            )
            .accessibilityLabel("Plan shelf")
        }

        if actions.canShowTextShelf {
            shelfToolbarButton(
                title: actions.isTextShelfVisible ? "Hide Files Shelf" : "Show Files Shelf",
                label: "Files",
                systemImage: "folder",
                isActive: actions.isTextShelfVisible,
                action: onToggleText
            )
            .accessibilityLabel("Files shelf")
        }

        if actions.canShowQueryShelf {
            shelfToolbarButton(
                title: actions.isQueryShelfVisible ? "Hide Query Shelf" : "Show Query Shelf",
                label: "Query",
                systemImage: "cylinder.split.1x2",
                isActive: actions.isQueryShelfVisible,
                action: onToggleQuery
            )
            .accessibilityLabel("Query shelf")
        }

        if actions.canShowBrowserShelf {
            browserMenuButton
                .accessibilityLabel("Browser shelf")
        }
    }

    private var browserMenuButton: some View {
        Button {
            presentBrowserMenu()
        } label: {
            AstraToolbarCommandLabel(
                systemImage: "globe",
                text: "Browser",
                isActive: actions.isBrowserShelfVisible,
                showsMenuIndicator: true,
                showsActiveBackground: false
            )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            ToolbarMenuAnchorView(anchor: $browserMenuAnchor)
        }
        .help("Open Browser Shelf")
        .accessibilityLabel("Browser shelf mode")
    }

    private func presentBrowserMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(
            ToolbarClosureMenuItem(
                title: "Open Embedded Browser",
                systemSymbolName: actions.browserEngine == .embedded ? "checkmark" : "globe"
            ) {
                onOpenBrowserEngine(.embedded)
            }
        )
        menu.addItem(
            ToolbarClosureMenuItem(
                title: "Open Controlled Browser",
                systemSymbolName: actions.browserEngine == .controlled ? "checkmark" : "macwindow"
            ) {
                onOpenBrowserEngine(.controlled)
            }
        )

        if actions.isBrowserShelfVisible {
            menu.addItem(.separator())
            menu.addItem(
                ToolbarClosureMenuItem(
                    title: "Hide Browser Shelf",
                    systemSymbolName: "xmark"
                ) {
                    onToggleBrowser()
                }
            )
        }

        if let browserMenuAnchor {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: browserMenuAnchor.bounds.minY - 4),
                in: browserMenuAnchor
            )
        } else if let event = NSApp.currentEvent, let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    private var shelfClusterWidth: CGFloat {
        guard !shelfControlWidths.isEmpty else { return 0 }
        return shelfControlWidths.reduce(0, +)
            + (CGFloat(shelfControlWidths.count - 1) * AstraToolbarCommandMetrics.clusterSpacing)
            + (AstraToolbarCommandMetrics.clusterHorizontalPadding * 2)
    }

    private var shelfControlWidths: [CGFloat] {
        var widths: [CGFloat] = []
        if actions.canShowAppPreviewShelf { widths.append(AstraToolbarCommandMetrics.labeledControlMinWidth) }
        if actions.canShowPlanShelf { widths.append(AstraToolbarCommandMetrics.labeledControlMinWidth) }
        if actions.canShowTextShelf { widths.append(AstraToolbarCommandMetrics.labeledControlMinWidth) }
        if actions.canShowQueryShelf { widths.append(AstraToolbarCommandMetrics.labeledControlMinWidth) }
        if actions.canShowBrowserShelf { widths.append(AstraToolbarCommandMetrics.labeledMenuControlMinWidth) }
        return widths
    }

    private var commandAnimation: Animation? {
        AstraMotion.toolbarCommand(reduceMotion: reduceMotion)
    }

    @ViewBuilder
    private var shelfActiveIndicator: some View {
        if let activeShelfIndicator {
            Capsule()
                .fill(Stanford.lagunita.opacity(AstraToolbarCommandMetrics.activeFillOpacity))
                .frame(
                    width: activeShelfIndicator.width,
                    height: AstraToolbarCommandMetrics.controlHeight
                )
                .offset(x: activeShelfIndicator.offset)
        }
    }

    private var activeShelfIndicator: ShelfActiveIndicator? {
        var offset = AstraToolbarCommandMetrics.clusterHorizontalPadding

        if actions.canShowAppPreviewShelf {
            if actions.isAppPreviewShelfVisible {
                return ShelfActiveIndicator(key: "appPreview", offset: offset, width: AstraToolbarCommandMetrics.labeledControlMinWidth)
            }
            offset += AstraToolbarCommandMetrics.labeledControlMinWidth + AstraToolbarCommandMetrics.clusterSpacing
        }

        if actions.canShowPlanShelf {
            if actions.isPlanShelfVisible {
                return ShelfActiveIndicator(key: "plan", offset: offset, width: AstraToolbarCommandMetrics.labeledControlMinWidth)
            }
            offset += AstraToolbarCommandMetrics.labeledControlMinWidth + AstraToolbarCommandMetrics.clusterSpacing
        }

        if actions.canShowTextShelf {
            if actions.isTextShelfVisible {
                return ShelfActiveIndicator(key: "files", offset: offset, width: AstraToolbarCommandMetrics.labeledControlMinWidth)
            }
            offset += AstraToolbarCommandMetrics.labeledControlMinWidth + AstraToolbarCommandMetrics.clusterSpacing
        }

        if actions.canShowQueryShelf {
            if actions.isQueryShelfVisible {
                return ShelfActiveIndicator(key: "query", offset: offset, width: AstraToolbarCommandMetrics.labeledControlMinWidth)
            }
            offset += AstraToolbarCommandMetrics.labeledControlMinWidth + AstraToolbarCommandMetrics.clusterSpacing
        }

        if actions.canShowBrowserShelf, actions.isBrowserShelfVisible {
            return ShelfActiveIndicator(key: "browser", offset: offset, width: AstraToolbarCommandMetrics.labeledMenuControlMinWidth)
        }

        return nil
    }

    private func shelfToolbarButton(
        title: String,
        label: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            AstraToolbarCommandLabel(
                systemImage: systemImage,
                text: label,
                isActive: isActive,
                showsActiveBackground: false
            )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func toolbarButton(
        title: String,
        label: String? = nil,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let label {
                AstraToolbarCommandLabel(systemImage: systemImage, text: label, isActive: isActive)
            } else {
                AstraToolbarCommandIcon(systemImage: systemImage, isActive: isActive)
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ShelfActiveIndicator: Equatable {
    let key: String
    let offset: CGFloat
    let width: CGFloat
}

private struct ToolbarMenuAnchorView: NSViewRepresentable {
    @Binding var anchor: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = ToolbarMenuAnchorNSView()
        resolve(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolve(nsView)
    }

    private func resolve(_ nsView: NSView) {
        guard anchor == nil || anchor !== nsView else { return }
        DispatchQueue.main.async {
            if anchor == nil || anchor !== nsView {
                anchor = nsView
            }
        }
    }
}

private final class ToolbarMenuAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class ToolbarClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, systemSymbolName: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performMenuAction), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performMenuAction() {
        handler()
    }
}
