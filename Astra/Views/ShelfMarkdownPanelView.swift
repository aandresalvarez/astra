import AppKit
import SwiftUI

struct ShelfMarkdownPanelView: View {
    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    @ObservedObject var session: ShelfMarkdownSession
    @Binding var isPresented: Bool
    @Binding var isPinnedToTask: Bool
    var workspace: Workspace?
    var task: AgentTask?
    var onOpenGeneratedFile: ((String) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewMode: ShelfTextViewMode = .preview
    @State private var isEditing = false
    @State private var wrapLines = true
    @State private var fileRoots: [WorkspaceFileRoot] = []
    @State private var fileNodes: [WorkspaceFileNode] = []
    @State private var fileIndexErrors: [WorkspaceFileIndexError] = []
    @State private var fileIndexTruncated = false
    @State private var isScanningFiles = false
    @State private var fileSearchText = ""
    @State private var expandedRootIDs: Set<String> = []
    @State private var expandedDirectoryIDs: Set<String> = []
    @State private var fileIndexTask: Task<Void, Never>?
    @State private var isFileNavigatorCollapsed = false
    @State private var fileNavigatorWidth: CGFloat = 282
    @State private var fileNavigatorResizeStartWidth: CGFloat = 282
    @State private var isResizingFileNavigator = false
    @State private var largePreviewDocumentIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if !isFileNavigatorCollapsed {
                    fileNavigator
                        .frame(width: fileNavigatorWidth)

                    FileNavigatorResizeHandle(
                        isResizing: isResizingFileNavigator,
                        onChanged: resizeFileNavigator,
                        onEnded: finishResizingFileNavigator
                    )
                }

                viewerPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(ObjectIdentifier(session))
        .onAppear {
            normalizeViewMode()
            refreshFileIndex()
        }
        .onDisappear {
            fileIndexTask?.cancel()
        }
        .onChange(of: session.selectedDocumentID) {
            isEditing = false
            normalizeViewMode()
        }
        .onChange(of: fileScopeSignature) {
            refreshFileIndex()
        }
    }

    private var toolbar: some View {
        ZStack {
            HStack(spacing: 0) {
                fileExplorerToggle
                Spacer(minLength: 0)
                toolbarActions
            }

            HStack {
                Spacer(minLength: 0)
                modePicker
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TextShelfToolbarButtonStyle())
        .frame(height: 42)
        .padding(.horizontal, 14)
        .background(.bar)
    }

    private var fileExplorerToggle: some View {
        Button {
            withAnimation(fileNavigatorAnimation) {
                isFileNavigatorCollapsed.toggle()
            }
        } label: {
            Image(systemName: "folder.fill")
                .font(Stanford.ui(16, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(TextShelfToolbarButtonStyle(isActive: !isFileNavigatorCollapsed))
        .help(isFileNavigatorCollapsed ? "Show file explorer" : "Hide file explorer")
        .accessibilityLabel(isFileNavigatorCollapsed ? "Show file explorer" : "Hide file explorer")
    }

    @ViewBuilder
    private var toolbarActions: some View {
        HStack(spacing: 6) {
            if session.canSaveSelectedDocument {
                Button {
                    if isEditing {
                        isEditing = false
                    } else {
                        allowLargePreviewForSelectedDocument()
                        viewMode = .source
                        isEditing = true
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                }
                .help(isEditing ? "Done editing" : "Edit file")
            }

            if shouldShowSaveButton {
                Button {
                    session.saveSelectedDocument()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(!session.isSelectedDocumentDirty)
                .keyboardShortcut("s", modifiers: .command)
                .help(session.isSelectedDocumentDirty ? "Save changes" : "No changes to save")
            }

            overflowMenu

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 20)
                .padding(.horizontal, 3)

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close Files shelf")
        }
    }

    private var viewerPane: some View {
        VStack(spacing: 0) {
            if !session.documents.isEmpty {
                tabStrip
                if session.hasFile {
                    Divider()
                    selectedFileBreadcrumb
                }
                Divider()
            }
            documentBody
            if session.hasFile {
                Divider()
                statusBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileNavigator: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Workspace Paths")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer(minLength: 0)

                    if isScanningFiles {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 18, height: 18)
                    }

                    Button {
                        refreshFileIndex()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(Stanford.ui(11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh workspace files")
                }

                TextField("Search files by name or path", text: $fileSearchText)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.caption(12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Stanford.cardBackground.opacity(0.45))

            Divider()

            if fileRoots.isEmpty {
                ContentUnavailableView {
                    Label("No workspace paths", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Configure a workspace folder to browse files.")
                }
                .font(Stanford.caption(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isSearchingFiles {
                            searchResultsSection
                        } else {
                            ForEach(fileRoots) { root in
                                fileRootSection(root)
                            }
                        }

                        if fileIndexTruncated {
                            Label("Showing first \(fileNodes.count) items", systemImage: "exclamationmark.triangle")
                                .font(Stanford.caption(11))
                                .foregroundStyle(Stanford.poppy)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }

                        ForEach(fileIndexErrors, id: \.self) { error in
                            Label(error.message, systemImage: "exclamationmark.triangle")
                                .font(Stanford.caption(11))
                                .foregroundStyle(Stanford.poppy)
                                .lineLimit(2)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .help(error.path)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Stanford.cardBackground.opacity(0.20))
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Search Results")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer(minLength: 0)

                Text("\(fileSearchResults.count)")
                    .font(Stanford.caption(10).weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if fileSearchResults.isEmpty {
                Text("No matches")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            } else {
                ForEach(fileSearchResults.prefix(80)) { node in
                    searchResultRow(node)
                }

                if fileSearchResults.count > 80 {
                    Text("\(fileSearchResults.count - 80) more matches")
                        .font(Stanford.caption(10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }
        }
    }

    private func fileRootSection(_ root: WorkspaceFileRoot) -> some View {
        let rootNodes = filteredNodes(for: root)
        let isExpanded = expandedRootIDs.contains(root.id)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleRoot(root)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Image(systemName: root.isDirectory ? (root.kind == .taskFolder ? "tray.full" : "folder") : "doc.text")
                        .font(Stanford.ui(12, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(root.title)
                            .font(Stanford.caption(12).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(root.path)
                            .font(Stanford.caption(10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    if !rootNodes.isEmpty {
                        Text("\(rootNodes.count)")
                            .font(Stanford.caption(10).weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(root.path, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }

                Button {
                    let url = URL(fileURLWithPath: root.path, isDirectory: root.isDirectory)
                    if root.isDirectory {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label(root.isDirectory ? "Open in Finder" : "Reveal in Finder", systemImage: "folder")
                }
            }

            if isExpanded {
                if rootNodes.isEmpty {
                    Text(fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No files" : "No matches")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 38)
                        .padding(.vertical, 7)
                } else {
                    ForEach(visibleNodes(in: rootNodes)) { node in
                        fileNodeRow(node)
                    }
                }
            }
        }
    }

    private func fileNodeRow(_ node: WorkspaceFileNode) -> some View {
        let isSelected = session.fileURL?.path == node.path
        let directoryID = directoryExpansionID(node)
        let isExpanded = expandedDirectoryIDs.contains(directoryID)

        return Button {
            if node.isDirectory {
                toggleDirectory(node)
            } else {
                openFileNode(node)
            }
        } label: {
            HStack(spacing: 7) {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else {
                    Color.clear
                        .frame(width: 12, height: 12)
                }

                Image(systemName: fileNodeIcon(node))
                    .font(Stanford.ui(12, weight: .medium))
                    .foregroundStyle(node.isDirectory ? Stanford.lagunita : fileNodeColor(node))
                    .frame(width: 16)

                Text(node.name)
                    .font(Stanford.caption(12).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Stanford.lagunita : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if !node.isDirectory {
                    let size = fileSizeLabel(node.size)
                    if !size.isEmpty {
                        Text(size)
                            .font(Stanford.caption(9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, CGFloat(node.depth) * 12 + 10)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? Stanford.lagunita.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(node.path)
        .contextMenu {
            if !node.isDirectory {
                Button {
                    openFileNode(node)
                } label: {
                    Label("Open in Files", systemImage: "doc.text")
                }
            }

            if let destination = node.destination,
               destination != .files,
               onOpenGeneratedFile != nil {
                Button {
                    onOpenGeneratedFile?(node.path)
                } label: {
                    Label(destination.title, systemImage: destination.systemImage)
                }
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.right.square")
            }
        }
    }

    private func searchResultRow(_ node: WorkspaceFileNode) -> some View {
        let isSelected = session.fileURL?.path == node.path

        return Button {
            openFileNode(node)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: fileNodeIcon(node))
                    .font(Stanford.ui(13, weight: .medium))
                    .foregroundStyle(fileNodeColor(node))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(Stanford.caption(12).weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Stanford.lagunita : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(searchResultPathLabel(for: node))
                        .font(Stanford.caption(10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                let size = fileSizeLabel(node.size)
                if !size.isEmpty {
                    Text(size)
                        .font(Stanford.caption(9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isSelected ? Stanford.lagunita.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(node.path)
        .contextMenu {
            Button {
                openFileNode(node)
            } label: {
                Label("Open in Files", systemImage: "doc.text")
            }

            if let destination = node.destination,
               destination != .files,
               onOpenGeneratedFile != nil {
                Button {
                    onOpenGeneratedFile?(node.path)
                } label: {
                    Label(destination.title, systemImage: destination.systemImage)
                }
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.right.square")
            }
        }
    }

    private var fileScopeSignature: String {
        let workspacePart = [
            workspace?.id.uuidString ?? "no-workspace",
            workspace?.primaryPath ?? "",
            workspace?.additionalPaths.joined(separator: "|") ?? ""
        ].joined(separator: "|")

        let taskPart: String
        if let task {
            taskPart = [
                task.id.uuidString,
                task.inputs.joined(separator: "|"),
                TaskWorkspaceAccess(task: task).taskFolder
            ].joined(separator: "|")
        } else {
            taskPart = "no-task"
        }

        return workspacePart + "::" + taskPart
    }

    private var normalizedFileSearchText: String {
        fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearchingFiles: Bool {
        !normalizedFileSearchText.isEmpty
    }

    private var fileSearchResults: [WorkspaceFileNode] {
        let query = normalizedFileSearchText
        guard !query.isEmpty else { return [] }

        return fileNodes.filter { node in
            guard !node.isDirectory else { return false }
            return node.name.lowercased().contains(query)
                || node.relativePath.lowercased().contains(query)
                || node.path.lowercased().contains(query)
        }
    }

    private func searchResultPathLabel(for node: WorkspaceFileNode) -> String {
        let rootTitle = fileRoots.first(where: { $0.id == node.rootID })?.title ?? "Workspace"
        let parent = node.parentRelativePath
        return parent.isEmpty ? rootTitle : "\(rootTitle) / \(parent)"
    }

    private func refreshFileIndex() {
        fileIndexTask?.cancel()

        let roots = WorkspaceFileIndexService.roots(workspace: workspace, task: task)
        fileRoots = roots
        expandedRootIDs = Set(roots.map(\.id))
        isScanningFiles = true
        fileIndexErrors = []
        fileIndexTruncated = false

        fileIndexTask = Task {
            let snapshot = await WorkspaceFileIndexService.scan(roots: roots)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                fileRoots = snapshot.roots
                fileNodes = snapshot.nodes
                fileIndexErrors = snapshot.errors
                fileIndexTruncated = snapshot.isTruncated
                isScanningFiles = false
            }
        }
    }

    private func filteredNodes(for root: WorkspaceFileRoot) -> [WorkspaceFileNode] {
        let query = normalizedFileSearchText
        return fileNodes.filter { node in
            guard node.rootID == root.id else { return false }
            guard !query.isEmpty else { return true }
            return node.name.lowercased().contains(query)
                || node.relativePath.lowercased().contains(query)
                || node.path.lowercased().contains(query)
        }
    }

    private func visibleNodes(in nodes: [WorkspaceFileNode]) -> [WorkspaceFileNode] {
        guard !isSearchingFiles else {
            return nodes
        }

        return nodes.filter { node in
            visibleByExpansion(node)
        }
    }

    private func visibleByExpansion(_ node: WorkspaceFileNode) -> Bool {
        let parts = node.relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return true }

        var current = ""
        for part in parts.dropLast() {
            current = current.isEmpty ? part : "\(current)/\(part)"
            guard expandedDirectoryIDs.contains(directoryExpansionID(rootID: node.rootID, relativePath: current)) else {
                return false
            }
        }
        return true
    }

    private func toggleRoot(_ root: WorkspaceFileRoot) {
        if expandedRootIDs.contains(root.id) {
            expandedRootIDs.remove(root.id)
        } else {
            expandedRootIDs.insert(root.id)
        }
    }

    private func toggleDirectory(_ node: WorkspaceFileNode) {
        let id = directoryExpansionID(node)
        if expandedDirectoryIDs.contains(id) {
            expandedDirectoryIDs.remove(id)
        } else {
            expandedDirectoryIDs.insert(id)
        }
    }

    private func openFileNode(_ node: WorkspaceFileNode) {
        guard !node.isDirectory else { return }
        session.load(URL(fileURLWithPath: node.path))
    }

    private func resizeFileNavigator(_ translation: CGSize) {
        if !isResizingFileNavigator {
            fileNavigatorResizeStartWidth = fileNavigatorWidth
            isResizingFileNavigator = true
        }

        fileNavigatorWidth = clampedFileNavigatorWidth(fileNavigatorResizeStartWidth + translation.width)
    }

    private func finishResizingFileNavigator() {
        fileNavigatorWidth = clampedFileNavigatorWidth(fileNavigatorWidth)
        fileNavigatorResizeStartWidth = fileNavigatorWidth
        isResizingFileNavigator = false
    }

    private func clampedFileNavigatorWidth(_ width: CGFloat) -> CGFloat {
        min(420, max(220, width))
    }

    private func directoryExpansionID(_ node: WorkspaceFileNode) -> String {
        directoryExpansionID(rootID: node.rootID, relativePath: node.relativePath)
    }

    private func directoryExpansionID(rootID: String, relativePath: String) -> String {
        "\(rootID):\(relativePath)"
    }

    private func fileNodeIcon(_ node: WorkspaceFileNode) -> String {
        if node.isDirectory {
            return "folder"
        }
        return node.destination?.systemImage ?? Formatters.fileIcon(for: node.path)
    }

    private func fileNodeColor(_ node: WorkspaceFileNode) -> Color {
        switch node.destination {
        case .browser?:
            Stanford.sky
        case .query?:
            Stanford.paloAltoGreen
        case .files?:
            Stanford.lagunita
        case nil:
            .secondary
        }
    }

    private func fileSizeLabel(_ size: Int64) -> String {
        guard size > 0 else { return "" }
        return Self.fileSizeFormatter.string(fromByteCount: size)
    }

    @ViewBuilder
    private var modePicker: some View {
        if session.selectedDocumentKind == .markdown {
            Picker("", selection: $viewMode) {
                Label("Preview", systemImage: "doc.richtext")
                    .tag(ShelfTextViewMode.preview)
                Label("Source", systemImage: "curlybraces")
                    .tag(ShelfTextViewMode.source)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 154)
            .help("Switch between rendered Markdown and source")
        } else if session.selectedDocumentKind == .json {
            Picker("", selection: $viewMode) {
                Label("Pretty", systemImage: "curlybraces")
                    .tag(ShelfTextViewMode.preview)
                Label("Source", systemImage: "doc.plaintext")
                    .tag(ShelfTextViewMode.source)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 148)
            .help("Switch between formatted JSON and source")
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(session.documents) { document in
                    textTab(document)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
        .frame(height: 40)
        .background(Stanford.cardBackground.opacity(0.55))
    }

    private func textTab(_ document: ShelfMarkdownDocument) -> some View {
        let isSelected = session.selectedDocumentID == document.id
        return HStack(spacing: 6) {
            Button {
                session.selectDocument(document.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: document.kind.systemImage)
                        .font(Stanford.ui(11, weight: .semibold))
                    Text(document.title)
                        .font(Stanford.ui(12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if document.isDirty {
                        Circle()
                            .fill(Stanford.cardinalRed)
                            .frame(width: 6, height: 6)
                            .help("Unsaved changes")
                    }
                }
                .foregroundStyle(isSelected ? Stanford.black : Stanford.coolGrey)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(document.fileURL.path)

            Button {
                session.closeDocument(document.id)
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(isSelected ? Stanford.black.opacity(0.75) : Stanford.coolGrey.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.001))
                    )
            }
            .buttonStyle(.plain)
            .help("Close \(document.title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 190, height: 34)
        .background(isSelected ? Stanford.cardBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Stanford.cardinalRed : Color.clear)
                .frame(height: 2)
        }
    }

    private var selectedFileBreadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(selectedBreadcrumbSegments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(Stanford.ui(9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }

                    breadcrumbSegmentButton(segment)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(height: 34)
        .background(Stanford.cardBackground.opacity(0.28))
        .help(session.displayPath)
    }

    private var selectedBreadcrumbSegments: [FileBreadcrumbSegment] {
        guard let fileURL = session.fileURL else { return [] }
        let filePath = fileURL.standardizedFileURL.path

        if let root = fileRoots.first(where: { WorkspaceFileIndexService.isPath(filePath, inside: $0) }) {
            if !root.isDirectory {
                return [
                    FileBreadcrumbSegment(
                        title: URL(fileURLWithPath: root.path).lastPathComponent,
                        path: root.path,
                        isFile: true
                    )
                ]
            }

            let relative = relativePath(for: filePath, rootPath: root.path)
            let rootName = URL(fileURLWithPath: root.path).lastPathComponent
            let components = relative
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)

            var path = root.path
            var segments = [FileBreadcrumbSegment(title: rootName, path: path, isFile: false)]
            for (index, component) in components.enumerated() {
                path = (path as NSString).appendingPathComponent(component)
                segments.append(FileBreadcrumbSegment(
                    title: component,
                    path: path,
                    isFile: index == components.count - 1
                ))
            }
            return segments
        }

        let pathComponents = fileURL.pathComponents.filter { $0 != "/" }
        let startIndex = max(0, pathComponents.count - 5)
        let fallback = Array(pathComponents.suffix(5))
        var path = fileURL.path.hasPrefix("/") ? "/" : ""
        for component in pathComponents.prefix(startIndex) {
            path = (path as NSString).appendingPathComponent(component)
        }
        return fallback.enumerated().map { index, title in
            path = (path as NSString).appendingPathComponent(title)
            return FileBreadcrumbSegment(title: title, path: path, isFile: index == fallback.count - 1)
        }
    }

    private func breadcrumbSegmentButton(_ segment: FileBreadcrumbSegment) -> some View {
        Button {
            revealBreadcrumbSegment(segment)
        } label: {
            HStack(spacing: 5) {
                if segment.isFile {
                    Image(systemName: session.selectedDocumentKind?.systemImage ?? "doc.text")
                        .font(Stanford.ui(11, weight: .medium))
                        .foregroundStyle(Stanford.lagunita)
                }

                Text(segment.title)
                    .font(Stanford.caption(12).weight(segment.isFile ? .semibold : .medium))
                    .foregroundStyle(segment.isFile ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(segment.path)
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Button {
                let url = URL(fileURLWithPath: segment.path)
                if segment.isFile {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(segment.isFile ? "Reveal in Finder" : "Open in Finder", systemImage: "folder")
            }
        }
    }

    private func revealBreadcrumbSegment(_ segment: FileBreadcrumbSegment) {
        withAnimation(fileNavigatorAnimation) {
            isFileNavigatorCollapsed = false
        }
        expandFileNavigator(to: segment.path, isFile: segment.isFile)
    }

    private var fileNavigatorAnimation: Animation? {
        AstraMotion.disclosure(reduceMotion: reduceMotion)
    }

    private func expandFileNavigator(to path: String, isFile: Bool) {
        let targetPath = isFile ? (path as NSString).deletingLastPathComponent : path
        guard let root = fileRoots.first(where: { WorkspaceFileIndexService.isPath(targetPath, inside: $0) }) else {
            return
        }

        expandedRootIDs.insert(root.id)
        let relative = relativePath(for: targetPath, rootPath: root.path)
        guard !relative.isEmpty else { return }

        var current = ""
        for component in relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            current = current.isEmpty ? component : "\(current)/\(component)"
            expandedDirectoryIDs.insert(directoryExpansionID(rootID: root.id, relativePath: current))
        }
    }

    private func relativePath(for path: String, rootPath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard standardizedPath.hasPrefix(standardizedRoot + "/") else {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return String(standardizedPath.dropFirst(standardizedRoot.count + 1))
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                refreshFileIndex()
            } label: {
                Label("Refresh files", systemImage: "arrow.clockwise")
            }

            Button {
                session.reload()
            } label: {
                Label("Reload current file", systemImage: "arrow.clockwise")
            }
            .disabled(!session.hasFile)

            Button {
                session.copyContentToPasteboard()
            } label: {
                Label(copyMenuTitle, systemImage: "doc.on.doc")
            }
            .disabled(!session.hasFile)

            Button {
                session.openExternal()
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.forward.square")
            }
            .disabled(!session.hasFile)

            Button {
                session.revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!session.hasFile)

            Divider()

            Toggle(isOn: $wrapLines) {
                Label("Wrap lines", systemImage: wrapLines ? "text.word.spacing" : "text.alignleft")
            }

            Toggle(isOn: $isPinnedToTask) {
                Label(
                    "Pin to task",
                    systemImage: isPinnedToTask ? "pin.fill" : "pin"
                )
            }

            Divider()

            Button {
                session.closeSelectedDocument()
            } label: {
                Label("Close current file", systemImage: "xmark")
            }
            .disabled(!session.hasFile)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .help("Files shelf options")
    }

    private var shouldShowSaveButton: Bool {
        session.canSaveSelectedDocument && (isEditing || session.isSelectedDocumentDirty)
    }

    private var copyMenuTitle: String {
        if session.selectedDocument?.kind.isTextBacked == true {
            "Copy Contents"
        } else {
            "Copy Path"
        }
    }

    @ViewBuilder
    private var documentBody: some View {
        if let errorMessage = session.errorMessage {
            fileUnavailableView(errorMessage)
        } else if !session.hasFile {
            ContentUnavailableView {
                Label("No file selected", systemImage: "doc.text")
            } description: {
                Text("Choose a file from the workspace paths to preview it here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = session.selectedDocument, shouldGateLargePreview(document) {
            largeFileOverview(document)
        } else if let document = session.selectedDocument, document.kind == .image {
            imagePreviewBody(document)
        } else if let document = session.selectedDocument, document.kind == .unsupported {
            unsupportedFileOverview(document)
        } else if effectiveViewMode == .preview, session.selectedDocumentKind == .markdown {
            if session.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("Empty Markdown file", systemImage: "doc.richtext")
                } description: {
                    Text("Switch to Source to edit this file.")
                } actions: {
                    Button("Edit Source") {
                        viewMode = .source
                        isEditing = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SelectableMarkdownDocumentView(
                    text: session.content,
                    signature: session.contentSignature
                )
                .background(Stanford.cardBackground.opacity(0.45))
            }
        } else if effectiveViewMode == .preview, session.selectedDocumentKind == .json {
            jsonPreviewBody
        } else if isEditing {
            ShelfTextEditorView(
                text: Binding(
                    get: { session.content },
                    set: { session.updateSelectedContent($0) }
                ),
                isEditable: true,
                wrapLines: wrapLines
            )
            .background(Stanford.cardBackground.opacity(0.45))
        } else {
            ShelfSyntaxHighlightedTextView(
                text: session.content,
                language: selectedSyntaxLanguage,
                wrapLines: wrapLines,
                signature: session.contentSignature
            )
            .background(Stanford.cardBackground.opacity(0.45))
        }
    }

    private func fileUnavailableView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("File unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            HStack(spacing: 10) {
                Button {
                    session.reload()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }

                Button {
                    session.openExternal()
                } label: {
                    Label("Open External", systemImage: "arrow.up.forward.square")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func imagePreviewBody(_ document: ShelfMarkdownDocument) -> some View {
        if let image = NSImage(contentsOf: document.fileURL) {
            GeometryReader { proxy in
                ZStack {
                    Stanford.cardBackground.opacity(0.45)

                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFit()
                            .frame(
                                maxWidth: max(proxy.size.width - 48, 120),
                                maxHeight: max(proxy.size.height - 48, 120)
                            )
                            .padding(24)
                    }
                }
            }
        } else {
            unsupportedFileOverview(
                document,
                title: "Image preview unavailable",
                message: "Open this file in its default app to inspect it."
            )
        }
    }

    private func unsupportedFileOverview(
        _ document: ShelfMarkdownDocument,
        title: String = "No inline preview",
        message: String = "This file type can be opened in its default app."
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: document.kind.systemImage)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tertiary)

            VStack(spacing: 5) {
                Text(title)
                    .font(Stanford.ui(20, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(document.title)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(document.fileURL.path)

                Text(message)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                fileFactRow("Type", value: document.kind.displayName, systemImage: document.kind.systemImage)
                fileFactRow("Size", value: fileSizeLabel(document.fileByteSize), systemImage: "externaldrive")
                if let imageSize = document.imageSize {
                    fileFactRow("Dimensions", value: imageSizeLabel(imageSize), systemImage: "aspectratio")
                }
                if let modifiedAt = document.modifiedAt {
                    fileFactRow("Modified", value: modifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                }
                fileFactRow("Path", value: document.fileURL.path, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            }
            .frame(width: 360, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    session.openExternal()
                } label: {
                    Label("Open External", systemImage: "arrow.up.forward.square")
                }

                Button {
                    session.revealInFinder()
                } label: {
                    Label("Reveal", systemImage: "folder")
                }

                Button {
                    copyPathToPasteboard(document.fileURL.path)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            }
            .controlSize(.small)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Stanford.cardBackground.opacity(0.45))
    }

    private func largeFileOverview(_ document: ShelfMarkdownDocument) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tertiary)

            VStack(spacing: 5) {
                Text("Large file")
                    .font(Stanford.ui(20, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(document.title)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(document.fileURL.path)
            }

            VStack(alignment: .leading, spacing: 8) {
                fileFactRow("Type", value: document.kind.displayName, systemImage: document.kind.systemImage)
                fileFactRow("Size", value: fileSizeLabel(document.fileByteSize), systemImage: "externaldrive")
                fileFactRow("Lines", value: "\(lineCount)", systemImage: "text.alignleft")
                if let modifiedAt = document.modifiedAt {
                    fileFactRow("Modified", value: modifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                }
            }
            .frame(width: 320, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    allowLargePreview(document)
                    if document.kind == .json {
                        viewMode = .preview
                    }
                } label: {
                    Label(document.kind == .json ? "Open Pretty Preview" : "Preview Anyway", systemImage: "doc.text")
                }

                Button {
                    allowLargePreview(document)
                    viewMode = .source
                    isEditing = false
                } label: {
                    Label("Open Source", systemImage: "doc.plaintext")
                }

                Button {
                    session.openExternal()
                } label: {
                    Label("Open External", systemImage: "arrow.up.forward.square")
                }
            }
            .controlSize(.small)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Stanford.cardBackground.opacity(0.45))
    }

    private func fileFactRow(_ title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(Stanford.ui(11, weight: .medium))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 15)

            Text(title)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)

            Text(value.isEmpty ? "0 bytes" : value)
                .font(Stanford.caption(11))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var jsonPreviewBody: some View {
        if let document = session.selectedDocument,
           let errorMessage = document.jsonErrorMessage {
            ContentUnavailableView {
                Label("Invalid JSON", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Open Source") {
                    viewMode = .source
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Stanford.cardBackground.opacity(0.45))
        } else {
            ShelfSyntaxHighlightedTextView(
                text: session.selectedDocument?.formattedJSONContent ?? session.content,
                language: .json,
                wrapLines: wrapLines,
                signature: "\(session.contentSignature)|pretty-json"
            )
            .background(Stanford.cardBackground.opacity(0.45))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let document = session.selectedDocument {
                Label(document.kind.displayName, systemImage: document.kind.systemImage)
                if !fileSizeLabel(document.fileByteSize).isEmpty {
                    Text(fileSizeLabel(document.fileByteSize))
                }
                if let imageSize = document.imageSize {
                    Text(imageSizeLabel(imageSize))
                }
                if document.kind.isTextBacked, document.errorMessage == nil {
                    Text("\(lineCount) \(lineCount == 1 ? "line" : "lines")")
                    Text("\(session.content.count) characters")
                }
                if shouldGateLargePreview(document) {
                    Label("Large preview paused", systemImage: "pause.circle")
                        .foregroundStyle(Stanford.poppy)
                }
                if document.isDirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .foregroundStyle(Stanford.cardinalRed)
                }
                if let saveErrorMessage = session.saveErrorMessage {
                    Label(saveErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Stanford.poppy)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Label(isEditing ? "Editing" : "Read-only", systemImage: isEditing ? "pencil" : "lock")
            }
        }
        .font(Stanford.caption(11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Stanford.cardBackground.opacity(0.65))
    }

    private var effectiveViewMode: ShelfTextViewMode {
        guard session.selectedDocumentKind == .markdown || session.selectedDocumentKind == .json else { return .source }
        return viewMode
    }

    private var lineCount: Int {
        guard !session.content.isEmpty else { return 0 }
        return session.content.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var selectedSyntaxLanguage: ShelfSyntaxLanguage {
        guard let document = session.selectedDocument else { return .plaintext }
        return ShelfSyntaxLanguage.infer(from: document.fileURL, kind: document.kind)
    }

    private func normalizeViewMode() {
        if session.selectedDocumentKind == .markdown || session.selectedDocumentKind == .json {
            if !isEditing {
                viewMode = .preview
            }
        } else {
            viewMode = .source
        }
    }

    private func shouldGateLargePreview(_ document: ShelfMarkdownDocument) -> Bool {
        document.isLargePreview
            && !document.isDirty
            && !largePreviewDocumentIDs.contains(document.id)
    }

    private func allowLargePreviewForSelectedDocument() {
        guard let document = session.selectedDocument else { return }
        allowLargePreview(document)
    }

    private func allowLargePreview(_ document: ShelfMarkdownDocument) {
        largePreviewDocumentIDs.insert(document.id)
    }

    private func imageSizeLabel(_ size: CGSize) -> String {
        "\(Int(size.width)) x \(Int(size.height))"
    }

    private func copyPathToPasteboard(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

private enum ShelfTextViewMode: String, Hashable {
    case preview
    case source
}

private struct FileBreadcrumbSegment: Hashable {
    let title: String
    let path: String
    let isFile: Bool
}

enum ShelfSyntaxLanguage: Hashable {
    case json
    case swift
    case javascript
    case typescript
    case html
    case css
    case python
    case shell
    case sql
    case yaml
    case markdown
    case plaintext

    static func infer(from url: URL, kind: ShelfTextDocumentKind) -> ShelfSyntaxLanguage {
        switch kind {
        case .json:
            return .json
        case .markdown:
            return .markdown
        case .image, .unsupported:
            return .plaintext
        case .text:
            break
        }

        switch url.pathExtension.lowercased() {
        case "swift":
            return .swift
        case "js", "jsx", "mjs", "cjs":
            return .javascript
        case "ts", "tsx":
            return .typescript
        case "html", "htm", "xml", "svg":
            return .html
        case "css", "scss", "sass", "less":
            return .css
        case "py", "pyw":
            return .python
        case "sh", "bash", "zsh", "fish", "command":
            return .shell
        case "sql":
            return .sql
        case "yml", "yaml", "toml":
            return .yaml
        case "md", "markdown", "qmd":
            return .markdown
        default:
            let name = url.lastPathComponent.lowercased()
            if ["dockerfile", "makefile", "rakefile", "gemfile"].contains(name) {
                return .shell
            }
            return .plaintext
        }
    }
}

private struct ShelfSyntaxHighlightedTextView: NSViewRepresentable {
    let text: String
    let language: ShelfSyntaxLanguage
    let wrapLines: Bool
    let signature: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.backgroundColor = .clear

        scrollView.documentView = textView
        context.coordinator.textView = textView
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        configureWrapping(for: textView, in: scrollView)

        let nextSignature = "\(signature)|\(language)|wrap:\(wrapLines)"
        guard context.coordinator.lastSignature != nextSignature else { return }
        context.coordinator.lastSignature = nextSignature
        textView.textStorage?.setAttributedString(ShelfSyntaxHighlighter.attributedString(
            for: text,
            language: language
        ))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func configureWrapping(for textView: NSTextView, in scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = !wrapLines
        textView.isHorizontallyResizable = !wrapLines
        textView.autoresizingMask = wrapLines ? [.width] : [.width, .height]
        textView.textContainer?.widthTracksTextView = wrapLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapLines ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastSignature = ""
    }
}

enum ShelfSyntaxHighlighter {
    static let maxHighlightedUTF8Bytes = 256 * 1_024

    static func attributedString(for text: String, language: ShelfSyntaxLanguage) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: baseAttributes
        )
        guard !text.isEmpty else { return attributed }
        // Avoid running regex highlighters over large files during SwiftUI view updates.
        guard text.utf8.count <= maxHighlightedUTF8Bytes else { return attributed }

        switch language {
        case .json:
            highlightJSON(in: attributed, text: text)
        case .swift:
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "actor", "as", "associatedtype", "async", "await", "break", "case", "catch",
                    "class", "continue", "default", "defer", "do", "else", "enum", "extension",
                    "false", "for", "func", "guard", "if", "import", "in", "init", "let", "nil",
                    "private", "protocol", "public", "return", "self", "static", "struct",
                    "switch", "throw", "throws", "true", "try", "var", "where", "while"
                ],
                lineCommentPattern: #"//[^\n\r]*"#,
                blockCommentPattern: #"/\*[\s\S]*?\*/"#
            )
        case .javascript, .typescript:
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "async", "await", "break", "case", "catch", "class", "const", "continue",
                    "default", "delete", "else", "export", "extends", "false", "finally",
                    "for", "from", "function", "if", "import", "in", "instanceof", "interface",
                    "let", "new", "null", "return", "switch", "this", "throw", "true", "try",
                    "type", "typeof", "undefined", "var", "void", "while", "yield"
                ],
                lineCommentPattern: #"//[^\n\r]*"#,
                blockCommentPattern: #"/\*[\s\S]*?\*/"#
            )
        case .html:
            apply(pattern: #"<!--[\s\S]*?-->"#, color: .secondaryLabelColor, to: attributed, options: [.dotMatchesLineSeparators])
            apply(pattern: #"</?[A-Za-z][^>\s/]*"#, color: .systemBlue, to: attributed)
            apply(pattern: #"\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\=)"#, color: .systemPurple, to: attributed)
            highlightStrings(in: attributed)
        case .css:
            apply(pattern: #"#[0-9A-Fa-f]{3,8}\b"#, color: .systemPink, to: attributed)
            apply(pattern: #"\b-?\d+(?:\.\d+)?(?:px|rem|em|vh|vw|%|s|ms)?\b"#, color: .systemOrange, to: attributed)
            highlightCode(
                in: attributed,
                text: text,
                keywords: ["important", "media", "supports", "keyframes", "from", "to"],
                lineCommentPattern: nil,
                blockCommentPattern: #"/\*[\s\S]*?\*/"#
            )
        case .python:
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "and", "as", "assert", "async", "await", "break", "class", "continue",
                    "def", "del", "elif", "else", "except", "False", "finally", "for", "from",
                    "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not",
                    "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"
                ],
                lineCommentPattern: "#[^\\n\\r]*",
                blockCommentPattern: nil
            )
        case .shell:
            apply(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*"#, color: .systemPurple, to: attributed)
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "case", "cd", "done", "do", "elif", "else", "esac", "fi", "for", "function",
                    "if", "in", "then", "while"
                ],
                lineCommentPattern: "#[^\\n\\r]*",
                blockCommentPattern: nil
            )
        case .sql:
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "ALTER", "AND", "AS", "BETWEEN", "BY", "CASE", "CREATE", "DELETE", "DROP",
                    "ELSE", "END", "FROM", "GROUP", "HAVING", "IN", "INSERT", "INTO", "IS",
                    "JOIN", "LEFT", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "OUTER",
                    "RIGHT", "SELECT", "SET", "TABLE", "THEN", "UNION", "UPDATE", "VALUES",
                    "WHEN", "WHERE", "WITH"
                ],
                lineCommentPattern: #"--[^\n\r]*"#,
                blockCommentPattern: #"/\*[\s\S]*?\*/"#
            )
        case .yaml:
            apply(pattern: "#[^\\n\\r]*", color: .secondaryLabelColor, to: attributed, options: [.anchorsMatchLines])
            apply(pattern: #"^\s*[-A-Za-z0-9_.]+(?=\s*:)"#, color: .systemBlue, to: attributed, options: [.anchorsMatchLines])
            apply(pattern: #"\b(true|false|null|yes|no|on|off)\b"#, color: .systemPurple, to: attributed, options: [.caseInsensitive])
            apply(pattern: #"\b-?\d+(?:\.\d+)?\b"#, color: .systemOrange, to: attributed)
            highlightStrings(in: attributed)
        case .markdown:
            apply(pattern: #"^#{1,6}\s+.*$"#, color: .systemBlue, to: attributed, options: [.anchorsMatchLines])
            apply(pattern: #"`[^`\n]+`"#, color: .systemOrange, to: attributed)
            apply(pattern: #"```[\s\S]*?```"#, color: .systemGreen, to: attributed, options: [.dotMatchesLineSeparators])
            apply(pattern: #"\*\*[^*\n]+\*\*"#, color: .systemPurple, to: attributed)
            apply(pattern: #"^\s*[-*+]\s+"#, color: .systemBlue, to: attributed, options: [.anchorsMatchLines])
        case .plaintext:
            break
        }

        return attributed
    }

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private static func highlightJSON(in attributed: NSMutableAttributedString, text: String) {
        apply(pattern: #"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemOrange, to: attributed)
        apply(pattern: #"\b(true|false|null)\b"#, color: .systemPurple, to: attributed)
        apply(pattern: #""(?:\\.|[^"\\])*""#, color: .systemGreen, to: attributed)
        apply(pattern: #""(?:\\.|[^"\\])*"(?=\s*:)"#, color: .systemBlue, to: attributed)
    }

    private static func highlightCode(
        in attributed: NSMutableAttributedString,
        text: String,
        keywords: [String],
        lineCommentPattern: String?,
        blockCommentPattern: String?
    ) {
        apply(pattern: #"\b-?\d+(?:\.\d+)?\b"#, color: .systemOrange, to: attributed)
        applyKeywords(keywords, color: .systemBlue, to: attributed)
        let stringRanges = highlightStrings(in: attributed)
        if let blockCommentPattern {
            apply(
                pattern: blockCommentPattern,
                color: .secondaryLabelColor,
                to: attributed,
                options: [.dotMatchesLineSeparators],
                excludingMatchStartsIn: stringRanges
            )
        }
        if let lineCommentPattern {
            apply(
                pattern: lineCommentPattern,
                color: .secondaryLabelColor,
                to: attributed,
                options: [.anchorsMatchLines],
                excludingMatchStartsIn: stringRanges
            )
        }
    }

    @discardableResult
    private static func highlightStrings(in attributed: NSMutableAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        ranges += apply(pattern: #""(?:\\.|[^"\\])*""#, color: .systemGreen, to: attributed)
        ranges += apply(pattern: #"'(?:\\.|[^'\\])*'"#, color: .systemGreen, to: attributed)
        return ranges
    }

    private static func applyKeywords(
        _ keywords: [String],
        color: NSColor,
        to attributed: NSMutableAttributedString
    ) {
        let pattern = "\\b(\(keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")))\\b"
        apply(pattern: pattern, color: color, to: attributed, options: [.caseInsensitive])
    }

    @discardableResult
    private static func apply(
        pattern: String,
        color: NSColor,
        to attributed: NSMutableAttributedString,
        options: NSRegularExpression.Options = [],
        excludingMatchStartsIn excludedRanges: [NSRange] = []
    ) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        var appliedRanges: [NSRange] = []
        let range = NSRange(location: 0, length: attributed.length)
        regex.enumerateMatches(in: attributed.string, range: range) { match, _, _ in
            guard let matchRange = match?.range, matchRange.location != NSNotFound else { return }
            let startsInExcludedRange = excludedRanges.contains { excludedRange in
                NSLocationInRange(matchRange.location, excludedRange)
            }
            guard !startsInExcludedRange else { return }
            attributed.addAttribute(.foregroundColor, value: color, range: matchRange)
            appliedRanges.append(matchRange)
        }
        return appliedRanges
    }
}

private struct TextShelfToolbarButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Stanford.ui(13, weight: .semibold))
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        if isActive {
            return Stanford.lagunita.opacity(isPressed ? 0.72 : 1)
        }
        return Color.primary.opacity(isPressed ? 0.55 : 0.82)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return isActive ? Stanford.lagunita.opacity(0.16) : Color.primary.opacity(0.12)
        }
        return isActive ? Stanford.lagunita.opacity(0.10) : Color.clear
    }

    private var strokeColor: Color {
        isActive ? Stanford.lagunita.opacity(0.24) : Color.clear
    }
}

private struct FileNavigatorResizeHandle: View {
    let isResizing: Bool
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 1)
                .allowsHitTesting(false)

            Rectangle()
                .fill(Stanford.lagunita.opacity(indicatorOpacity))
                .frame(width: 2)
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.clear)
                .frame(width: 12)
                .contentShape(Rectangle())
                .background(FileNavigatorCursorRectView(cursor: .resizeLeftRight))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in onChanged(value.translation) }
                        .onEnded { _ in onEnded() }
                )
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isResizing)
        .help("Resize file explorer")
    }

    private var indicatorOpacity: Double {
        if isResizing { return 0.55 }
        if isHovered { return 0.30 }
        return 0
    }
}

private struct FileNavigatorCursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView {
        FileNavigatorCursorRectNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? FileNavigatorCursorRectNSView else { return }
        if view.cursor !== cursor {
            view.cursor = cursor
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

private final class FileNavigatorCursorRectNSView: NSView {
    var cursor: NSCursor

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ShelfTextEditorView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let wrapLines: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        scrollView.documentView = textView
        context.coordinator.textView = textView
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        context.coordinator.text = $text
        context.coordinator.isApplyingExternalChange = true
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            context.coordinator.clearUndoActions()
            textView.string = text
            context.coordinator.clearUndoActions()
            textView.setSelectedRange(NSRange(
                location: min(selectedRange.location, (text as NSString).length),
                length: 0
            ))
        }

        textView.isEditable = isEditable
        textView.allowsUndo = isEditable
        if !isEditable {
            context.coordinator.clearUndoActions()
        }
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        configureWrapping(for: textView, in: scrollView)
        context.coordinator.isApplyingExternalChange = false
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
        scrollView.documentView = nil
    }

    private func configureWrapping(for textView: NSTextView, in scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = !wrapLines
        textView.isHorizontallyResizable = !wrapLines
        textView.autoresizingMask = wrapLines ? [.width] : [.width, .height]
        textView.textContainer?.widthTracksTextView = wrapLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapLines ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var isApplyingExternalChange = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalChange,
                  let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }

        func clearUndoActions() {
            guard let textView else { return }
            textView.undoManager?.removeAllActions(withTarget: textView)
        }

        func detach() {
            guard let textView else { return }
            clearUndoActions()
            textView.delegate = nil
            textView.allowsUndo = false
            self.textView = nil
        }
    }
}

private struct SelectableMarkdownDocumentView: NSViewRepresentable {
    let text: String
    let signature: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.lastSignature != signature,
              let textView = context.coordinator.textView else {
            return
        }

        context.coordinator.lastSignature = signature
        textView.textStorage?.setAttributedString(MarkdownShelfTextRenderer.attributedString(for: text))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastSignature = ""
    }
}

private enum MarkdownShelfTextRenderer {
    static func attributedString(for text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = MarkdownTextView.parse(text)

        for block in blocks {
            switch block.kind {
            case .heading(let level):
                let size: CGFloat = level == 1 ? 28 : level == 2 ? 22 : 18
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .systemFont(ofSize: size, weight: .bold),
                    color: .labelColor,
                    lineSpacing: 4,
                    paragraphSpacing: 12
                )
            case .listItem(let depth, let marker):
                let indent = String(repeating: "    ", count: depth)
                append(
                    "\(indent)\(marker) \(block.content)\n",
                    to: result,
                    font: .systemFont(ofSize: 15),
                    color: .labelColor,
                    lineSpacing: 5,
                    paragraphSpacing: 6
                )
            case .codeBlock:
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    color: .labelColor,
                    lineSpacing: 3,
                    paragraphSpacing: 10,
                    background: NSColor.textBackgroundColor.withAlphaComponent(0.22)
                )
            case .table:
                let tableText = MarkdownTextView.monospacedTableText(block.content)
                append(
                    tableText + "\n\n",
                    to: result,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    color: .labelColor,
                    lineSpacing: 4,
                    paragraphSpacing: 10
                )
            case .blockquote:
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .systemFont(ofSize: 15).withTraits(.italicFontMask),
                    color: .secondaryLabelColor,
                    lineSpacing: 5,
                    paragraphSpacing: 10
                )
            case .notice:
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .systemFont(ofSize: 14, weight: .medium),
                    color: .labelColor,
                    lineSpacing: 4,
                    paragraphSpacing: 10
                )
            case .label:
                append(
                    block.content + "\n",
                    to: result,
                    font: .systemFont(ofSize: 15, weight: .semibold),
                    color: .labelColor,
                    lineSpacing: 5,
                    paragraphSpacing: 6
                )
            case .divider:
                append("────────\n\n", to: result, font: .systemFont(ofSize: 13), color: .separatorColor)
            case .blank:
                result.append(NSAttributedString(string: "\n"))
            case .text:
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .systemFont(ofSize: 16),
                    color: .labelColor,
                    lineSpacing: 7,
                    paragraphSpacing: 12
                )
            }
        }

        return result
    }

    private static func append(
        _ text: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat = 5,
        paragraphSpacing: CGFloat = 8,
        background: NSColor? = nil
    ) {
        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(MarkdownLinkifier.markdownAttributed(text)))
        let range = NSRange(location: 0, length: attributed.length)
        guard range.length > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.lineBreakMode = .byWordWrapping

        attributed.addAttribute(.font, value: font, range: range)
        attributed.addAttribute(.foregroundColor, value: color, range: range)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        if let background {
            attributed.addAttribute(.backgroundColor, value: background, range: range)
        }
        attributed.enumerateAttribute(.link, in: range) { value, linkRange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.foregroundColor, value: NSColor.linkColor, range: linkRange)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: linkRange)
        }

        result.append(attributed)
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: traits)
    }
}
