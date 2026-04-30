# Task Thread Performance Validation

Use the development channel only for this check.

## Scenario

1. Open `ASTRA Dev.app`.
2. Select or create a task with a long thread: at least 50 runs, 500 events, several expanded agent bubbles, and generated files in the task folder.
3. Start a Time Profiler capture while streaming output into the selected task.
4. During the capture, scroll the chat thread, expand and collapse agent activity, switch between Chat and Files, and filter the sidebar.

## Expected Shape

- `TaskThreadSnapshot.init` runs when task events or runs change, not once per rendered bubble.
- `TaskGeneratedFiles.filesAsync` does folder enumeration off the main actor and only refreshes when the task folder or latest-run file-change state changes.
- `SidebarTaskIndex.init` replaces repeated per-workspace scans during sidebar rendering.
- `MarkdownLinkifier.markdownAttributed` should appear less often on repeated renders because rendered blocks share a bounded attributed-string cache.

## Local Checks

```bash
swift test --filter ViewTests
swift test
./script/build_and_run.sh --verify
git diff --check
```
