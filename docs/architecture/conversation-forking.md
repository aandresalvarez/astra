# Conversation Forking

ASTRA conversation forks preserve task history through a selected completed run. They are not Git branches and must not create, switch, commit, push, or publish repository branches.

## User-visible modes

- **Shared files** copies the conversation checkpoint while retaining references to the same files. Changes to those files are visible from both conversations.
- **Independent file copies** snapshots explicit task inputs, message attachments, checkpoint outputs, and checkpoint artifacts into the fork task folder. ASTRA never recursively copies a directory; directory inputs remain shared references.

Git-backed workspaces only allow the shared-files mode. The confirmation sheet shows the repository, branch, commit, and dirty state. A dirty worktree requires explicit acknowledgement. If another task is running against the same Git worktree, the fork remains readable but cannot send or resume provider work until that run releases the worktree.

## Persistence contract

The fork manifest is written before SwiftData objects are inserted. It records provenance, mode, repository context, SHA-256 values, and source-to-local file mappings. A manifest failure removes the prepared task folder and creates no fork. A persistence failure deletes both the inserted model graph and prepared task folder.

Provider session identifiers and task-scoped permission grants are intentionally reset. Run history, deterministic event history, task configuration, and checkpoint-scoped source references are copied. Events attached to copied runs remain included even when their timestamp is later than the run completion timestamp; unscoped events are limited by the checkpoint cutoff.
