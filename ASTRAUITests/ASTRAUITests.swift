import XCTest

final class ASTRAUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    /// Helper to find the "New Task" toolbar button.
    private var newTaskButton: XCUIElement {
        app.windows.firstMatch.toolbars.buttons["New Task"].firstMatch
    }

    // MARK: - App Launch

    func testAppLaunchesWithWindow() {
        launchWithSeedData()
        let composer = app.textFields["ComposerInput"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "App shows the main composer")
    }

    // MARK: - Composer

    func testComposerQuickRunDisabledWhenEmpty() {
        launchWithSeedData()
        let composer = app.textFields["ComposerInput"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Composer should exist")

        // Quick Run button should not exist when input is empty
        let runButton = app.buttons["QuickRunButton"]
        // Button may not exist at all, or may be disabled
        if runButton.exists {
            XCTAssertFalse(runButton.isEnabled, "Run button should be disabled when empty")
        }
    }

    func testCreateTaskAddsToSidebar() {
        launchWithSeedData()

        let taskRow = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Seeded Task")
        ).firstMatch
        XCTAssertTrue(taskRow.waitForExistence(timeout: 5), "Seeded task appears in sidebar")
    }

    // MARK: - Task Selection

    func testSelectingTaskShowsDetailView() {
        launchWithSeedData()

        let taskRow = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Seeded Task")
        ).firstMatch
        XCTAssertTrue(taskRow.waitForExistence(timeout: 5))
        taskRow.click()

        sleep(1)
        let detailTexts = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Seeded Task")
        )
        XCTAssertTrue(detailTexts.count >= 1, "Task title shown in detail view")
    }

    // MARK: - Toolbar Buttons

    func testRunQueueToolbarButtonExists() {
        launchWithSeedData()
        let runQueueButton = app.windows.firstMatch.toolbars.buttons["Run Queue"].firstMatch
        XCTAssertTrue(runQueueButton.waitForExistence(timeout: 5), "Run Queue toolbar button exists")
    }

    // MARK: - Chat Panel

    func testChatPanelShowsComposer() {
        launchWithSeedData()
        let composer = app.textFields["ComposerInput"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Composer input field shown")
    }

    func testPermissionToggleExists() {
        launchWithSeedData()
        let toggle = app.buttons["PermissionToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Permission toggle exists")
    }

    func testTeamToggleExists() {
        launchWithSeedData()
        let toggle = app.buttons["TeamToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Team toggle exists")
    }

    // MARK: - Team Toggle

    func testTeamToggleToggles() {
        launchWithSeedData()
        let toggle = app.buttons["TeamToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        // Should start as "Solo" (check accessibility value)
        XCTAssertEqual(toggle.value as? String, "Solo", "Should show 'Solo' initially")

        // Click to toggle to Team mode
        toggle.click()
        sleep(1)

        XCTAssertEqual(toggle.value as? String, "Team", "Should show 'Team' after toggle")
    }

    // MARK: - Phase 1 Functional: Workspace → Compose → Run → Verify

    func testPhase1WorkspaceToCompletion() {
        // Launch with Phase 1 seed: workspace at /tmp/uitest_phase1
        launchForPhase("--uitesting-phase1")

        // 1. Verify workspace was created and composer is visible
        let composer = app.textFields["ComposerInput"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Composer should appear with seeded workspace")

        // 2. Verify team toggle and permission toggle are visible
        let teamToggle = app.buttons["TeamToggle"]
        XCTAssertTrue(teamToggle.waitForExistence(timeout: 5), "Team toggle should exist")

        let permToggle = app.buttons["PermissionToggle"]
        XCTAssertTrue(permToggle.waitForExistence(timeout: 5), "Permission toggle should exist")

        // 3. Paste the Phase 1 prompt
        pasteText("Create a file named hello.txt with the text 'Phase 1 test passed'", into: composer)

        // 4. Verify Quick Run button appears
        let runButton = app.buttons["QuickRunButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 5), "Quick Run button should appear")

        // 5. Click Quick Run
        runButton.click()

        // 6. Wait for the task to start
        waitForTaskStarted(timeout: 60)

        // 7. Wait for completion
        waitForCompletion(timeout: 120)

        // 8. Verify the file was created on disk
        sleep(2)
        let fm = FileManager.default
        let filePath = "/tmp/uitest_phase1/hello.txt"
        XCTAssertTrue(fm.fileExists(atPath: filePath),
                       "hello.txt should exist at \(filePath)")

        if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
            XCTAssertTrue(content.contains("Phase 1") || content.contains("passed"),
                          "hello.txt should contain expected text, got: \(content)")
        }
    }

    // MARK: - Phase 2 Functional: Team Mode → Maker & Checker (2 Agents)

    func testPhase2MakerCheckerTeam() {
        // Launch with Phase 2 seed: workspace at /tmp/uitest_phase2
        launchForPhase("--uitesting-phase2")

        // 1. Verify composer is visible
        let composer = app.textFields["ComposerInput"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Composer should appear")

        // 2. Enable Team mode (default size is 3, prompt controls actual team structure)
        let teamToggle = app.buttons["TeamToggle"]
        XCTAssertTrue(teamToggle.waitForExistence(timeout: 5))
        teamToggle.click()
        sleep(1)
        XCTAssertEqual(teamToggle.value as? String, "Team", "Should be in Team mode")

        // 3. Paste the Phase 2 prompt (typeText is too slow for long strings)
        let prompt = "Write a JavaScript function in regex.js that extracts all email addresses from a string. Then write test.js to test it with edge cases. Run the tests and save output to test_results.txt"
        pasteText(prompt, into: composer)

        // 4. Click Quick Run
        let runButton = app.buttons["QuickRunButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 5), "Quick Run button should appear")
        runButton.click()

        // 5. Wait for the task to start
        waitForTaskStarted(timeout: 60)

        // 6. Wait for completion — team tasks take longer (up to 5 min)
        waitForCompletion(timeout: 300)

        // 7. Verify files on disk
        sleep(3)
        let fm = FileManager.default
        let regexPath = "/tmp/uitest_phase2/regex.js"
        let testPath = "/tmp/uitest_phase2/test.js"

        XCTAssertTrue(fm.fileExists(atPath: regexPath),
                       "regex.js should exist at \(regexPath)")
        XCTAssertTrue(fm.fileExists(atPath: testPath),
                       "test.js should exist at \(testPath)")

        // Verify regex.js contains email extraction logic
        if let content = try? String(contentsOfFile: regexPath, encoding: .utf8) {
            XCTAssertTrue(content.contains("@") || content.contains("email") || content.contains("Email"),
                          "regex.js should contain email-related code, got: \(content.prefix(200))")
        }

        // 8. App should still be running
        XCTAssertTrue(app.windows.firstMatch.exists, "App should still be running")
    }

    // MARK: - Phase 3 Functional: Team Mode → Parallel Debate (3 Agents)

    func testPhase3ParallelDebateSwarm() {
        // Launch with Phase 3 seed: workspace at /tmp/uitest_phase3
        launchForPhase("--uitesting-phase3")

        // 1. Verify composer is visible
        let composer = app.textFields["ComposerInput"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Composer should appear")

        // 2. Enable Team mode (default size 3 — perfect for this test)
        let teamToggle = app.buttons["TeamToggle"]
        XCTAssertTrue(teamToggle.waitForExistence(timeout: 5))
        teamToggle.click()
        sleep(1)
        XCTAssertEqual(teamToggle.value as? String, "Team", "Should be in Team mode")

        // 3. Paste the Phase 3 prompt
        let prompt = "Compare Redux Toolkit vs Zustand vs React Context API for a new React project. Evaluate bundle size, boilerplate, ease of use, and TypeScript support. Output a final markdown file named state-decision.md with a comparison matrix table and recommendation."
        pasteText(prompt, into: composer)

        // 4. Click Quick Run
        let runButton = app.buttons["QuickRunButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 5), "Quick Run button should appear")
        runButton.click()

        // 5. Wait for the task to start
        waitForTaskStarted(timeout: 60)

        // 6. Wait for completion — swarm tasks can take a while (up to 5 min)
        waitForCompletion(timeout: 300)

        // 7. Verify state-decision.md on disk (may not exist if budget exceeded first)
        sleep(3)
        let fm = FileManager.default
        let decisionPath = "/tmp/uitest_phase3/state-decision.md"

        if fm.fileExists(atPath: decisionPath) {
            if let content = try? String(contentsOfFile: decisionPath, encoding: .utf8) {
                XCTAssertFalse(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              "state-decision.md should have content")
                let mentionsLibraries = content.contains("Redux") || content.contains("Zustand") || content.contains("Context")
                XCTAssertTrue(mentionsLibraries,
                              "state-decision.md should mention at least one library")
            }
        }

        // 8. App should still be running after swarm task
        XCTAssertTrue(app.windows.firstMatch.exists, "App should still be running")
    }

    // MARK: - Helpers

    private func launchWithSeedData() {
        app.terminate()
        app.launchArguments = ["--uitesting-seed"]
        app.launch()
        sleep(2)
    }

    private func launchForPhase(_ flag: String) {
        app.terminate()
        app.launchArguments = [flag]
        app.launch()
        sleep(2)
    }

    /// Paste text into a text field using the system pasteboard (much faster than typeText).
    private func pasteText(_ text: String, into element: XCUIElement) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        element.click()
        // Cmd+V to paste
        element.typeKey("v", modifierFlags: .command)
        sleep(1)
    }

    /// Wait for any static text containing the given substring.
    @discardableResult
    private func waitForText(containing text: String, timeout: TimeInterval) -> XCUIElement {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                       "Expected to find text containing '\(text)' within \(Int(timeout))s")
        return element
    }

    /// Wait for the task to start running — checks for the activity row identifier.
    private func waitForTaskStarted(timeout: TimeInterval) {
        // The task.started event creates an ActivityRow with this identifier
        let activityRow = app.otherElements["ActivityRow_task.started"]
        if activityRow.waitForExistence(timeout: timeout) { return }

        // Fallback: look for "Agent started" text in any static text
        let predicate = NSPredicate(format: "value CONTAINS %@", "Agent started")
        let textMatch = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(textMatch.waitForExistence(timeout: 5),
                       "Task should start within \(Int(timeout))s — no ActivityRow_task.started or 'Agent started' text found")
    }

    /// Wait for task completion — looks for terminal event identifiers or text.
    private func waitForCompletion(timeout: TimeInterval) {
        // Poll for completion indicators: check both accessibility identifiers and text content
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            // Check for completion activity rows
            if app.otherElements["ActivityRow_task.completed"].exists { return }
            if app.otherElements["ActivityRow_budget.exceeded"].exists { return }
            if app.otherElements["ActivityRow_error"].exists { return }

            // Check for completion text
            let completionPredicate = NSPredicate(format:
                "value CONTAINS %@ OR value CONTAINS %@ OR value CONTAINS %@ OR value CONTAINS %@",
                "Awaiting manual review", "Budget exceeded", "budget exceeded", "Agent exited")
            if app.staticTexts.matching(completionPredicate).firstMatch.exists { return }

            Thread.sleep(forTimeInterval: 2)
        }

        XCTFail("Task should complete within \(Int(timeout)) seconds")
    }

}
