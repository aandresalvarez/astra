import AppKit
import SwiftUI
import ASTRAModels

/// Fixed-height native rows avoid both the lazy SwiftUI accessibility trap and
/// an O(history) self-sizing pass when jumping to the end of a large archive.
/// The coordinator is only a presentation copy of the committed summary.
struct UsageDashboardTaskTable<Row: View>: NSViewRepresentable {
    let tasks: [UsageDashboardSummary.TaskRow]
    let rowHeight: CGFloat
    let row: (UsageDashboardSummary.TaskRow) -> Row
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(tasks: tasks, rowHeight: rowHeight, colorScheme: colorScheme, render: renderer)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = UsageTaskScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("usage"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.rowHeight = rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.setAccessibilityLabel("Per-task usage")
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        scroll.documentView = table
        table.reloadData()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(tasks: tasks, rowHeight: rowHeight, colorScheme: colorScheme, render: renderer)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
        coordinator.table = nil
    }

    private var renderer: (UsageDashboardSummary.TaskRow) -> AnyView {
        let makeRow = row
        let scheme = colorScheme
        return { AnyView(makeRow($0).environment(\.colorScheme, scheme)) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private var tasks: [UsageDashboardSummary.TaskRow]
        private var rowHeight: CGFloat
        private var colorScheme: ColorScheme
        private var render: (UsageDashboardSummary.TaskRow) -> AnyView
        private var reloadScheduled = false
        private let cellID = NSUserInterfaceItemIdentifier("UsageTaskCell")

        init(tasks: [UsageDashboardSummary.TaskRow], rowHeight: CGFloat, colorScheme: ColorScheme,
             render: @escaping (UsageDashboardSummary.TaskRow) -> AnyView) {
            self.tasks = tasks
            self.rowHeight = rowHeight
            self.colorScheme = colorScheme
            self.render = render
        }

        func update(tasks: [UsageDashboardSummary.TaskRow], rowHeight: CGFloat, colorScheme: ColorScheme,
                    render: @escaping (UsageDashboardSummary.TaskRow) -> AnyView) {
            self.render = render
            guard self.tasks != tasks || self.rowHeight != rowHeight || self.colorScheme != colorScheme else { return }
            self.tasks = tasks
            self.rowHeight = rowHeight
            self.colorScheme = colorScheme
            guard !reloadScheduled else { return }
            reloadScheduled = true
            // Keep Cocoa reloads outside SwiftUI's view-update transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reloadScheduled = false
                self.table?.rowHeight = self.rowHeight
                self.table?.reloadData()
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { tasks.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard tasks.indices.contains(row) else { return nil }
            let task = tasks[row]
            let cell: UsageTaskHostingCell
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? UsageTaskHostingCell {
                cell = reused
                cell.host.rootView = render(task)
            } else {
                cell = UsageTaskHostingCell(rootView: render(task))
                cell.identifier = cellID
            }
            cell.toolTip = task.title
            let budgetLabel = task.requestUsageReconciliationPending ? "request usage unconfirmed" : "latest request budget \(Int(task.budgetProgress * 100)) percent"
            cell.setAccessibilityLabel("\(task.title), \(task.status.rawValue.replacingOccurrences(of: "_", with: " ")), \(task.tokensUsed) tokens, \(String(format: "$%.2f", task.costUSD)), \(budgetLabel)")
            return cell
        }
    }
}

private final class UsageTaskHostingCell: NSTableCellView {
    let host: NSHostingView<AnyView>

    init(rootView: AnyView) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        // The table owns row geometry. Hosting must not negotiate a new
        // intrinsic height from inside an NSTableView delegate callback.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { nil }
}

private final class UsageTaskScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let table = documentView as? NSTableView, contentSize.width > 0,
              abs(table.frame.width - contentSize.width) > 0.5 else { return }
        table.setFrameSize(NSSize(width: contentSize.width, height: table.frame.height))
        table.tableColumns.first?.width = contentSize.width
    }
}
