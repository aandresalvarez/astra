import Foundation
import Testing
@testable import ASTRA

/// The pure presentation logic behind the rich native renderer: storage-table
/// sort/filter and form-field validation. The SwiftUI views are thin renderers over
/// these, so correctness is asserted here.
@Suite("Workspace App Renderer")
struct WorkspaceAppRendererTests {
    private func rows() -> [[String: WorkspaceAppStorageValue]] {
        [
            ["name": .text("Banana"), "qty": .integer(3)],
            ["name": .text("apple"), "qty": .integer(10)],
            ["name": .text("Cherry"), "qty": .null],
        ]
    }

    // MARK: - Table sort + filter

    @Test("ascending numeric sort orders by value and pushes empty/null last")
    func numericSortAscending() {
        let sorted = WorkspaceAppTablePresentation.displayRows(
            rows(), searchableColumns: ["name", "qty"], filter: "", sortColumn: "qty", ascending: true
        )
        #expect(sorted.map { WorkspaceAppStorageRowActionPresentationBuilder.displayValue($0["name"]) }
            == ["Banana", "apple", "Cherry"])  // qty 3, 10, null-last
    }

    @Test("descending numeric sort reverses, still pushing empties last")
    func numericSortDescending() {
        let sorted = WorkspaceAppTablePresentation.displayRows(
            rows(), searchableColumns: ["name", "qty"], filter: "", sortColumn: "qty", ascending: false
        )
        #expect(sorted.map { WorkspaceAppStorageRowActionPresentationBuilder.displayValue($0["name"]) }
            == ["apple", "Banana", "Cherry"])  // qty 10, 3, null-last
    }

    @Test("text sort is case-insensitive natural order")
    func textSortCaseInsensitive() {
        let sorted = WorkspaceAppTablePresentation.displayRows(
            rows(), searchableColumns: ["name"], filter: "", sortColumn: "name", ascending: true
        )
        #expect(sorted.map { WorkspaceAppStorageRowActionPresentationBuilder.displayValue($0["name"]) }
            == ["apple", "Banana", "Cherry"])
    }

    @Test("filter matches across columns, case-insensitively")
    func filterAcrossColumns() {
        let filtered = WorkspaceAppTablePresentation.displayRows(
            rows(), searchableColumns: ["name", "qty"], filter: "err", sortColumn: nil, ascending: true
        )
        #expect(filtered.count == 1)
        #expect(WorkspaceAppStorageRowActionPresentationBuilder.displayValue(filtered[0]["name"]) == "Cherry")
        // A numeric match in another column also counts.
        let byQty = WorkspaceAppTablePresentation.displayRows(
            rows(), searchableColumns: ["name", "qty"], filter: "10", sortColumn: nil, ascending: true
        )
        #expect(byQty.count == 1)
        #expect(WorkspaceAppStorageRowActionPresentationBuilder.displayValue(byQty[0]["name"]) == "apple")
    }

    @Test("empty filter + no sort returns rows unchanged")
    func passthrough() {
        let out = WorkspaceAppTablePresentation.displayRows(
            rows(), searchableColumns: ["name"], filter: "", sortColumn: nil, ascending: true
        )
        #expect(out.count == 3)
    }

    // MARK: - Form validation

    private func field(
        _ name: String,
        type: String = "text",
        required: Bool = false,
        readOnly: Bool = false
    ) -> WorkspaceAppFormFieldPresentation {
        WorkspaceAppFormFieldPresentation(
            name: name, label: name, fieldType: type,
            required: required, readOnly: readOnly, readOnlyReason: nil,
            choices: [], value: nil
        )
    }

    @Test("a required, empty field is flagged")
    func requiredMissing() {
        let errors = WorkspaceAppFormValidation.errors(
            fields: [field("title", required: true)],
            values: [:]
        )
        #expect(errors["title"] != nil)
    }

    @Test("number and date fields must parse")
    func typeValidation() {
        let fields = [field("count", type: "number"), field("due", type: "date")]
        let bad = WorkspaceAppFormValidation.errors(
            fields: fields,
            values: ["count": .text("abc"), "due": .text("2026-13-40")]
        )
        #expect(bad["count"] != nil)
        #expect(bad["due"] != nil)

        let good = WorkspaceAppFormValidation.errors(
            fields: fields,
            values: ["count": .text("12.5"), "due": .text("2026-06-19")]
        )
        #expect(good.isEmpty)
    }

    @Test("read-only fields are never flagged, even when required")
    func readOnlySkipped() {
        let errors = WorkspaceAppFormValidation.errors(
            fields: [field("locked", required: true, readOnly: true)],
            values: [:]
        )
        #expect(errors.isEmpty)
    }

    @Test("an optional empty field is valid")
    func optionalEmptyValid() {
        let errors = WorkspaceAppFormValidation.errors(
            fields: [field("notes")],
            values: [:]
        )
        #expect(errors.isEmpty)
    }

    // MARK: - Sandboxed HTML report (flexible local visualization)

    @Test("html report is CSP-locked, script-free, and escapes app data")
    func htmlReportIsSandboxed() {
        let html = WorkspaceAppWebReportHTML.html(
            title: "Items report",
            columns: ["name", "qty"],
            rows: [["name": .text("<b>Ann</b> & Bob"), "qty": .integer(2)]]
        )
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("default-src 'none'"))
        #expect(!html.lowercased().contains("<script"))
        // App data is escaped, never injected as markup.
        #expect(html.contains("&lt;b&gt;Ann&lt;/b&gt; &amp; Bob"))
        #expect(html.contains("<td>2</td>"))
    }

    @Test("html report renders an empty state with no data")
    func htmlReportEmptyState() {
        let html = WorkspaceAppWebReportHTML.html(title: "Report", columns: [], rows: [])
        #expect(html.contains("No data yet"))
        #expect(!html.contains("<table"))
    }

    @Test("a webView/htmlReport widget resolves to a sandboxed web report in the surface")
    func webViewWidgetBecomesWebReport() {
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "r", name: "R", description: "", archetypes: []),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "title", type: "text")
                ])
            ]),
            views: [WorkspaceAppViewSpec(id: "ov", type: "dashboard", title: "Overview", table: "items", widgets: [
                WorkspaceAppWidgetSpec(id: "rep", type: "webView", label: "Items report", table: "items", webRenderer: "htmlReport")
            ])],
            actions: [],
            permissions: WorkspaceAppPermissions(reads: [], writes: [], defaultMode: .draftOnly)
        )
        let snapshot = WorkspaceAppStorageTableSnapshot(
            name: "items",
            columns: ["id", "title"],
            rows: [["id": .text("1"), "title": .text("Hello")]],
            errorMessage: nil
        )
        let surface = WorkspaceAppNativeSurfaceBuilder.presentation(manifest: manifest, storageTables: [snapshot])
        #expect(surface.webReports.count == 1)
        #expect(surface.webReports[0].html.contains("Hello"))
    }
}
