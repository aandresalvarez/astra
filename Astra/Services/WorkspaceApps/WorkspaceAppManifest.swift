import Foundation

struct WorkspaceAppManifest: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var app: WorkspaceAppManifestMetadata
    var requirements: [WorkspaceAppRequirement]
    var storage: WorkspaceAppStorageSchema?
    var sources: [WorkspaceAppSource]
    var views: [WorkspaceAppViewSpec]
    var actions: [WorkspaceAppActionSpec]
    var automations: [WorkspaceAppAutomationSpec]
    var permissions: WorkspaceAppPermissions
    // Slice 5b: durable "submit blocked / needs review" reasons (e.g. a form field whose REDCap
    // branching ASTRA cannot honor exactly). Optional + nil-default so the fully-synthesized
    // Codable OMITS it for every existing manifest — digests stay byte-stable.
    var submitBlockedReasons: [String]?

    init(
        schemaVersion: Int = 1,
        app: WorkspaceAppManifestMetadata,
        requirements: [WorkspaceAppRequirement] = [],
        storage: WorkspaceAppStorageSchema? = nil,
        sources: [WorkspaceAppSource] = [],
        views: [WorkspaceAppViewSpec] = [],
        actions: [WorkspaceAppActionSpec] = [],
        automations: [WorkspaceAppAutomationSpec] = [],
        permissions: WorkspaceAppPermissions = WorkspaceAppPermissions(),
        submitBlockedReasons: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.requirements = requirements
        self.storage = storage
        self.sources = sources
        self.views = views
        self.actions = actions
        self.automations = automations
        self.permissions = permissions
        self.submitBlockedReasons = submitBlockedReasons
    }
}

struct WorkspaceAppManifestMetadata: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var icon: String
    var description: String
    var tags: [String]
    var archetypes: [String]

    init(
        id: String,
        name: String,
        icon: String = "square.grid.2x2",
        description: String = "",
        tags: [String] = [],
        archetypes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
        self.tags = tags
        self.archetypes = archetypes
    }
}

struct WorkspaceAppRequirement: Codable, Sendable, Equatable {
    var id: String
    var contract: String
    var minVersion: String?
    var operations: [String]
    var providerHint: String?
    var providerRequired: String?
    var dataClass: String?
    var optional: Bool
    var reason: String?

    init(
        id: String,
        contract: String,
        minVersion: String? = nil,
        operations: [String],
        providerHint: String? = nil,
        providerRequired: String? = nil,
        dataClass: String? = nil,
        optional: Bool = false,
        reason: String? = nil
    ) {
        self.id = id
        self.contract = contract
        self.minVersion = minVersion
        self.operations = operations
        self.providerHint = providerHint
        self.providerRequired = providerRequired
        self.dataClass = dataClass
        self.optional = optional
        self.reason = reason
    }
}

struct WorkspaceAppStorageSchema: Codable, Sendable, Equatable {
    var tables: [WorkspaceAppStorageTable]

    init(tables: [WorkspaceAppStorageTable] = []) {
        self.tables = tables
    }
}

struct WorkspaceAppStorageTable: Codable, Sendable, Equatable {
    var name: String
    var columns: [WorkspaceAppStorageColumn]

    init(name: String, columns: [WorkspaceAppStorageColumn]) {
        self.name = name
        self.columns = columns
    }
}

struct WorkspaceAppStorageColumn: Codable, Sendable, Equatable {
    var name: String
    var type: String
    var primaryKey: Bool
    var required: Bool

    init(name: String, type: String, primaryKey: Bool = false, required: Bool = false) {
        self.name = name
        self.type = type
        self.primaryKey = primaryKey
        self.required = required
    }
}

struct WorkspaceAppSource: Codable, Sendable, Equatable {
    var id: String
    var requirementRef: String?
    var operation: String?
    var mode: String
    var query: String?
    var projectRef: String?
    var tableRef: String?
    var sourceRef: String?

    init(
        id: String,
        requirementRef: String? = nil,
        operation: String? = nil,
        mode: String = "read",
        query: String? = nil,
        projectRef: String? = nil,
        tableRef: String? = nil,
        sourceRef: String? = nil
    ) {
        self.id = id
        self.requirementRef = requirementRef
        self.operation = operation
        self.mode = mode
        self.query = query
        self.projectRef = projectRef
        self.tableRef = tableRef
        self.sourceRef = sourceRef
    }
}

struct WorkspaceAppViewSpec: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var title: String?
    var table: String?
    var widgets: [WorkspaceAppWidgetSpec]
    // Slice 5b: a "form" view carries form fields (REDCap data-entry replacement). Optional
    // + defaulted so existing manifests + their digests are unaffected (same pattern as widgets).
    var formFields: [WorkspaceAppFormFieldSpec]

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case table
        case widgets
        case formFields
    }

    init(
        id: String,
        type: String,
        title: String? = nil,
        table: String? = nil,
        widgets: [WorkspaceAppWidgetSpec] = [],
        formFields: [WorkspaceAppFormFieldSpec] = []
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.table = table
        self.widgets = widgets
        self.formFields = formFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        table = try container.decodeIfPresent(String.self, forKey: .table)
        widgets = try container.decodeIfPresent([WorkspaceAppWidgetSpec].self, forKey: .widgets) ?? []
        formFields = try container.decodeIfPresent([WorkspaceAppFormFieldSpec].self, forKey: .formFields) ?? []
    }

    // Custom encode so an empty formFields is OMITTED — existing form-less manifests encode
    // byte-for-byte as before, keeping their digests (and Slice 3's revert digest check) stable.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(table, forKey: .table)
        try container.encode(widgets, forKey: .widgets)
        if !formFields.isEmpty {
            try container.encode(formFields, forKey: .formFields)
        }
    }
}

/// Slice 5b: a single field on a form view. Drives a draft-record input control, maps to a
/// local draft-table column, and submits through the declared write mode. `visibleWhen` carries
/// the field's raw REDCap branching logic and MUST be classified safe by
/// `WorkspaceAppREDCapBranchingAnalyzer` (the validator enforces this); unsupported branching is
/// dropped to `readOnly` + flagged by the builder rather than silently approximated.
struct WorkspaceAppFormFieldSpec: Codable, Sendable, Equatable {
    var name: String
    var label: String
    var fieldType: String          // text | textarea | number | date | choice | multichoice | yesno
    var required: Bool
    var choices: [WorkspaceAppFormChoice]?
    var visibleWhen: String?       // raw REDCap branching logic; must be 5a-safe when present
    var readOnly: Bool
    var readOnlyReason: String?    // why a field was forced read-only (unsupported branching / type)

    enum CodingKeys: String, CodingKey {
        case name, label, fieldType, required, choices, visibleWhen, readOnly, readOnlyReason
    }

    init(
        name: String,
        label: String,
        fieldType: String,
        required: Bool = false,
        choices: [WorkspaceAppFormChoice]? = nil,
        visibleWhen: String? = nil,
        readOnly: Bool = false,
        readOnlyReason: String? = nil
    ) {
        self.name = name
        self.label = label
        self.fieldType = fieldType
        self.required = required
        self.choices = choices
        self.visibleWhen = visibleWhen
        self.readOnly = readOnly
        self.readOnlyReason = readOnlyReason
    }

    // Lenient decode: only name/label/fieldType are required, so a model-generated field
    // missing the booleans/choices still decodes (untrusted output is validated afterward).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decode(String.self, forKey: .label)
        fieldType = try container.decode(String.self, forKey: .fieldType)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        choices = try container.decodeIfPresent([WorkspaceAppFormChoice].self, forKey: .choices)
        visibleWhen = try container.decodeIfPresent(String.self, forKey: .visibleWhen)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        readOnlyReason = try container.decodeIfPresent(String.self, forKey: .readOnlyReason)
    }
}

/// A selectable option for a `choice`/`multichoice` form field (a REDCap choice-list entry).
struct WorkspaceAppFormChoice: Codable, Sendable, Equatable {
    var value: String
    var label: String

    enum CodingKeys: String, CodingKey {
        case value, label
    }

    init(value: String, label: String) {
        self.value = value
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        // Fall back to the value when no display label is supplied.
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? value
    }
}

struct WorkspaceAppWidgetSpec: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var label: String
    var table: String?
    var field: String?
    var groupBy: String?
    var aggregation: String?
    var markdownContent: String?
    var diagramContent: String?
    var diagramKind: String?
    var webRenderer: String?
    var allowedActions: [String]
    var requiredAssets: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case label
        case table
        case field
        case groupBy
        case aggregation
        case markdownContent
        case diagramContent
        case diagramKind
        case webRenderer
        case allowedActions
        case requiredAssets
    }

    init(
        id: String,
        type: String,
        label: String,
        table: String? = nil,
        field: String? = nil,
        groupBy: String? = nil,
        aggregation: String? = nil,
        markdownContent: String? = nil,
        diagramContent: String? = nil,
        diagramKind: String? = nil,
        webRenderer: String? = nil,
        allowedActions: [String] = [],
        requiredAssets: [String] = []
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.table = table
        self.field = field
        self.groupBy = groupBy
        self.aggregation = aggregation
        self.markdownContent = markdownContent
        self.diagramContent = diagramContent
        self.diagramKind = diagramKind
        self.webRenderer = webRenderer
        self.allowedActions = allowedActions
        self.requiredAssets = requiredAssets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        label = try container.decode(String.self, forKey: .label)
        table = try container.decodeIfPresent(String.self, forKey: .table)
        field = try container.decodeIfPresent(String.self, forKey: .field)
        groupBy = try container.decodeIfPresent(String.self, forKey: .groupBy)
        aggregation = try container.decodeIfPresent(String.self, forKey: .aggregation)
        markdownContent = try container.decodeIfPresent(String.self, forKey: .markdownContent)
        diagramContent = try container.decodeIfPresent(String.self, forKey: .diagramContent)
        diagramKind = try container.decodeIfPresent(String.self, forKey: .diagramKind)
        webRenderer = try container.decodeIfPresent(String.self, forKey: .webRenderer)
        allowedActions = try container.decodeIfPresent([String].self, forKey: .allowedActions) ?? []
        requiredAssets = try container.decodeIfPresent([String].self, forKey: .requiredAssets) ?? []
    }
}

struct WorkspaceAppActionSpec: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var label: String?
    var requirementRef: String?
    var operation: String?
    var sourceRef: String?
    var table: String?
    var exportFormat: String?
    var targetURL: String?
    var clipboardText: String?
    var notificationTitle: String?
    var notificationBody: String?
    var taskTitle: String?
    var taskGoal: String?
    var approvalPrompt: String?
    var approvalDecisions: [String]
    var agentPrompt: String?
    var agentInputBindings: [String]
    var agentDecisions: [String]
    var agentPolicyMode: String?
    var agentTokenBudget: Int?
    var agentRequiresApproval: Bool
    var gateField: String?
    var gateOperator: String?
    var gateValue: WorkspaceAppStorageValue?
    var steps: [String]
    var maxIterations: Int?
    var timeoutSeconds: Int?
    var delaySeconds: Int?
    // Slice 9 Phase C composite/leaf action fields.
    var fanOutStep: String?       // task.fanOut: child task.createAndRun template (one task per bound row)
    var thenStep: String?         // gate.branch: step to run when the predicate passes
    var elseStep: String?         // gate.branch: step to run when the predicate fails (optional)
    var reduceStrategy: String?   // rows.reduce: count | sum | concat | first | last
    var reduceColumn: String?     // rows.reduce: row key to fold over

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case label
        case requirementRef
        case operation
        case sourceRef
        case table
        case exportFormat
        case targetURL
        case clipboardText
        case notificationTitle
        case notificationBody
        case taskTitle
        case taskGoal
        case approvalPrompt
        case approvalDecisions
        case agentPrompt
        case agentInputBindings
        case agentDecisions
        case agentPolicyMode
        case agentTokenBudget
        case agentRequiresApproval
        case gateField
        case gateOperator
        case gateValue
        case steps
        case maxIterations
        case timeoutSeconds
        case delaySeconds
        case fanOutStep
        case thenStep
        case elseStep
        case reduceStrategy
        case reduceColumn
    }

    init(
        id: String,
        type: String,
        label: String? = nil,
        requirementRef: String? = nil,
        operation: String? = nil,
        sourceRef: String? = nil,
        table: String? = nil,
        exportFormat: String? = nil,
        targetURL: String? = nil,
        clipboardText: String? = nil,
        notificationTitle: String? = nil,
        notificationBody: String? = nil,
        taskTitle: String? = nil,
        taskGoal: String? = nil,
        approvalPrompt: String? = nil,
        approvalDecisions: [String] = [],
        agentPrompt: String? = nil,
        agentInputBindings: [String] = [],
        agentDecisions: [String] = [],
        agentPolicyMode: String? = nil,
        agentTokenBudget: Int? = nil,
        agentRequiresApproval: Bool = false,
        gateField: String? = nil,
        gateOperator: String? = nil,
        gateValue: WorkspaceAppStorageValue? = nil,
        steps: [String] = [],
        maxIterations: Int? = nil,
        timeoutSeconds: Int? = nil,
        delaySeconds: Int? = nil,
        fanOutStep: String? = nil,
        thenStep: String? = nil,
        elseStep: String? = nil,
        reduceStrategy: String? = nil,
        reduceColumn: String? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.requirementRef = requirementRef
        self.operation = operation
        self.sourceRef = sourceRef
        self.table = table
        self.exportFormat = exportFormat
        self.targetURL = targetURL
        self.clipboardText = clipboardText
        self.notificationTitle = notificationTitle
        self.notificationBody = notificationBody
        self.taskTitle = taskTitle
        self.taskGoal = taskGoal
        self.approvalPrompt = approvalPrompt
        self.approvalDecisions = approvalDecisions
        self.agentPrompt = agentPrompt
        self.agentInputBindings = agentInputBindings
        self.agentDecisions = agentDecisions
        self.agentPolicyMode = agentPolicyMode
        self.agentTokenBudget = agentTokenBudget
        self.agentRequiresApproval = agentRequiresApproval
        self.gateField = gateField
        self.gateOperator = gateOperator
        self.gateValue = gateValue
        self.steps = steps
        self.maxIterations = maxIterations
        self.timeoutSeconds = timeoutSeconds
        self.delaySeconds = delaySeconds
        self.fanOutStep = fanOutStep
        self.thenStep = thenStep
        self.elseStep = elseStep
        self.reduceStrategy = reduceStrategy
        self.reduceColumn = reduceColumn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        requirementRef = try container.decodeIfPresent(String.self, forKey: .requirementRef)
        operation = try container.decodeIfPresent(String.self, forKey: .operation)
        sourceRef = try container.decodeIfPresent(String.self, forKey: .sourceRef)
        table = try container.decodeIfPresent(String.self, forKey: .table)
        exportFormat = try container.decodeIfPresent(String.self, forKey: .exportFormat)
        targetURL = try container.decodeIfPresent(String.self, forKey: .targetURL)
        clipboardText = try container.decodeIfPresent(String.self, forKey: .clipboardText)
        notificationTitle = try container.decodeIfPresent(String.self, forKey: .notificationTitle)
        notificationBody = try container.decodeIfPresent(String.self, forKey: .notificationBody)
        taskTitle = try container.decodeIfPresent(String.self, forKey: .taskTitle)
        taskGoal = try container.decodeIfPresent(String.self, forKey: .taskGoal)
        approvalPrompt = try container.decodeIfPresent(String.self, forKey: .approvalPrompt)
        approvalDecisions = try container.decodeIfPresent([String].self, forKey: .approvalDecisions) ?? []
        agentPrompt = try container.decodeIfPresent(String.self, forKey: .agentPrompt)
        agentInputBindings = try container.decodeIfPresent([String].self, forKey: .agentInputBindings) ?? []
        agentDecisions = try container.decodeIfPresent([String].self, forKey: .agentDecisions) ?? []
        agentPolicyMode = try container.decodeIfPresent(String.self, forKey: .agentPolicyMode)
        agentTokenBudget = try container.decodeIfPresent(Int.self, forKey: .agentTokenBudget)
        agentRequiresApproval = try container.decodeIfPresent(Bool.self, forKey: .agentRequiresApproval) ?? false
        gateField = try container.decodeIfPresent(String.self, forKey: .gateField)
        gateOperator = try container.decodeIfPresent(String.self, forKey: .gateOperator)
        gateValue = try container.decodeIfPresent(WorkspaceAppStorageValue.self, forKey: .gateValue)
        steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
        maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        delaySeconds = try container.decodeIfPresent(Int.self, forKey: .delaySeconds)
        fanOutStep = try container.decodeIfPresent(String.self, forKey: .fanOutStep)
        thenStep = try container.decodeIfPresent(String.self, forKey: .thenStep)
        elseStep = try container.decodeIfPresent(String.self, forKey: .elseStep)
        reduceStrategy = try container.decodeIfPresent(String.self, forKey: .reduceStrategy)
        reduceColumn = try container.decodeIfPresent(String.self, forKey: .reduceColumn)
    }
}

enum WorkspaceAppExpressionGateOperator: String, CaseIterable, Sendable {
    case exists
    case notExists
    case equals
    case notEquals
    case greaterThan
    case greaterThanOrEquals
    case lessThan
    case lessThanOrEquals

    static var allRawValues: Set<String> {
        Set(Self.allCases.map(\.rawValue))
    }

    static func requiresExpectedValue(_ rawValue: String) -> Bool {
        guard let value = Self(rawValue: rawValue) else { return false }
        switch value {
        case .exists, .notExists:
            return false
        case .equals, .notEquals, .greaterThan, .greaterThanOrEquals, .lessThan, .lessThanOrEquals:
            return true
        }
    }
}

struct WorkspaceAppAutomationSpec: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var enabledByDefault: Bool
    var action: String?
    var scheduleType: String?
    var intervalSeconds: Int?
    var dailyHour: Int?
    var dailyMinute: Int?
    var weeklyDayOfWeek: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case enabledByDefault
        case action
        case scheduleType
        case intervalSeconds
        case dailyHour
        case dailyMinute
        case weeklyDayOfWeek
    }

    init(
        id: String,
        type: String,
        enabledByDefault: Bool = false,
        action: String? = nil,
        scheduleType: String? = nil,
        intervalSeconds: Int? = nil,
        dailyHour: Int? = nil,
        dailyMinute: Int? = nil,
        weeklyDayOfWeek: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.enabledByDefault = enabledByDefault
        self.action = action
        self.scheduleType = scheduleType
        self.intervalSeconds = intervalSeconds
        self.dailyHour = dailyHour
        self.dailyMinute = dailyMinute
        self.weeklyDayOfWeek = weeklyDayOfWeek
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        enabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? false
        action = try container.decodeIfPresent(String.self, forKey: .action)
        scheduleType = try container.decodeIfPresent(String.self, forKey: .scheduleType)
        intervalSeconds = try container.decodeIfPresent(Int.self, forKey: .intervalSeconds)
        dailyHour = try container.decodeIfPresent(Int.self, forKey: .dailyHour)
        dailyMinute = try container.decodeIfPresent(Int.self, forKey: .dailyMinute)
        weeklyDayOfWeek = try container.decodeIfPresent(Int.self, forKey: .weeklyDayOfWeek)
    }
}

struct WorkspaceAppPermissions: Codable, Sendable, Equatable {
    var reads: [String]
    var writes: [String]
    var externalWrites: [String]
    var defaultMode: WorkspaceAppPermissionMode

    init(
        reads: [String] = [],
        writes: [String] = [],
        externalWrites: [String] = [],
        defaultMode: WorkspaceAppPermissionMode = .readOnly
    ) {
        self.reads = reads
        self.writes = writes
        self.externalWrites = externalWrites
        self.defaultMode = defaultMode
    }
}
