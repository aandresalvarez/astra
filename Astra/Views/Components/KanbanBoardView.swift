import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Kanban Category

enum KanbanCategory: String, CaseIterable, Identifiable, Hashable {
    case drafts = "Drafts"
    case queued = "Queued"
    case running = "Running"
    /// Anything that needs the user's eyeballs: pending-user prompts *and*
    /// agent-terminal statuses that haven't been triaged yet (completed,
    /// failed, cancelled, budget-exceeded). The old `needsReview` + `finished`
    /// lanes were two presentations of the same question — "does a human need
    /// to look at this?" — so they were merged into a single column.
    case review = "Review"
    case done = "Done"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .done:
            return TaskPresentationState.closedColumnTitle
        case .drafts, .queued, .running, .review:
            return rawValue
        }
    }

    var icon: String {
        switch self {
        case .drafts: return "pencil.circle.fill"
        case .queued: return "clock.fill"
        case .running: return "bolt.circle.fill"
        case .review: return "eye.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .drafts: return Stanford.driftwood
        case .queued: return Stanford.queued
        case .running: return Stanford.running
        case .review: return Stanford.pendingUser
        case .done: return Stanford.completed
        }
    }

    func includes(status: TaskStatus, isDone: Bool) -> Bool {
        switch self {
        case .drafts:
            return !isDone && status == .draft
        case .queued:
            return !isDone && status == .queued
        case .running:
            return !isDone && status == .running
        case .review:
            return !isDone && [.pendingUser, .completed, .failed, .cancelled, .budgetExceeded].contains(status)
        case .done:
            return isDone
        }
    }

    func includes(_ task: AgentTask) -> Bool {
        includes(status: task.status, isDone: task.isDone)
    }

    func sortedTasks(from tasks: [AgentTask]) -> [AgentTask] {
        switch self {
        case .queued:
            return tasks.sorted { $0.queuePosition < $1.queuePosition }
        case .review:
            // Pending-user tasks are actively blocking the agent on a
            // question — surface them above passive terminal outcomes.
            return tasks.sorted { lhs, rhs in
                let lhsPending = lhs.status == .pendingUser
                let rhsPending = rhs.status == .pendingUser
                if lhsPending != rhsPending { return lhsPending }
                return lhs.updatedAt > rhs.updatedAt
            }
        default:
            return tasks.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Keyboard shortcut character (1-5) for moving a task to this category via the
    /// card context menu. Maps to the lifecycle ordering of the board columns so a
    /// returning user can learn them positionally.
    var keyboardMoveShortcut: KeyEquivalent {
        switch self {
        case .drafts: return "1"
        case .queued: return "2"
        case .running: return "3"
        case .review: return "4"
        case .done: return "5"
        }
    }

    /// VoiceOver description for a column header — supplements the visual icon and
    /// colour so the category meaning is not encoded only by hue.
    var accessibilityDescription: String {
        switch self {
        case .drafts: return "Drafts column. Not yet queued."
        case .queued: return "Queued column. Waiting for an agent."
        case .running: return "Running column. Agent-owned; cards move here automatically."
        case .review: return "Review column. Tasks waiting for your attention — either a pending question or an untriaged outcome."
        case .done: return "Closed column. Archived tasks."
        }
    }
}

/// Attaches a `⌘N` keyboard shortcut to a menu item that moves the focused task
/// into the given category. Defined as a `ViewModifier` so we can apply it inside
/// a `ForEach` without SwiftUI complaining about a non-constant shortcut key.
private struct MoveShortcutModifier: ViewModifier {
    let category: KanbanCategory

    func body(content: Content) -> some View {
        content.keyboardShortcut(category.keyboardMoveShortcut, modifiers: [.command])
    }
}

enum KanbanBoardDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfort"
        case .spacious: return "Spacious"
        }
    }

    var icon: String {
        switch self {
        case .compact: return "rectangle.compress.vertical"
        case .comfortable: return "rectangle.grid.1x2"
        case .spacious: return "rectangle.expand.vertical"
        }
    }

    var columnWidth: CGFloat {
        switch self {
        case .compact: return 154
        case .comfortable: return 184
        case .spacious: return 220
        }
    }

    func columnWidth(for category: KanbanCategory) -> CGFloat {
        switch category {
        case .review:
            switch self {
            case .compact: return 260
            case .comfortable: return 320
            case .spacious: return 380
            }
        case .done:
            switch self {
            case .compact: return 200
            case .comfortable: return 238
            case .spacious: return 280
            }
        default:
            return columnWidth
        }
    }

    var columnMaxHeight: CGFloat {
        switch self {
        case .compact: return 420
        case .comfortable: return 510
        case .spacious: return 600
        }
    }

    var collapsedLaneHeight: CGFloat {
        switch self {
        case .compact: return 310
        case .comfortable: return 388
        case .spacious: return 460
        }
    }

    var cardSpacing: CGFloat {
        switch self {
        case .compact: return 5
        case .comfortable: return 7
        case .spacious: return 10
        }
    }

    var cardPadding: EdgeInsets {
        switch self {
        case .compact:
            return EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)
        case .comfortable:
            return EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10)
        case .spacious:
            return EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        }
    }

    var titleLineLimit: Int {
        switch self {
        case .compact: return 2
        case .comfortable, .spacious: return 3
        }
    }
}

enum KanbanBoardPresentation {
    static let toolbarUsesSingleRow = true
    static let columnsUseQuietLaneChrome = true
    static let columnHeaderUsesDotTitleCount = true
    static let taskCardsUseSingleMetadataLine = true
    static let taskCardsReserveTopMetadataRow = false
    static let visibleTrashIsQuietUntilDrag = true
    static let reviewCardsUseLeadingAccentOnly = true
    static let taskCardsDeduplicateRepeatedTitles = true
    static let taskCardsExposeOutcomeMetadata = true
    static let columnBaseFillOpacity: Double = 0.012
    static let persistentColumnFillOpacity: Double = 0.016
    static let columnStrokeOpacity: Double = 0.045
    static let cardBaseFillOpacity: Double = 0.018
    static let cardHoverFillOpacity: Double = 0.032
    static let cardStrokeOpacity: Double = 0.045
    static let cardHoverStrokeOpacity: Double = 0.10

    static func cardThreadMessageFallbackCount(goal: String) -> Int {
        AgentTask.fallbackThreadMessageCount(forGoal: goal)
    }
}

enum KanbanBoardLayout {
    static let columnSpacing: CGFloat = 12
    static let outerPadding: CGFloat = 12

    static func contentWidth(for categories: [KanbanCategory], density: KanbanBoardDensity) -> CGFloat {
        let totalColumns = categories.reduce(0) { $0 + density.columnWidth(for: $1) }
        let totalSpacing = columnSpacing * CGFloat(max(0, categories.count - 1))
        return totalColumns + totalSpacing
    }
}

private let kanbanBoardCoordinateSpace = "kanbanBoardCoordinateSpace"

/// Fingerprint of the board-relevant fields of one task. Streaming token
/// updates mutate fields like `tokensUsed`/`costUSD`/`draftMessages` that do
/// NOT appear here, so the fingerprint stays stable and the board does not
/// re-bucket. Only id / status / queuePosition / isDone / updatedAt are
/// included — exactly the fields `KanbanCategory.includes(_:)` and
/// `KanbanCategory.sortedTasks(from:)` read.
/// Cheap value-type fingerprint of the inputs that determine board membership
/// and ordering. Stored by `KanbanBucketCache` and compared element-wise (no
/// hashing, so no collision risk). `status` is the `TaskStatus` enum, not its
/// rawValue String, so comparison allocates nothing.
private struct KanbanTaskFingerprint: Equatable {
    let id: UUID
    let status: TaskStatus
    let queuePosition: Int
    let isDone: Bool
    let updatedAt: Date

    init(_ task: AgentTask) {
        self.id = task.id
        self.status = task.status
        self.queuePosition = task.queuePosition
        self.isDone = task.isDone
        self.updatedAt = task.updatedAt
    }

    func matches(_ task: AgentTask) -> Bool {
        id == task.id
            && status == task.status
            && queuePosition == task.queuePosition
            && isDone == task.isDone
            && updatedAt == task.updatedAt
    }
}

/// Reference-type memo for the board's per-column buckets. Held in `@State`
/// on `KanbanBoardView`; because it is a class, mutating it in place does NOT
/// invalidate the view (unlike mutating a value-type `@State`), so the lazy
/// recompute can run safely from within `body`/computed reads. Recomputes the
/// five buckets once per data change, gated on an exact element-wise comparison
/// so streaming updates that don't change board membership or ordering reuse
/// the previous buckets.
private final class KanbanBucketCache {
    private var fingerprint: [KanbanTaskFingerprint] = []
    private var cached: [KanbanCategory: [AgentTask]] = [:]
    private var primed = false

    func buckets(for tasks: [AgentTask]) -> [KanbanCategory: [AgentTask]] {
        // Exact, allocation-free check on the no-change (hot) path: compare each
        // task against the stored fingerprint in a single pass without building
        // a new `[KanbanTaskFingerprint]` array. `buckets(for:)` is read 15–25×
        // per render (and on every drag-delta frame while dragging a card), so
        // avoiding the per-call array allocation removes the bulk of the cost.
        // An exact compare (vs. a hash) means no chance of reusing stale buckets
        // on a hash collision. See the UI responsiveness audit (Cluster 3).
        if primed, fingerprint.count == tasks.count,
           zip(fingerprint, tasks).allSatisfy({ $0.matches($1) }) {
            return cached
        }
        var result: [KanbanCategory: [AgentTask]] = [:]
        for category in KanbanCategory.allCases {
            result[category] = category.sortedTasks(from: tasks.filter { category.includes($0) })
        }
        fingerprint = tasks.map(KanbanTaskFingerprint.init)
        cached = result
        primed = true
        return result
    }
}

private struct KanbanDragState: Equatable {
    let taskID: UUID
    let sourceCategory: KanbanCategory
    let sourceFrame: CGRect
    var location: CGPoint
    var translation: CGSize
}

private struct KanbanColumnFramePreferenceKey: PreferenceKey {
    static var defaultValue: [KanbanCategory: CGRect] = [:]

    static func reduce(value: inout [KanbanCategory: CGRect], nextValue: () -> [KanbanCategory: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct KanbanTaskFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct KanbanUtilityDropFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull {
            value = next
        }
    }
}

private enum KanbanDropTarget: Equatable {
    case category(KanbanCategory)
    case discard
}

// MARK: - Kanban Board

struct KanbanBoardView: View {
    let tasks: [AgentTask]
    let onOpenTask: (AgentTask) -> Void
    let onDeleteTask: (AgentTask) -> Void
    var onSetDoneState: ((AgentTask, Bool) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("kanbanBoardDensity") private var densityRaw = KanbanBoardDensity.spacious.rawValue
    @AppStorage("kanbanShowCardDetails") private var showCardDetails = true
    @State private var expandedEmptyCategories: Set<KanbanCategory> = []
    @State private var columnFrames: [KanbanCategory: CGRect] = [:]
    @State private var taskFrames: [UUID: CGRect] = [:]
    @State private var utilityDropFrame: CGRect = .null
    @State private var dragState: KanbanDragState?
    @State private var taskPendingDiscard: AgentTask?
    @State private var showClearAllDoneConfirm = false
    // Reference-type memo: buckets are recomputed once per data change and
    // reused across the multiple `tasksFor(_:)` calls each body pass makes.
    @State private var bucketCache = KanbanBucketCache()

    private let acceptedDropTypes: [UTType] = [.plainText, .text, .utf8PlainText]

    private var density: KanbanBoardDensity {
        KanbanBoardDensity(rawValue: densityRaw) ?? .spacious
    }

    private var densitySelection: Binding<KanbanBoardDensity> {
        Binding(
            get: { density },
            set: { densityRaw = $0.rawValue }
        )
    }

    private var boardCategories: [KanbanCategory] {
        // Drafts are in-composition plumbing, not delegated work — the board is
        // the supervision pipeline only (Queued → Running → Review → Done).
        // Draft-status tasks are also filtered out before they reach the board,
        // so the lane is dropped here to avoid an always-empty column.
        KanbanCategory.allCases.filter { $0 != .drafts }
    }

    private var persistentDropCategories: Set<KanbanCategory> {
        [.review, .done]
    }

    private var collapsibleLifecycleCategories: Set<KanbanCategory> {
        [.drafts, .queued, .running]
    }

    private var isEmptyBoard: Bool {
        tasks.isEmpty
    }

    private var visibleCategories: [KanbanCategory] {
        guard !isEmptyBoard else {
            return boardCategories.filter { persistentDropCategories.contains($0) }
        }
        return boardCategories.filter { category in
            persistentDropCategories.contains(category)
                || !tasksFor(category).isEmpty
                || expandedEmptyCategories.contains(category)
        }
    }

    /// Total rendered width of the kanban column row (sum of column widths +
    /// 12pt spacing between them). Used to constrain the toolbar above so its
    /// trailing controls (trash, View menu) align with the rightmost column's
    /// trailing edge rather than floating off near the window edge when the
    /// board doesn't fill the available space.
    private var kanbanContentWidth: CGFloat {
        KanbanBoardLayout.contentWidth(for: visibleCategories, density: density)
    }

    private var collapsedEmptyCategories: [KanbanCategory] {
        guard !isEmptyBoard else { return [] }
        return boardCategories.filter { category in
            collapsibleLifecycleCategories.contains(category)
                && tasksFor(category).isEmpty
                && !expandedEmptyCategories.contains(category)
        }
    }

    private var hasExpandedEmptyLifecycleCategories: Bool {
        !expandedEmptyCategories.intersection(collapsibleLifecycleCategories).isEmpty
    }

    private var visibleTaskCount: Int {
        visibleCategories.reduce(0) { $0 + tasksFor($1).count }
    }

    private var gestureDropTarget: KanbanDropTarget? {
        guard let dragState, let draggedTask else { return nil }
        return targetCategory(at: dragState.location, for: draggedTask)
    }

    private var draggedTask: AgentTask? {
        guard let dragState else { return nil }
        return tasks.first(where: { $0.id == dragState.taskID })
    }

    @ViewBuilder
    private var dragPreviewOverlay: some View {
        if let dragState, let draggedTask {
            KanbanTaskCardView(
                task: draggedTask,
                category: dragState.sourceCategory,
                density: density,
                showDetails: showCardDetails,
                isDragPreview: true
            )
            .frame(width: dragState.sourceFrame.width)
            .position(
                x: dragState.sourceFrame.midX + dragState.translation.width,
                y: dragState.sourceFrame.midY + dragState.translation.height
            )
            .zIndex(1000)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    /// Memoized buckets for the current `tasks`. Recomputes only when the
    /// fingerprint (ids + statuses + positions + isDone + updatedAt) changes,
    /// so a streaming token update that leaves board membership and order
    /// unchanged reuses the previous buckets instead of re-filtering/sorting.
    private var buckets: [KanbanCategory: [AgentTask]] {
        bucketCache.buckets(for: tasks)
    }

    private func tasksFor(_ category: KanbanCategory) -> [AgentTask] {
        buckets[category] ?? []
    }

    private func handleDrop(category: KanbanCategory, providers: [NSItemProvider]) -> Bool {
        let registeredTypes = providers
            .flatMap(\.registeredTypeIdentifiers)
            .joined(separator: ", ")
        AppLogger.info(
            "Kanban drop received category=\(category.rawValue) providerCount=\(providers.count) types=\(registeredTypes)",
            category: "UI"
        )

        guard let provider = providers.first(where: { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
        }) else {
            AppLogger.warning("Kanban drop rejected: no compatible text provider", category: "UI")
            return false
        }

        if provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { object, error in
                DispatchQueue.main.async {
                    if let error {
                        AppLogger.warning(
                            "Kanban drop loadObject failed category=\(category.rawValue) error=\(error.localizedDescription)",
                            category: "UI"
                        )
                    }
                    let idString: String?
                    if let string = object as? NSString {
                        idString = string as String
                    } else if let string = object as? String {
                        idString = string
                    } else {
                        idString = nil
                    }
                    guard let idString else {
                        AppLogger.warning("Kanban drop rejected: text object was nil", category: "UI")
                        return
                    }
                    applyDrop(category: category, idString: idString)
                }
            }
            return true
        }

        let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier
            : provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
                ? UTType.utf8PlainText.identifier
                : UTType.text.identifier

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
            let idString: String?
            if let data = item as? Data {
                idString = String(data: data, encoding: .utf8)
            } else if let string = item as? String {
                idString = string
            } else if let string = item as? NSString {
                idString = string as String
            } else {
                idString = nil
            }

            DispatchQueue.main.async {
                if let error {
                    AppLogger.warning(
                        "Kanban drop loadItem failed category=\(category.rawValue) type=\(typeIdentifier) error=\(error.localizedDescription)",
                        category: "UI"
                    )
                }
                guard let idString else {
                    AppLogger.warning(
                        "Kanban drop rejected: item type \(String(describing: type(of: item))) could not be decoded",
                        category: "UI"
                    )
                    return
                }
                applyDrop(category: category, idString: idString)
            }
        }

        return true
    }

    private func applyDrop(category: KanbanCategory, idString: String) {
        guard let uuid = UUID(uuidString: idString) else {
            AppLogger.warning("Kanban drop rejected: invalid task id \(idString)", category: "UI")
            return
        }
        guard let task = tasks.first(where: { $0.id == uuid }) else {
            AppLogger.warning("Kanban drop rejected: task \(uuid.uuidString) not found", category: "UI")
            return
        }
        // Don't allow moving running tasks
        guard task.status != .running else {
            AppLogger.info("Kanban drop ignored: running task \(task.id.uuidString)", category: "UI")
            return
        }

        let previousStatus = task.status
        let wasDone = task.isDone
        let (nextStatus, nextDone) = resolvedDropState(for: task, into: category)

        guard previousStatus != nextStatus || wasDone != nextDone else {
            AppLogger.info(
                "Kanban drop ignored: task \(task.id.uuidString) already matches \(category.rawValue)",
                category: "UI"
            )
            return
        }

        if previousStatus == nextStatus, wasDone != nextDone, let onSetDoneState {
            onSetDoneState(task, nextDone)
            AppLogger.info(
                "Kanban drop delegated task=\(task.id.uuidString) target=\(category.rawValue) done=\(wasDone)->\(nextDone)",
                category: "UI"
            )
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            TaskStateMachine.setFromBoardMove(task, to: nextStatus, modelContext: modelContext)
            task.isDone = nextDone
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
            AppLogger.info(
                "Kanban drop applied task=\(task.id.uuidString) target=\(category.rawValue) status=\(previousStatus.rawValue)->\(task.status.rawValue) done=\(wasDone)->\(task.isDone)",
                category: "UI"
            )
        }
    }

    private func resolvedDropState(for task: AgentTask, into category: KanbanCategory) -> (TaskStatus, Bool) {
        var nextStatus = task.status
        var nextDone = task.isDone

        switch category {
        case .drafts:
            nextStatus = .draft
            nextDone = false
        case .queued:
            nextStatus = .queued
            nextDone = false
        case .running:
            // Running is read-only: the agent owns this lane.
            // Keep current status so isActionableDropTarget rejects the drop.
            nextDone = false
        case .review:
            // Review keeps the card's current status (pendingUser, completed,
            // failed, cancelled, budgetExceeded) and just clears the archive
            // flag. Practically this means: dropping a Closed card into Review
            // un-archives it; dropping an active card in here is rejected by
            // the filter and handled as a no-op.
            nextDone = false
        case .done:
            nextDone = true
        }

        return (nextStatus, nextDone)
    }

    private func isActionableDropTarget(_ category: KanbanCategory, for task: AgentTask) -> Bool {
        let (nextStatus, nextDone) = resolvedDropState(for: task, into: category)
        guard task.status != nextStatus || task.isDone != nextDone else { return false }
        return category.includes(status: nextStatus, isDone: nextDone)
    }

    private func availableMoveCategories(for task: AgentTask) -> [KanbanCategory] {
        boardCategories.filter { isActionableDropTarget($0, for: task) }
    }

    private func moveTask(_ task: AgentTask, to category: KanbanCategory) {
        guard isActionableDropTarget(category, for: task) else { return }
        applyDrop(category: category, idString: task.id.uuidString)
    }

    private func canDiscard(_ task: AgentTask) -> Bool {
        task.status != .running
    }

    private func discardTask(_ task: AgentTask) {
        guard canDiscard(task) else { return }
        taskPendingDiscard = task
    }

    private func targetCategory(at location: CGPoint, for task: AgentTask? = nil) -> KanbanDropTarget? {
        if utilityDropFrame.insetBy(dx: -8, dy: -8).contains(location) {
            if let task, canDiscard(task) {
                return .discard
            }
        }

        if let category = visibleCategories.reversed().first(where: { category in
            guard let frame = columnFrames[category] else { return false }
            guard frame.insetBy(dx: -8, dy: -8).contains(location) else { return false }
            guard let task else { return true }
            return isActionableDropTarget(category, for: task)
        }) {
            return .category(category)
        }

        return nil
    }

    private func handleGestureDragChanged(
        task: AgentTask,
        sourceCategory: KanbanCategory,
        value: DragGesture.Value
    ) {
        guard task.status != .running else { return }
        guard let sourceFrame = taskFrames[task.id] else { return }

        if dragState?.taskID != task.id {
            AppLogger.info(
                "Kanban gesture drag started task=\(task.id.uuidString) source=\(sourceCategory.rawValue)",
                category: "UI"
            )
        }

        dragState = KanbanDragState(
            taskID: task.id,
            sourceCategory: sourceCategory,
            sourceFrame: sourceFrame,
            location: value.location,
            translation: value.translation
        )
    }

    private func handleGestureDragEnded(task: AgentTask, value: DragGesture.Value) {
        defer {
            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.84)) {
                dragState = nil
            }
        }

        guard task.status != .running else { return }

        guard let target = targetCategory(at: value.location, for: task) else {
            AppLogger.info("Kanban gesture drop cancelled task=\(task.id.uuidString)", category: "UI")
            return
        }

        AppLogger.info(
            "Kanban gesture drop ended task=\(task.id.uuidString) target=\(target)",
            category: "UI"
        )
        switch target {
        case .category(let category):
            applyDrop(category: category, idString: task.id.uuidString)
        case .discard:
            discardTask(task)
        }
    }

    private func expandEmptyCategory(_ category: KanbanCategory) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
            _ = expandedEmptyCategories.insert(category)
        }
    }

    private func expandAllCollapsedCategories() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
            expandedEmptyCategories.formUnion(collapsedEmptyCategories)
        }
    }

    private func collapseEmptyCategory(_ category: KanbanCategory) {
        guard collapsibleLifecycleCategories.contains(category) else { return }
        guard tasksFor(category).isEmpty else { return }

        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
            _ = expandedEmptyCategories.remove(category)
        }
    }

    private func collapseEmptyLifecycleCategories() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
            expandedEmptyCategories.subtract(collapsibleLifecycleCategories)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Single toolbar row above the board — count summary + empty-
            // lane capsules on the left, trash + customize on the right.
            // The empty-lanes strip used to sit on its own row below this
            // header; folding it in saves vertical space and makes the
            // controls read as one toolbar instead of two stacked.
            // Capped to `kanbanContentWidth` so the trailing controls sit
            // above the rightmost column instead of drifting toward the
            // window edge when the board is narrower than the viewport.
            boardHeader
                .frame(maxWidth: kanbanContentWidth, alignment: .leading)

            if isEmptyBoard && visibleCategories.isEmpty {
                emptyKanbanMessage
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    AdaptiveGlassContainer(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(visibleCategories) { category in
                                let categoryTasks = tasksFor(category)
                                let canCollapseExpandedEmptyCategory =
                                    collapsibleLifecycleCategories.contains(category)
                                    && categoryTasks.isEmpty
                                    && expandedEmptyCategories.contains(category)

                                KanbanColumnView(
                                    category: category,
                                    tasks: categoryTasks,
                                    density: density,
                                    showCardDetails: showCardDetails,
                                    draggedTaskID: dragState?.taskID,
                                    isGestureDropTarget: gestureDropTarget == .category(category),
                                    canCollapseEmptyState: canCollapseExpandedEmptyCategory,
                                    onOpenTask: onOpenTask,
                                    availableMoveCategories: availableMoveCategories,
                                    onMoveTask: moveTask,
                                    onDiscardTask: discardTask,
                                    onDrop: { providers in
                                        handleDrop(category: category, providers: providers)
                                    },
                                    acceptedDropTypes: acceptedDropTypes,
                                    onDragChanged: { task, sourceCategory, value in
                                        handleGestureDragChanged(
                                            task: task,
                                            sourceCategory: sourceCategory,
                                            value: value
                                        )
                                    },
                                    onDragEnded: { task, value in
                                        handleGestureDragEnded(task: task, value: value)
                                    },
                                    onCollapseEmptyState: {
                                        collapseEmptyCategory(category)
                                    },
                                    onClearAll: category == .done ? {
                                        showClearAllDoneConfirm = true
                                    } : nil
                                )
                            }

                            // Discard lives in the board toolbar, not as a column.
                            // Columns in the strip now only represent real task states.
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
                }
                .coordinateSpace(name: kanbanBoardCoordinateSpace)
                .onPreferenceChange(KanbanColumnFramePreferenceKey.self) { frames in
                    columnFrames = frames
                }
                .onPreferenceChange(KanbanTaskFramePreferenceKey.self) { frames in
                    taskFrames = frames
                }
                .onPreferenceChange(KanbanUtilityDropFramePreferenceKey.self) { frame in
                    utilityDropFrame = frame
                }
                .overlay(alignment: .topLeading) {
                    dragPreviewOverlay
                }
            }
        }
        .padding(12)
        .background(Color.clear)
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Delete \"\(taskPendingDiscard?.title ?? "task")\"?",
            isPresented: Binding(
                get: { taskPendingDiscard != nil },
                set: { if !$0 { taskPendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let task = taskPendingDiscard {
                    onDeleteTask(task)
                }
                taskPendingDiscard = nil
            }
            Button("Cancel", role: .cancel) {
                taskPendingDiscard = nil
            }
        }
        .confirmationDialog(
            "Delete all done tasks?",
            isPresented: $showClearAllDoneConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(doneTasks.count) task\(doneTasks.count == 1 ? "" : "s")", role: .destructive) {
                for task in doneTasks {
                    onDeleteTask(task)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var doneTasks: [AgentTask] {
        tasksFor(.done)
    }

    private var boardHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            // Far left: count summary. Quietly tells the user how big the
            // board is and whether anything is hidden behind the visibility
            // toggle (e.g. "3 visible of 5 tasks").
            Text(taskCountSummary)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.secondary)
                .help("Number of tasks on the board")

            // Inline empty-lane indicators. Used to be on its own row
            // below the header — folded in here so there's a single
            // toolbar above the columns instead of two stacked ones.
            if !collapsedEmptyCategories.isEmpty {
                CollapsedKanbanLanesView(
                    categories: collapsedEmptyCategories,
                    density: density,
                    onExpand: expandEmptyCategory
                )
            }

            Spacer()

            // Trash stays as a visible drop target — it's drag-only, no
            // click action, so hiding it inside the Customize menu would
            // break the discard-by-drag affordance entirely.
            KanbanDiscardToolbarTarget(
                acceptedDropTypes: acceptedDropTypes,
                isGestureDropTarget: gestureDropTarget == .discard,
                canDropDraggedTask: draggedTask.map { canDiscard($0) } ?? true,
                onDeleteTask: { task in
                    discardTask(task)
                }
            )

            Divider()
                .frame(height: 18)
                .opacity(0.35)

            // Customize menu now hosts the column-visibility toggles
            // (Show All Columns / Hide Empty) alongside density and
            // card details. They were standalone text buttons in the
            // toolbar before, which read as ad-hoc actions; living
            // inside Customize makes their toggle nature explicit.
            Menu {
                if !collapsedEmptyCategories.isEmpty {
                    Button {
                        expandAllCollapsedCategories()
                    } label: {
                        Label("Show All Columns", systemImage: "rectangle.split.3x1")
                    }
                }

                if hasExpandedEmptyLifecycleCategories {
                    Button {
                        collapseEmptyLifecycleCategories()
                    } label: {
                        Label("Hide Empty Columns", systemImage: "rectangle.compress.vertical")
                    }
                }

                if !collapsedEmptyCategories.isEmpty || hasExpandedEmptyLifecycleCategories {
                    Divider()
                }

                Picker("Density", selection: densitySelection) {
                    ForEach(KanbanBoardDensity.allCases) { density in
                        Label(density.title, systemImage: density.icon)
                            .tag(density)
                    }
                }

                Section("Cards") {
                    Toggle("Show Details", isOn: $showCardDetails)
                }
            } label: {
                Label("View", systemImage: "slider.horizontal.3")
                    .font(Stanford.caption(11).weight(.medium))
                    .frame(height: 26)
                    .padding(.horizontal, 7)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Customize board")
        }
    }

    private var taskCountSummary: String {
        let totalLabel = tasks.count == 1 ? "task" : "tasks"
        if visibleTaskCount == tasks.count {
            return "\(tasks.count) \(totalLabel)"
        }
        return "\(visibleTaskCount) visible of \(tasks.count) \(totalLabel)"
    }

    private var emptyKanbanMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Empty Kanban")
                .font(Stanford.body(15).weight(.semibold))
                .foregroundStyle(.primary)
            Text("Create a task to start the workspace board.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .liquidSurface(cornerRadius: 12, fallbackFill: Color.primary.opacity(0.025), fallbackStrokeOpacity: 0.055)
    }
}

// MARK: - Kanban Column

struct KanbanColumnView: View {
    let category: KanbanCategory
    let tasks: [AgentTask]
    let density: KanbanBoardDensity
    let showCardDetails: Bool
    let draggedTaskID: UUID?
    let isGestureDropTarget: Bool
    let canCollapseEmptyState: Bool
    let onOpenTask: (AgentTask) -> Void
    let availableMoveCategories: (AgentTask) -> [KanbanCategory]
    let onMoveTask: (AgentTask, KanbanCategory) -> Void
    let onDiscardTask: (AgentTask) -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    let acceptedDropTypes: [UTType]
    let onDragChanged: (AgentTask, KanbanCategory, DragGesture.Value) -> Void
    let onDragEnded: (AgentTask, DragGesture.Value) -> Void
    let onCollapseEmptyState: () -> Void
    var onClearAll: (() -> Void)?

    @State private var isDropTargeted = false
    @State private var hoveredTaskID: UUID?
    @State private var isColumnHovered = false
    @State private var isTrashHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActiveDropTarget: Bool {
        isDropTargeted || isGestureDropTarget
    }

    private var isPersistentDropColumn: Bool {
        category == .review || category == .done
    }

    @ViewBuilder
    private var columnSurface: some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
        let baseFill = Color.primary.opacity(
            isPersistentDropColumn
                ? KanbanBoardPresentation.persistentColumnFillOpacity
                : KanbanBoardPresentation.columnBaseFillOpacity
        )

        shape
            .fill(baseFill)
            .overlay {
                shape.stroke(
                    Color.primary.opacity(
                        isActiveDropTarget ? 0.14 : KanbanBoardPresentation.columnStrokeOpacity
                    ),
                    lineWidth: 1
                )
            }
            .shadow(
                color: category.color.opacity(isActiveDropTarget ? 0.10 : 0),
                radius: isActiveDropTarget ? 12 : 0,
                x: 0,
                y: isActiveDropTarget ? 6 : 0
            )
    }

    private var dropHintTitle: String {
        switch category {
        case .drafts:
            return "Move to draft"
        case .queued:
            return "Queue task"
        case .running:
            return "Agent-owned"
        case .review:
            return "Send to Review"
        case .done:
            return TaskPresentationState.closeTaskActionTitle
        }
    }

    private var dropHintIcon: String { category.icon }

    private var emptyTitle: String {
        if isActiveDropTarget {
            return dropHintTitle
        }
        switch category {
        case .drafts:
            return "No drafts"
        case .queued:
            return "Nothing queued"
        case .running:
            return "Nothing running"
        case .review:
            return "Nothing to review"
        case .done:
            return "Drop closed work here"
        }
    }

    private var emptySubtitle: String? {
        guard isPersistentDropColumn else { return nil }
        return category == .done
            ? "Archived tasks stay easy to reach."
            : "Pending questions and untriaged outcomes land here."
    }

    private var emptyIcon: String {
        if isActiveDropTarget {
            return category == .done ? "checkmark.circle.fill" : "arrow.down.to.line.compact"
        }
        return category == .done ? "checkmark.circle" : "tray"
    }

    private var emptyPlaceholderHeight: CGFloat {
        if isPersistentDropColumn {
            return density == .compact ? 88 : 104
        }
        return density == .spacious ? 92 : 72
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader

            ScrollView(.vertical, showsIndicators: true) {
                if tasks.isEmpty {
                    emptyColumnPlaceholder
                } else {
                    LazyVStack(spacing: density.cardSpacing) {
                        ForEach(tasks) { task in
                            let isDraggingTask = draggedTaskID == task.id
                            let moveTargets = availableMoveCategories(task)

                            ZStack(alignment: .topTrailing) {
                                KanbanTaskCardView(
                                    task: task,
                                    category: category,
                                    density: density,
                                    showDetails: showCardDetails
                                )
                                .opacity(isDraggingTask ? 0 : 1)
                                .allowsHitTesting(!isDraggingTask)
                                .accessibilityHidden(isDraggingTask)
                                .onTapGesture { onOpenTask(task) }
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: KanbanTaskFramePreferenceKey.self,
                                            value: [task.id: proxy.frame(in: .named(kanbanBoardCoordinateSpace))]
                                        )
                                    }
                                }
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 6, coordinateSpace: .named(kanbanBoardCoordinateSpace))
                                        .onChanged { value in
                                            onDragChanged(task, category, value)
                                        }
                                        .onEnded { value in
                                            onDragEnded(task, value)
                                        }
                                )
                                .contextMenu {
                                    taskActionsMenu(for: task, moveTargets: moveTargets)
                                }
                                .accessibilityAction(named: Text("Open task")) {
                                    onOpenTask(task)
                                }
                                if !moveTargets.isEmpty && hoveredTaskID == task.id && !isDraggingTask {
                                    Menu {
                                        taskActionsMenu(for: task, moveTargets: moveTargets)
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(Stanford.ui(12, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                            )
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .padding(.top, 8)
                                    .padding(.trailing, 8)
                                    .transition(.opacity)
                                }
                            }
                            .onHover { hovering in
                                if hovering {
                                    hoveredTaskID = task.id
                                } else if hoveredTaskID == task.id {
                                    hoveredTaskID = nil
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxHeight: density.columnMaxHeight)
            .contentShape(Rectangle())
            .onDrop(of: acceptedDropTypes, isTargeted: $isDropTargeted) { providers in
                onDrop(providers)
            }
            .overlay(alignment: .bottom) {
                if showsOverflowHint {
                    columnOverflowHint
                }
            }
        }
        .frame(width: density.columnWidth(for: category))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: KanbanColumnFramePreferenceKey.self,
                    value: [category: proxy.frame(in: .named(kanbanBoardCoordinateSpace))]
                )
            }
        }
        .background(columnSurface)
        .overlay {
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .fill(category.color.opacity(isActiveDropTarget ? 0.025 : 0))
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(isActiveDropTarget ? category.color.opacity(0.28) : .clear, lineWidth: 1.2)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if isActiveDropTarget && tasks.isEmpty {
                dropHintOverlay
                    .padding(.top, 52)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(isActiveDropTarget ? 1.006 : 1, anchor: .top)
        .shadow(color: category.color.opacity(isActiveDropTarget ? 0.10 : 0), radius: isActiveDropTarget ? 12 : 0, x: 0, y: isActiveDropTarget ? 6 : 0)
        .animation(reduceMotion ? .easeInOut(duration: 0.1) : .spring(response: 0.28, dampingFraction: 0.78), value: isActiveDropTarget)
        .onDrop(of: acceptedDropTypes, isTargeted: $isDropTargeted) { providers in
            onDrop(providers)
        }
        .onHover { isColumnHovered = $0 }
    }

    @ViewBuilder
    private func taskActionsMenu(for task: AgentTask, moveTargets: [KanbanCategory]) -> some View {
        Button {
            onOpenTask(task)
        } label: {
            Label("Open Task", systemImage: "arrow.right.circle")
        }
        .keyboardShortcut(.return, modifiers: [])

        if !moveTargets.isEmpty {
            Divider()

            ForEach(moveTargets) { target in
                Button {
                    onMoveTask(task, target)
                } label: {
                    Label(moveActionTitle(for: target), systemImage: target.icon)
                }
                .modifier(MoveShortcutModifier(category: target))
            }
        }

        Divider()

        Button(role: .destructive) {
            onDiscardTask(task)
        } label: {
            Label("Discard Task", systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: [])
    }

    private func moveActionTitle(for category: KanbanCategory) -> String {
        switch category {
        case .done:
            return TaskPresentationState.closeTaskActionTitle
        case .drafts:
            return "Move to Drafts"
        case .queued:
            return "Move to Queue"
        case .running:
            return "Move to Running"
        case .review:
            return "Send to Review"
        }
    }

    private var showsOverflowHint: Bool {
        tasks.count > overflowHintThreshold
    }

    private var overflowHintThreshold: Int {
        switch category {
        case .review:
            switch density {
            case .compact: return 3
            case .comfortable: return 4
            case .spacious: return 5
            }
        case .done:
            switch density {
            case .compact: return 2
            case .comfortable: return 3
            case .spacious: return 4
            }
        default:
            switch density {
            case .compact: return 4
            case .comfortable: return 5
            case .spacious: return 6
            }
        }
    }

    private var columnOverflowHint: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.clear,
                    Color(nsColor: .windowBackgroundColor).opacity(0.9)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 22)

            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(Stanford.ui(10, weight: .semibold))
                Text("Scroll for more")
                    .font(Stanford.caption(11).weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
        }
        .allowsHitTesting(false)
    }

    private var columnHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                KanbanColumnHeaderChip(category: category, count: tasks.count)
                Spacer()
                if let onClearAll, !tasks.isEmpty {
                    Button {
                        onClearAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(Stanford.ui(11))
                            .foregroundStyle(isTrashHovered ? Stanford.cardinalRed : Color.secondary.opacity(0.5))
                            .frame(width: 22, height: 22)
                            .background(isTrashHovered ? Stanford.cardinalRed.opacity(0.1) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .onHover { isTrashHovered = $0 }
                    .help("Delete all \(tasks.count) done task\(tasks.count == 1 ? "" : "s")")
                    .opacity(isColumnHovered ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isColumnHovered)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isTrashHovered)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle()
                .fill(Color.primary.opacity(KanbanBoardPresentation.columnStrokeOpacity))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard canCollapseEmptyState else { return }
            onCollapseEmptyState()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.displayTitle), \(tasks.count) \(tasks.count == 1 ? "task" : "tasks")")
        .accessibilityHint(category.accessibilityDescription)
    }

    private var dropHintOverlay: some View {
        HStack(spacing: 8) {
            Image(systemName: dropHintIcon)
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(category.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(dropHintTitle)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Release to update this task")
                    .font(Stanford.caption(10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: min(density.columnWidth(for: category) - 28, 260))
        .background(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(category.color.opacity(0.24), lineWidth: 1)
        )
    }

    private var emptyColumnPlaceholder: some View {
        VStack(spacing: isPersistentDropColumn ? 10 : 8) {
            Image(systemName: emptyIcon)
                .font(Stanford.ui(isPersistentDropColumn ? 15 : 18, weight: .medium))
                .foregroundStyle(isActiveDropTarget ? category.color : .secondary.opacity(0.75))
            Text(emptyTitle)
                .font(Stanford.caption(isPersistentDropColumn ? 13 : 12).weight(.medium))
                .foregroundStyle(isActiveDropTarget ? category.color : .secondary)
                .multilineTextAlignment(.center)

            if let emptySubtitle, !isActiveDropTarget {
                Text(emptySubtitle)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: emptyPlaceholderHeight)
        .padding(isPersistentDropColumn ? 12 : 8)
        .background(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .fill(
                    isActiveDropTarget
                        ? category.color.opacity(0.07)
                        : Color.primary.opacity(isPersistentDropColumn ? 0.012 : 0.014)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(
                    isActiveDropTarget
                        ? category.color.opacity(0.36)
                        : Color.primary.opacity(isPersistentDropColumn ? 0.045 : 0.052),
                    style: StrokeStyle(lineWidth: isActiveDropTarget ? 1.5 : 1, dash: isPersistentDropColumn ? [] : [5, 4])
                )
        )
        .padding(isPersistentDropColumn ? 10 : 8)
        .scaleEffect(isActiveDropTarget ? 1.018 : 1)
        .shadow(color: category.color.opacity(isActiveDropTarget ? 0.16 : 0), radius: isActiveDropTarget ? 12 : 0, x: 0, y: isActiveDropTarget ? 6 : 0)
        .animation(reduceMotion ? .easeInOut(duration: 0.1) : .spring(response: 0.28, dampingFraction: 0.82), value: isActiveDropTarget)
    }
}

private struct KanbanCountBadge: View {
    let count: Int
    let tint: Color

    var body: some View {
        Text("\(count)")
            .font(Stanford.caption(11).weight(.semibold))
            .foregroundStyle(count == 0 ? .secondary : tint)
            .padding(.horizontal, Stanford.sidebarBadgeHorizontalPadding)
            .frame(minWidth: Stanford.sidebarBadgeMinWidth, minHeight: Stanford.sidebarBadgeHeight)
        .background(tint.opacity(count == 0 ? 0.06 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.sidebarBadgeCornerRadius, style: .continuous))
            .accessibilityLabel("\(count) \(count == 1 ? "task" : "tasks")")
    }
}

private struct KanbanColumnHeaderChip: View {
    let category: KanbanCategory
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(category.color)
                .frame(width: 6, height: 6)

            Text(category.displayTitle)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(.primary)

            Text("\(count)")
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.displayTitle), \(count) \(count == 1 ? "task" : "tasks")")
    }
}

/// Compact trash target in the board toolbar. Replaces the old dashed
/// "Discard" column — that column implied a *state* the model doesn't have
/// (fixes M7 / §5 Discard in the design review). Drag-to-discard is preserved;
/// the column strip now only represents real task states.
struct KanbanDiscardToolbarTarget: View {
    let acceptedDropTypes: [UTType]
    let isGestureDropTarget: Bool
    /// False while a running task is being dragged — dim the target so the
    /// user sees the board's existing guard (running tasks can't be discarded).
    let canDropDraggedTask: Bool
    let onDeleteTask: (AgentTask) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var isDropTargeted = false

    private var isActiveDropTarget: Bool {
        (isDropTargeted || isGestureDropTarget) && canDropDraggedTask
    }

    var body: some View {
        Image(systemName: isActiveDropTarget ? "trash.fill" : "trash")
            .font(Stanford.ui(13, weight: .semibold))
            .foregroundStyle(isActiveDropTarget ? Stanford.cardinalRed : Color.secondary.opacity(0.62))
            .frame(width: 26, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActiveDropTarget ? Stanford.cardinalRed.opacity(0.12) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isActiveDropTarget ? Stanford.cardinalRed.opacity(0.55) : Color.primary.opacity(0.08),
                        style: StrokeStyle(
                            lineWidth: 1,
                            dash: isActiveDropTarget ? [] : [3, 3]
                        )
                    )
            }
            .opacity(canDropDraggedTask ? 1 : 0.36)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: KanbanUtilityDropFramePreferenceKey.self,
                        value: proxy.frame(in: .named(kanbanBoardCoordinateSpace))
                    )
                }
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isActiveDropTarget)
            .accessibilityLabel("Discard dropped task")
            .help("Drag a task here to discard it")
            .onDrop(of: acceptedDropTypes, isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, _ in
            let idString: String?
            if let data = item as? Data {
                idString = String(data: data, encoding: .utf8)
            } else if let string = item as? String {
                idString = string
            } else if let string = item as? NSString {
                idString = string as String
            } else {
                idString = nil
            }

            guard let idString, let uuid = UUID(uuidString: idString) else { return }

            DispatchQueue.main.async {
                let descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == uuid })
                guard let fetchedTasks = try? modelContext.fetch(descriptor),
                      let task = fetchedTasks.first else { return }
                onDeleteTask(task)
            }
        }
        return true
    }
}

// MARK: - Collapsed Kanban Lanes

/// Compact horizontal strip that lists every lifecycle lane currently sitting
/// empty. Replaces the previous per-lane stacked placeholder boxes (three
/// stacked boxes ate ~400pt of vertical space even when they contained
/// nothing). The strip sits above the column row so the active lanes keep
/// the full width of the board.
struct CollapsedKanbanLanesView: View {
    let categories: [KanbanCategory]
    let density: KanbanBoardDensity
    let onExpand: (KanbanCategory) -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Colon makes it explicit this is an inline label, not a
            // category itself. Hover hint clarifies that the capsules
            // below it are interactive (click to expand the lane).
            Text("Empty:")
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(.tertiary)
                .help("Lanes with no tasks. Click a capsule to expand it.")

            ForEach(categories) { category in
                Button {
                    onExpand(category)
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(category.color)
                            .frame(width: 6, height: 6)
                        Text(category.displayTitle)
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Expand \(category.displayTitle)")
                .accessibilityLabel("\(category.displayTitle), 0 tasks")
                .accessibilityHint("Expand empty column")
            }
        }
    }
}

// MARK: - Kanban Task Card

struct KanbanTaskCardView: View {
    let task: AgentTask
    let category: KanbanCategory
    let density: KanbanBoardDensity
    let showDetails: Bool
    var isDragPreview = false
    @State private var isHovered = false

    private var threadMessageLabel: String {
        // Keep Kanban card layout independent from the live TaskEvent
        // relationship. SwiftUI can render many cards during layout, and
        // materializing event faults here has crashed production SwiftData.
        Self.threadMessageLabel(for: KanbanBoardPresentation.cardThreadMessageFallbackCount(goal: task.goal))
    }

    static func threadMessageLabel(for count: Int) -> String {
        count == 1 ? "1 message" : "\(count) messages"
    }

    /// Outcome metadata for the Review / Closed lanes. The visual signal is the
    /// card's leading accent bar; this label remains available for VoiceOver.
    private struct OutcomeState {
        let label: String
        let color: Color
    }

    private var outcomeState: OutcomeState? {
        guard let label = Self.outcomeLabel(for: task.status) else { return nil }

        switch task.status {
        case .pendingUser:
            return OutcomeState(
                label: label,
                color: Stanford.pendingUser
            )
        case .completed:
            return OutcomeState(
                label: label,
                color: Stanford.completed
            )
        case .failed:
            return OutcomeState(
                label: label,
                color: Stanford.failed
            )
        case .cancelled:
            return OutcomeState(
                label: label,
                color: Stanford.cancelled
            )
        case .budgetExceeded:
            return OutcomeState(
                label: label,
                color: Stanford.failed
            )
        case .draft, .queued, .running:
            return nil
        }
    }

    private var showsOutcomeAccent: Bool {
        (category == .review || category == .done) && outcomeState != nil
    }

    /// Colour for the left accent bar on Review cards — the outcome colour
    /// when we know the terminal state, the column colour otherwise. The
    /// small slab of colour lets you spot a red/amber card in the lane
    /// without parsing the chip text.
    private var accentBarColor: Color {
        if category == .review, let state = outcomeState {
            return state.color
        }
        return category.color
    }

    private var titleBadge: String? {
        task.title
            .split(whereSeparator: \.isWhitespace)
            .lazy
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .first { token in
                token.contains("-")
                    && token.contains(where: \.isNumber)
                    && token.contains(where: \.isLetter)
                    && token == token.uppercased()
            }
    }

    private var displayTitle: String {
        Self.displayTitle(for: task.title, titleBadge: titleBadge)
    }

    static func displayTitle(for title: String, titleBadge: String? = nil) -> String {
        let base: String
        if let titleBadge, let badgeRange = title.range(of: titleBadge) {
            var stripped = title
            stripped.removeSubrange(badgeRange)
            base = stripped.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        } else {
            base = title
        }
        return Self.shortenIdentifierTokens(Self.deduplicatedRepeatedTitle(base))
    }

    static func deduplicatedRepeatedTitle(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count.isMultiple(of: 2), !trimmed.isEmpty else { return trimmed }

        let midpoint = trimmed.index(trimmed.startIndex, offsetBy: trimmed.count / 2)
        let firstHalf = String(trimmed[..<midpoint])
        let secondHalf = String(trimmed[midpoint...])

        guard firstHalf == secondHalf else { return trimmed }
        return firstHalf.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var metadataLine: String? {
        let parts = Self.metadataParts(
            titleBadge: titleBadge,
            showDetails: showDetails,
            category: category,
            status: task.status,
            threadMessageLabel: threadMessageLabel,
            relativeUpdatedAt: Formatters.relativeShort(task.updatedAt)
        )
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Middle-ellipsize identifier-like tokens (long, contain `. _ - /`) so
    /// the recognizable head and tail of the ID stay visible even when the
    /// title gets line-clipped. Normal prose is left alone (M5 in the review).
    static func shortenIdentifierTokens(
        _ text: String,
        maxTokenLength: Int = 28,
        keepEachSide: Int = 10
    ) -> String {
        Formatters.shortenIdentifierTokens(
            text,
            maxTokenLength: maxTokenLength,
            keepEachSide: keepEachSide
        )
    }

    static func outcomeLabel(for status: TaskStatus) -> String? {
        switch status {
        case .pendingUser:
            return "Needs input"
        case .completed:
            return "Run finished"
        case .failed:
            return "Run failed"
        case .cancelled:
            return "Cancelled"
        case .budgetExceeded:
            return "Budget hit"
        case .draft, .queued, .running:
            return nil
        }
    }

    static func metadataParts(
        titleBadge: String?,
        showDetails: Bool,
        category: KanbanCategory,
        status: TaskStatus,
        threadMessageLabel: String,
        relativeUpdatedAt: String
    ) -> [String] {
        var parts: [String] = []
        if (category == .review || category == .done), let outcome = outcomeLabel(for: status) {
            parts.append(outcome)
        }
        if let titleBadge {
            parts.append(titleBadge)
        }
        if showDetails {
            parts.append(threadMessageLabel)
        }
        if showDetails || category == .review || category == .done {
            parts.append(relativeUpdatedAt)
        }
        return parts
    }

    @ViewBuilder
    private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)

        if isDragPreview {
            shape
                .fill(Color.primary.opacity(0.04))
                .overlay {
                    shape.stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
        } else {
            shape
                .fill(Color.primary.opacity(
                    isHovered
                        ? KanbanBoardPresentation.cardHoverFillOpacity
                        : KanbanBoardPresentation.cardBaseFillOpacity
                ))
                .overlay {
                    shape.stroke(
                        Color.primary.opacity(
                            isHovered
                                ? KanbanBoardPresentation.cardHoverStrokeOpacity
                                : KanbanBoardPresentation.cardStrokeOpacity
                        ),
                        lineWidth: 1
                    )
                }
        }
    }

    var body: some View {
        let metadata = metadataLine
        VStack(alignment: .leading, spacing: metadata == nil ? 0 : 6) {
            Text(displayTitle)
                .font(Stanford.body(titleFontSize).weight(category == .done ? .medium : .semibold))
                .foregroundStyle(category == .done ? .secondary : .primary)
                .lineLimit(density.titleLineLimit)
                .fixedSize(horizontal: false, vertical: true)

            if let metadata {
                Text(metadata)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Formatters.fullDate(task.updatedAt))
            }
        }
        .padding(density.cardPadding)
        .padding(.leading, category == .review ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
        .overlay(alignment: .leading) {
            // Left accent bar. On Review cards we use the per-outcome
            // colour (amber/green/red/grey) so the kind of attention
            // needed reads before you even look at the chip text.
            // Running cards get the same bar in lagunita with a slow
            // pulse — visible "this is alive" without a heavy spinner.
            if category == .review {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accentBarColor)
                    .frame(width: 3)
                    .opacity(0.85)
            } else if task.status == .running {
                RunningPulseBar()
            }
        }
        // Closed cards are archived — drop contrast so they recede visually
        // and a glance at the board clearly distinguishes "active work" from
        // "already filed."
        .opacity(category == .done && !isDragPreview ? 0.72 : 1)
        .scaleEffect(isDragPreview ? 1.035 : 1)
        .shadow(color: Color.black.opacity(isDragPreview ? 0.22 : 0), radius: isDragPreview ? 22 : 0, x: 0, y: isDragPreview ? 14 : 0)
        .compositingGroup()
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !isDragPreview else { return }
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint("Double-tap to open. Drag to move between columns.")
        .accessibilityAddTraits(.isButton)
    }

    /// Card title size per lane. Review gets a slight bump (the column is
    /// wider and typically holds output worth reading); Closed is smaller to
    /// reinforce that those cards are archived.
    private var titleFontSize: CGFloat {
        switch category {
        case .review: return 14
        case .done: return 13
        default: return 14
        }
    }

    /// Screen-reader-friendly summary for the whole card. Combines category,
    /// outcome (when present), badge identifier, and the task title so the
    /// status is not encoded only by colour / column position.
    private var accessibilityLabelText: String {
        var parts: [String] = ["\(category.displayTitle) task"]
        if let state = outcomeState, showsOutcomeAccent {
            parts.append(state.label)
        }
        if let badge = titleBadge {
            parts.append("identifier \(badge)")
        }
        parts.append(displayTitle)
        return parts.joined(separator: ", ")
    }
}

/// Slow-pulsing 3pt vertical bar shown on the leading edge of cards
/// whose task is `.running`. Reads as "this is alive" without the heavy
/// chrome of a spinner — keeps the card surface calm while still
/// signalling activity at a glance.
///
/// Animation is plain SwiftUI (no `TimelineView`) — `easeInOut` between
/// 0.35 and 1.0 opacity on a 1-second loop with autoreverse. Cheap, no
/// state machine, stops when the view leaves the hierarchy.
private struct RunningPulseBar: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Stanford.running)
            .frame(width: 3)
            .opacity(reduceMotion ? 0.7 : (pulse ? 1.0 : 0.35))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { if !reduceMotion { pulse = true } }
            .accessibilityHidden(true)
    }
}
