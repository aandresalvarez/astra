import AppKit
import SwiftUI
import ASTRAModels
import ASTRAPersistence
import ASTRACore

enum ShelfFileNavigatorContentPresentation: Equatable {
    case noWorkspacePaths
    case scanning
    case emptyScope
    case populatedList

    static func resolve(
        hasConfiguredRoots: Bool,
        hasVisibleFileRoots: Bool,
        isSearchingFiles: Bool,
        isScanningFiles: Bool
    ) -> ShelfFileNavigatorContentPresentation {
        if !hasConfiguredRoots {
            return .noWorkspacePaths
        }
        if isScanningFiles && !hasVisibleFileRoots {
            return .scanning
        }
        if !hasVisibleFileRoots && !isSearchingFiles {
            return .emptyScope
        }
        return .populatedList
    }

    var usesListSurface: Bool {
        switch self {
        case .noWorkspacePaths, .scanning, .emptyScope, .populatedList:
            true
        }
    }
}

enum ShelfTabStripPolicy {
    /// Every open file gets a tab with its own close button - even a lone
    /// file - so the toolbar's corner X keeps a single meaning (dismiss the
    /// shelf) and the last file is never left without a close affordance.
    static func showsTabStrip(openDocumentCount: Int) -> Bool {
        openDocumentCount > 0
    }
}

enum ShelfFileAutoOpenPolicy {
    static func shouldAutoOpen(
        hasFile: Bool,
        isLoadingDocument: Bool,
        snapshotSource: ShelfFileIndexSnapshotSource
    ) -> Bool {
        !hasFile && !isLoadingDocument && snapshotSource == .fresh
    }
}

enum ShelfFileSelectionAlignment {
    static func scope(
        for path: String,
        roots: [WorkspaceFileRoot],
        currentScope: ShelfFileNavigatorScope,
        hasTask: Bool
    ) -> ShelfFileNavigatorScope? {
        guard let root = roots.first(where: { WorkspaceFileIndexService.isPath(path, inside: $0) }) else {
            return nil
        }
        switch root.kind {
        case .primary, .additional:
            return currentScope == .task ? .workspace : currentScope
        case .taskFolder, .input:
            return currentScope == .workspace && hasTask ? .task : currentScope
        }
    }
}

struct ShelfMarkdownPanelView: View {
    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
    private static let visibleNodeBatchLimit = 180

    @ObservedObject var session: ShelfMarkdownSession
    @ObservedObject var fileIndex: ShelfFileIndexController
    @Binding var isPinnedToTask: Bool
    var workspace: Workspace?
    var task: AgentTask?
    var onOpenGeneratedFile: ((String) -> Void)?
    var responsivenessScope: UUID?
    @AppStorage(AppStorageKeys.markdownShelfShowHiddenPaths) private var showHiddenWorkspacePaths = false
    @AppStorage(AppStorageKeys.markdownShelfFileNavigatorPinned) private var isFileNavigatorPinned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewMode: ShelfTextViewMode = .preview
    @State private var isEditing = false
    @State private var wrapLines = true
    @State private var fileNavigatorScope: ShelfFileNavigatorScope = .task
    @State private var fileSearchText = ""
    /// Debounced mirror of `fileSearchText` that actually drives filtering, so a
    /// keystroke doesn't re-filter the (up to ~5,000 node) tree on every key.
    /// See the UI responsiveness audit (Cluster 3).
    @State private var appliedFileSearchText = ""
    @State private var expandedRootIDs: Set<String> = []
    @State private var expandedDirectoryIDs: Set<String> = []
    @State private var documentLoadTask: Task<Void, Never>?
    @State private var isFileNavigatorPresented = false
    @State private var fileNavigatorWidth: CGFloat = ShelfWidthMetrics.filesNavigatorDefaultWidth
    @State private var fileNavigatorResizeStartWidth: CGFloat = ShelfWidthMetrics.filesNavigatorDefaultWidth
    @State private var isResizingFileNavigator = false
    @State private var largePreviewDocumentIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            fileWorkspace
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(ObjectIdentifier(session))
        .onAppear {
            if let responsivenessScope {
                FilesShelfResponsivenessTelemetry.ensureStarted(
                    taskID: task?.id,
                    workspaceID: (task?.workspace ?? workspace)?.id,
                    scope: responsivenessScope
                )
            }
            normalizeViewMode()
            normalizeFileNavigatorScope()
            let hasDiscoveredFileNavigator = ShelfFileNavigatorDiscoveryStore.hasDiscovered()
            isFileNavigatorPresented = ShelfFileNavigatorInitialPresentationPolicy.shouldPresent(
                isPinned: isFileNavigatorPinned,
                hasSelectedFile: session.hasFile,
                hasDiscoveredBrowser: hasDiscoveredFileNavigator
            )
            ShelfFileNavigatorDiscoveryStore.markDiscovered()
            refreshFileIndex(reason: "appear")
        }
        .onDisappear {
            fileIndex.cancel(responsivenessScope: responsivenessScope)
            documentLoadTask?.cancel()
            session.cancelPendingDocumentLoad()
        }
        .task(id: responsivenessScope) {
            await Task.yield()
            if let responsivenessScope {
                FilesShelfResponsivenessTelemetry.chromeReady(scope: responsivenessScope)
            }
        }
        .task(id: fileSearchText) {
            // Apply clears immediately; debounce non-empty queries so typing
            // doesn't re-filter the whole tree on every keystroke. `.task(id:)`
            // cancels the prior wait when the text changes again.
            if !fileSearchText.isEmpty {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }
            }
            appliedFileSearchText = fileSearchText
            await fileIndex.applySearchText(fileSearchText)
        }
        .onChange(of: session.selectedDocumentID) {
            isEditing = false
            normalizeViewMode()
            alignFileNavigatorWithSelectedDocument()
        }
        .onChange(of: fileScopeSignature) {
            normalizeFileNavigatorScope()
            refreshFileIndex(reason: "context_change")
        }
        .onChange(of: showHiddenWorkspacePaths) {
            refreshFileIndex(force: true, reason: "hidden_paths_change")
        }
        .onChange(of: fileNavigatorScope) {
            refreshFileIndex(reason: "scope_change")
        }
        .onChange(of: fileIndex.revision) {
            resetFileNavigatorExpansion()
            alignFileNavigatorWithSelectedDocument()
            autoOpenFirstFileIfNeeded(nodes: scopedFileNodes)
        }
        .onExitCommand {
            guard isFileNavigatorPresented, !isFileNavigatorPinned else { return }
            withAnimation(fileNavigatorAnimation) {
                isFileNavigatorPresented = false
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            browseFilesButton

            toolbarDocumentCluster

            Spacer(minLength: 0)

            toolbarActions
        }
        .frame(height: 42)
        .padding(.horizontal, 12)
        .background(.bar)
    }

    private var browseFilesButton: some View {
        Button {
            withAnimation(fileNavigatorAnimation) {
                isFileNavigatorPresented.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Label("Browse files", systemImage: "folder")

                Image(systemName: isFileNavigatorPresented ? "chevron.up" : "chevron.down")
                    .font(Stanford.ui(9, weight: .semibold))
            }
        }
        .buttonStyle(BrowseFilesToolbarButtonStyle(isActive: isFileNavigatorPresented))
        .help(isFileNavigatorPresented ? "Hide file browser" : "Browse files")
        .accessibilityLabel(isFileNavigatorPresented ? "Hide file browser" : "Browse files")
        .accessibilityIdentifier("FilesShelfBrowseButton")
    }

    private var toolbarDocumentCluster: some View {
        HStack(spacing: 10) {
            if session.hasFile {
                toolbarFileContext
            }

            if shouldShowModePicker {
                modePicker
            }
        }
        .layoutPriority(1)
    }

    private var toolbarFileContext: some View {
        HStack(spacing: 7) {
            Image(systemName: session.selectedDocumentKind?.systemImage ?? "folder")
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(session.hasFile ? Stanford.lagunita : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.selectedDocument?.title ?? "Files")
                        .font(Stanford.caption(12).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if session.isSelectedDocumentDirty {
                        Circle()
                            .fill(Stanford.cardinalRed)
                            .frame(width: 5, height: 5)
                            .help("Unsaved changes")
                    }
                }

                if let subtitle = toolbarFileSubtitle {
                    Text(subtitle)
                        .font(Stanford.caption(10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(minWidth: 100, idealWidth: 190, maxWidth: 240, alignment: .leading)
        .help(session.displayPath.isEmpty ? "Files shelf" : session.displayPath)
    }

    private var toolbarFileSubtitle: String? {
        guard let fileURL = session.fileURL else { return nil }
        let parent = fileURL.deletingLastPathComponent().path
        guard !parent.isEmpty else { return nil }
        if let root = fileIndex.roots.first(where: { WorkspaceFileIndexService.isPath(fileURL.path, inside: $0) }) {
            let relativeParent = relativePath(for: parent, rootPath: root.path)
            return relativeParent.isEmpty ? root.title : "\(root.title) / \(relativeParent)"
        }
        return parent
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
                .buttonStyle(TextShelfToolbarButtonStyle())
                .help(isEditing ? "Done editing" : "Edit file")
            }

            if shouldShowSaveButton {
                Button {
                    session.saveSelectedDocument()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(TextShelfToolbarButtonStyle())
                .disabled(!session.isSelectedDocumentDirty)
                .keyboardShortcut("s", modifiers: .command)
                .help(session.isSelectedDocumentDirty ? "Save changes" : "No changes to save")
            }

            overflowMenu
        }
    }

    private var viewerPane: some View {
        VStack(spacing: 0) {
            if ShelfTabStripPolicy.showsTabStrip(openDocumentCount: session.documents.count) {
                tabStrip
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

    private var fileWorkspace: some View {
        GeometryReader { proxy in
            let layout = ShelfFileNavigatorLayout.resolve(
                isPresented: isFileNavigatorPresented,
                isPinned: isFileNavigatorPinned,
                availableWidth: proxy.size.width,
                navigatorWidth: fileNavigatorWidth
            )

            switch layout {
            case .hidden:
                viewerPane
            case .floating:
                ZStack(alignment: .leading) {
                    viewerPane

                    Color.black.opacity(0.025)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(fileNavigatorAnimation) {
                                isFileNavigatorPresented = false
                            }
                        }
                        .accessibilityHidden(true)

                    HStack(spacing: 0) {
                        fileNavigator
                            .frame(width: ShelfFileNavigatorResizePolicy.displayedWidth(
                                layout: layout,
                                navigatorWidth: fileNavigatorWidth,
                                availableWidth: proxy.size.width,
                                reservesResizeHandle: isFileNavigatorPinned
                            ))

                        if ShelfFileNavigatorResizePolicy.showsResizeHandle(
                            layout: layout,
                            isPinned: isFileNavigatorPinned
                        ) {
                            FileNavigatorResizeHandle(
                                isResizing: isResizingFileNavigator,
                                onChanged: { translation in
                                    resizeFloatingFileNavigator(
                                        translation,
                                        availableWidth: proxy.size.width
                                    )
                                },
                                onEnded: finishResizingFileNavigator
                            )
                        }
                    }
                        .background(.bar)
                        .shadow(color: Color.black.opacity(0.14), radius: 14, x: 3, y: 0)
                        .transition(fileNavigatorTransition)
                        .zIndex(1)
                }
            case .docked:
                HStack(spacing: 0) {
                    fileNavigator
                        .frame(width: fileNavigatorWidth)

                    FileNavigatorResizeHandle(
                        isResizing: isResizingFileNavigator,
                        onChanged: resizeFileNavigator,
                        onEnded: finishResizingFileNavigator
                    )

                    viewerPane
                }
            }
        }
    }

    private var fileNavigatorTransition: AnyTransition {
        reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity)
    }

    private var fileNavigator: some View {
        VStack(spacing: 0) {
            ShelfFileNavigatorHeader(
                searchText: $fileSearchText,
                scope: $fileNavigatorScope,
                isPinned: $isFileNavigatorPinned,
                effectiveScope: effectiveFileNavigatorScope,
                showsScopePicker: shouldShowScopePicker,
                isScanning: fileIndex.isScanning,
                onRefresh: { refreshFileIndex(force: true, reason: "manual_refresh") }
            )

            Divider()

            fileNavigatorContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Stanford.cardBackground.opacity(0.20))
    }

    private var fileNavigatorContent: some View {
        fileNavigatorListSurface {
            switch fileNavigatorContentPresentation {
            case .noWorkspacePaths:
                fileNavigatorEmptyState(
                    title: "No workspace paths",
                    message: "Configure a workspace folder to browse files.",
                    systemImage: "folder.badge.questionmark"
                )
            case .scanning:
                fileNavigatorScanningState
            case .emptyScope:
                VStack(spacing: 0) {
                    fileNavigatorEmptyState(
                        title: emptyScopeTitle,
                        message: emptyScopeMessage,
                        systemImage: "folder"
                    )

                    if effectiveFileNavigatorScope == .task, workspace != nil {
                        Button {
                            fileNavigatorScope = .workspace
                        } label: {
                            Label("Browse workspace files", systemImage: "folder")
                        }
                        .buttonStyle(BrowseFilesToolbarButtonStyle())
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("FilesShelfBrowseWorkspaceButton")
                    }
                }
            case .populatedList:
                if isSearchingFiles {
                    searchResultsSection
                } else {
                    ShelfOpenDocumentsSection(session: session, onSelect: selectOpenDocument)

                    if effectiveFileNavigatorScope == .task {
                        taskScopeFileSections
                    } else {
                        ForEach(visibleFileRoots) { root in
                            fileRootSection(root)
                        }
                    }
                }

                if fileIndex.isTruncated {
                    Label("Scanned first \(fileIndex.nodes.count) items", systemImage: "exclamationmark.triangle")
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.poppy)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }

                ForEach(fileIndex.errors, id: \.self) { error in
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.poppy)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .help(error.path)
                }
            }
        }
    }

    private var taskScopeFileSections: some View {
        let generatedRoots = visibleFileRoots.filter { rootProvenance($0) == .taskGenerated }
        return VStack(alignment: .leading, spacing: 0) {
            taskFileGroupSection(
                title: "Task Files",
                roots: generatedRoots.filter { !isTaskOutputRoot($0) }
            )
            taskFileGroupSection(
                title: "Task Output",
                roots: generatedRoots.filter(isTaskOutputRoot)
            )
            taskFileGroupSection(
                title: ShelfFileProvenance.userProvided.groupTitle,
                roots: visibleFileRoots.filter { rootProvenance($0) == .userProvided }
            )
        }
    }

    @ViewBuilder
    private func taskFileGroupSection(title: String, roots: [WorkspaceFileRoot]) -> some View {
        if !roots.isEmpty {
            HStack(spacing: 6) {
                Text(title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer(minLength: 0)

                Text(rootCountLabel(roots.reduce(0) { $0 + filteredNodes(for: $1).filter { !$0.isDirectory }.count }))
                    .font(Stanford.caption(10).weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 4)

            ForEach(roots) { root in
                fileRootSection(root)
            }
        }
    }

    private var fileNavigatorContentPresentation: ShelfFileNavigatorContentPresentation {
        let scope = effectiveFileNavigatorScope
        return ShelfFileNavigatorContentPresentation.resolve(
            hasConfiguredRoots: ShelfFileNavigatorRootAvailability.hasConfiguredRoots(
                allRootCount: fileIndex.allRoots.count, scopedRootCount: fileIndex.roots.count,
                scope: scope
            ),
            hasVisibleFileRoots: !visibleFileRoots.isEmpty,
            isSearchingFiles: isSearchingFiles,
            isScanningFiles: fileIndex.isScanning
        )
    }

    private func fileNavigatorListSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileNavigatorEmptyState(
        title: String,
        message: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(message)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var fileNavigatorScanningState: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(scanningScopeTitle)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(scanningScopeMessage)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var searchResultsSection: some View {
        let results = fileSearchResults
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Search Results")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer(minLength: 0)

                Text("\(results.count)")
                    .font(Stanford.caption(10).weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if results.isEmpty {
                Text("No matches")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            } else {
                ForEach(results.prefix(80)) { node in
                    searchResultRow(node)
                }

                if results.count > 80 {
                    Text("\(results.count - 80) more matches")
                        .font(Stanford.caption(10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }
        }
    }

    @ViewBuilder
    private func fileRootSection(_ root: WorkspaceFileRoot) -> some View {
        let rootNodes = filteredNodes(for: root)
        let isExpanded = expandedRootIDs.contains(root.id)

        if let node = flattenedFileNode(for: root, rootNodes: rootNodes) {
            fileNodeRow(node, displayDepth: 0)
        } else {
            VStack(alignment: .leading, spacing: 0) {
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
                            HStack(spacing: 5) {
                                Text(fileRootTitle(root))
                                    .font(Stanford.caption(12).weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if root.isGitRepository {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(Stanford.ui(9, weight: .semibold))
                                        .foregroundStyle(Stanford.lagunita)
                                        .help("Git repository")
                                }
                            }

                            if !root.subtitle.isEmpty {
                                Text(root.subtitle)
                                    .font(Stanford.caption(9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer(minLength: 0)

                        if !rootNodes.isEmpty {
                            Text(rootCountLabel(rootNodes.count))
                                .font(Stanford.caption(10).weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(root.path)
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
                    let displayedNodes = visibleNodes(in: rootNodes)
                    if displayedNodes.isEmpty {
                        Text("No visible files in expanded folders")
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 38)
                            .padding(.vertical, 7)
                    } else {
                        ForEach(displayedNodes.prefix(Self.visibleNodeBatchLimit)) { node in
                            fileNodeRow(node)
                        }

                        if displayedNodes.count > Self.visibleNodeBatchLimit {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Showing first \(Self.visibleNodeBatchLimit) visible items")
                                    .font(Stanford.caption(11).weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text("Search or expand a narrower folder to continue browsing this path.")
                                    .font(Stanford.caption(10))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.leading, 38)
                            .padding(.trailing, 12)
                            .padding(.vertical, 7)
                        }
                    }
                }
            }
        }
    }

    private func fileNodeRow(_ node: WorkspaceFileNode, displayDepth: Int? = nil) -> some View {
        let isSelected = session.fileURL?.path == node.path
        let directoryID = directoryExpansionID(node)
        let isExpanded = expandedDirectoryIDs.contains(directoryID)
        let rowDepth = displayDepth ?? node.depth

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
            }
            .padding(.leading, CGFloat(rowDepth) * 12 + 10)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
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

                    Text(searchResultDetailLabel(for: node))
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
        appliedFileSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearchingFiles: Bool {
        !normalizedFileSearchText.isEmpty
    }

    private var effectiveFileNavigatorScope: ShelfFileNavigatorScope {
        if task == nil && fileNavigatorScope == .task {
            return .workspace
        }
        return fileNavigatorScope
    }

    private var shouldShowScopePicker: Bool {
        task != nil
    }

    private var scopedFileRoots: [WorkspaceFileRoot] {
        fileIndex.roots
    }

    private var visibleFileRoots: [WorkspaceFileRoot] {
        scopedFileRoots.filter { root in
            !filteredNodes(for: root).isEmpty
        }
    }

    private var scopedFileNodes: [WorkspaceFileNode] {
        fileIndex.nodes
    }

    private var emptyScopeTitle: String {
        switch effectiveFileNavigatorScope {
        case .task:
            "No task files"
        case .workspace:
            "No workspace files"
        case .all:
            "No files"
        }
    }

    private var emptyScopeMessage: String {
        switch effectiveFileNavigatorScope {
        case .task:
            "Generated files and task inputs will appear here."
        case .workspace:
            "Switch to All or use search if this workspace only has hidden or filtered paths."
        case .all:
            "No visible files were found in the configured paths."
        }
    }

    private var scanningScopeTitle: String {
        switch effectiveFileNavigatorScope {
        case .task:
            "Scanning task files"
        case .workspace:
            "Scanning workspace files"
        case .all:
            "Scanning files"
        }
    }

    private var scanningScopeMessage: String {
        switch effectiveFileNavigatorScope {
        case .task:
            "Looking for generated files and task inputs."
        case .workspace:
            "Looking for visible files in this workspace."
        case .all:
            "Looking through the configured file paths."
        }
    }

    private var fileSearchResults: [WorkspaceFileNode] {
        guard isSearchingFiles else { return [] }
        return scopedFileRoots.flatMap(fileIndex.nodes(for:)).filter { !$0.isDirectory }
    }

    private func searchResultPathLabel(for node: WorkspaceFileNode) -> String {
        let rootTitle = fileIndex.roots.first(where: { $0.id == node.rootID })?.title ?? "Workspace"
        let parent = node.parentRelativePath
        return parent.isEmpty ? rootTitle : "\(rootTitle) / \(parent)"
    }

    private func searchResultDetailLabel(for node: WorkspaceFileNode) -> String {
        guard let provenance = fileNodeProvenance(node) else {
            return searchResultPathLabel(for: node)
        }
        return "\(provenance.label) · \(searchResultPathLabel(for: node))"
    }

    private func refreshFileIndex(force: Bool = false, reason: String = "menu_refresh") {
        let roots = orderedFileRoots(WorkspaceFileIndexService.roots(workspace: workspace, task: task))
        expandedRootIDs = []
        fileIndex.refresh(
            allRoots: roots,
            scope: effectiveFileNavigatorScope,
            includeHidden: showHiddenWorkspacePaths,
            force: force,
            reason: reason,
            taskID: task?.id,
            responsivenessScope: responsivenessScope
        )
    }

    private func normalizeFileNavigatorScope() {
        if task == nil {
            fileNavigatorScope = .workspace
        }
    }

    private func resetFileNavigatorExpansion() {
        expandedRootIDs = []
        expandedDirectoryIDs = []

        guard let fileURL = session.fileURL,
              let root = scopedFileRoots.first(where: { WorkspaceFileIndexService.isPath(fileURL.path, inside: $0) }) else {
            return
        }
        expandedRootIDs.insert(root.id)
        expandFileNavigator(to: fileURL.path, isFile: true)
    }

    private func alignFileNavigatorWithSelectedDocument() {
        guard let fileURL = session.fileURL else { return }
        let path = fileURL.standardizedFileURL.path
        if let alignedScope = ShelfFileSelectionAlignment.scope(
            for: path,
            roots: fileIndex.allRoots,
            currentScope: fileNavigatorScope,
            hasTask: task != nil
        ), alignedScope != fileNavigatorScope {
            fileNavigatorScope = alignedScope
        }
        expandFileNavigator(to: path, isFile: true)
    }

    private func rootCountLabel(_ count: Int) -> String {
        count >= 5_000 ? "5,000+" : "\(count)"
    }

    private func orderedFileRoots(_ roots: [WorkspaceFileRoot]) -> [WorkspaceFileRoot] {
        guard task != nil else { return roots }
        return roots.enumerated().sorted { lhs, rhs in
            let lhsPriority = fileRootPriority(lhs.element.kind)
            let rhsPriority = fileRootPriority(rhs.element.kind)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func fileRootPriority(_ kind: WorkspaceFileRoot.Kind) -> Int {
        switch kind {
        case .taskFolder:
            0
        case .input:
            1
        case .primary:
            2
        case .additional:
            3
        }
    }

    private var currentTaskOutputFolderNames: Set<String> {
        ShelfFileProvenanceResolver.currentTaskOutputFolderNames(for: task)
    }

    private func rootProvenance(_ root: WorkspaceFileRoot) -> ShelfFileProvenance {
        ShelfFileProvenanceResolver.provenance(
            for: root,
            currentTaskOutputFolderNames: currentTaskOutputFolderNames
        )
    }

    private func isTaskOutputRoot(_ root: WorkspaceFileRoot) -> Bool {
        guard root.kind == .taskFolder, let task else { return false }
        let taskFolder = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .standardizedFileURL.path
        return URL(fileURLWithPath: root.path).standardizedFileURL.path != taskFolder
    }

    private func fileRootTitle(_ root: WorkspaceFileRoot) -> String {
        guard root.kind == .taskFolder else { return root.title }
        guard isTaskOutputRoot(root) else { return "Working files" }

        let folderName = URL(fileURLWithPath: root.path).lastPathComponent
        return currentTaskOutputFolderNames.contains(folderName) ? "Current result" : "Related result"
    }

    private func fileNodeProvenance(_ node: WorkspaceFileNode) -> ShelfFileProvenance? {
        guard let root = fileIndex.roots.first(where: { $0.id == node.rootID }) else {
            return nil
        }
        return ShelfFileProvenanceResolver.provenance(
            for: root,
            node: node,
            currentTaskOutputFolderNames: currentTaskOutputFolderNames
        )
    }

    private func autoOpenFirstFileIfNeeded(nodes: [WorkspaceFileNode]) {
        guard ShelfFileAutoOpenPolicy.shouldAutoOpen(
            hasFile: session.hasFile,
            isLoadingDocument: session.isLoadingDocument,
            snapshotSource: fileIndex.snapshotSource
        ),
              let node = nodes.first(where: { !$0.isDirectory }) else {
            return
        }
        startDocumentLoad(URL(fileURLWithPath: node.path), automatically: true)
    }

    private func flattenedFileNode(
        for root: WorkspaceFileRoot,
        rootNodes: [WorkspaceFileNode]
    ) -> WorkspaceFileNode? {
        guard !isSearchingFiles else { return nil }
        let fileNodes = rootNodes.filter { !$0.isDirectory }
        guard fileNodes.count == 1,
              rootNodes.allSatisfy({ !$0.isDirectory }) else {
            return nil
        }
        return fileNodes.first
    }

    private func filteredNodes(for root: WorkspaceFileRoot) -> [WorkspaceFileNode] {
        fileIndex.nodes(for: root)
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
        startDocumentLoad(URL(fileURLWithPath: node.path), automatically: false)
        finishFileSelection()
    }

    private func startDocumentLoad(_ url: URL, automatically: Bool) {
        documentLoadTask?.cancel()
        documentLoadTask = Task {
            let loaded = automatically
                ? await session.loadAutomaticallyIfAllowedAsync(url)
                : await session.loadAsync(url)
            guard loaded, !Task.isCancelled else { return }
            expandFileNavigator(to: url.path, isFile: true)
        }
    }

    private func selectOpenDocument(_ documentID: String) {
        session.selectDocument(documentID)
        finishFileSelection()
    }

    private func finishFileSelection() {
        withAnimation(fileNavigatorAnimation) {
            isFileNavigatorPresented = ShelfFileNavigatorSelectionPolicy
                .isPresentedAfterSelectingFile(isPinned: isFileNavigatorPinned)
        }
    }

    private func resizeFileNavigator(_ translation: CGSize) {
        if !isResizingFileNavigator {
            fileNavigatorResizeStartWidth = fileNavigatorWidth
            isResizingFileNavigator = true
        }

        fileNavigatorWidth = clampedFileNavigatorWidth(fileNavigatorResizeStartWidth + translation.width)
    }

    private func resizeFloatingFileNavigator(_ translation: CGSize, availableWidth: CGFloat) {
        if !isResizingFileNavigator {
            fileNavigatorResizeStartWidth = ShelfFileNavigatorResizePolicy.displayedWidth(
                layout: .floating,
                navigatorWidth: fileNavigatorWidth,
                availableWidth: availableWidth,
                reservesResizeHandle: true
            )
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

    private var shouldShowModePicker: Bool {
        session.selectedDocumentKind == .markdown || session.selectedDocumentKind == .json
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
            .frame(width: 142)
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
            .frame(width: 136)
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

        if let root = fileIndex.roots.first(where: { WorkspaceFileIndexService.isPath(filePath, inside: $0) }) {
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
            let rootName = root.title
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
            isFileNavigatorPresented = true
        }
        expandFileNavigator(to: segment.path, isFile: segment.isFile)
    }

    private var fileNavigatorAnimation: Animation? {
        AstraMotion.disclosure(reduceMotion: reduceMotion)
    }

    private func expandFileNavigator(to path: String, isFile: Bool) {
        let targetPath = isFile ? (path as NSString).deletingLastPathComponent : path
        guard let root = fileIndex.roots.first(where: { WorkspaceFileIndexService.isPath(targetPath, inside: $0) }) else {
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
        if standardizedPath == standardizedRoot {
            return ""
        }
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
                if let fileURL = session.fileURL {
                    startDocumentLoad(fileURL, automatically: false)
                }
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

            Toggle(isOn: $showHiddenWorkspacePaths) {
                Label(
                    "Show hidden paths",
                    systemImage: showHiddenWorkspacePaths ? "eye" : "eye.slash"
                )
            }
            .help("Show dotfiles and tool folders such as .astra, .codex, and .claude. Internal task history stays hidden.")

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
        if session.isLoadingDocument && !session.hasFile {
            ProgressView("Preparing preview…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = session.errorMessage {
            fileUnavailableView(errorMessage)
        } else if !session.hasFile {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(Stanford.ui(28, weight: .regular))
                    .foregroundStyle(.tertiary)

                Text("No file selected")
                    .font(Stanford.body(16).weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("Choose a task or workspace file to preview it here.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)

                Button {
                    withAnimation(fileNavigatorAnimation) {
                        isFileNavigatorPresented = true
                    }
                } label: {
                    Label("Browse files", systemImage: "folder")
                }
                .buttonStyle(BrowseFilesToolbarButtonStyle(isActive: true))
                .padding(.top, 8)
                .accessibilityIdentifier("FilesShelfEmptyStateBrowseButton")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 120)
            .frame(maxHeight: .infinity, alignment: .top)
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
                    if let fileURL = session.fileURL {
                        startDocumentLoad(fileURL, automatically: false)
                    }
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
        if let preview = document.imagePreview {
            GeometryReader { proxy in
                ZStack {
                    Stanford.cardBackground.opacity(0.45)

                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: preview.image)
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
