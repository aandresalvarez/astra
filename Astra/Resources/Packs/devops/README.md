# DevOps Pack

The DevOps pack is a bundled example vertical for repository operations. It is
deliberately a composition pack: it points ASTRA at existing core shelves,
existing capability packages, and App Studio template provenance without adding
new runtime permissions.

## Defaults

- Shows the Plan shelf and Files shelf by default.
- Hides Browser, Query, and App Preview unless the workspace or admin profile
  explicitly enables them.
- References the existing `github-workflow` capability package for pull
  request, issue, and CI vocabulary.

## Templates

- `pr-ci-review-template.md` describes the PR / CI Review workspace app shape.

Template capability package IDs are provenance only. A workspace must still
enable the referenced capability package before runtime resources such as `gh`
are made available to task launches.

## Inspecting The Example

Open `Workspace Settings > Packs`, reload if needed, and enable `DevOps Pack`.
The pack row should show:

- Shelves: Plan, Files
- Templates: PR / CI Review
- Capabilities: github-workflow
- Policies: No restrictions

After enabling it, App Studio should offer the PR / CI Review template for that
workspace. The GitHub workflow capability still needs to be enabled separately.
