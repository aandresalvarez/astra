# Downstream Sync Validation

Before adopting this repository into another GitHub repository, validate the
repository-owned process files against the target repository.

## Required Checks

1. Confirm `.github/CODEOWNERS` names accounts or teams that exist in the target
   repository and have write access. The current file intentionally uses
   concrete owners because GitHub CODEOWNERS does not support a repository-name
   variable.
2. Confirm `.github/workflows/ci.yml` job names match the branch-protection
   required status checks:
   - `Focused Swift tests`
   - `Whitespace`
3. Apply branch protection to the target repository with:

   ```bash
   script/configure_branch_protection.sh <owner/repo> main
   ```

   Omitting `<owner/repo>` uses the current checkout's GitHub remote. Pass the
   target repository explicitly during downstream adoption.
4. Re-read the resulting GitHub branch-protection page and confirm pull
   requests, code-owner review, stale-review dismissal, resolved conversations,
   required checks, force-push blocking, and branch deletion blocking are active.

## Current Upstream Defaults

This checkout's default CODEOWNERS owner is `@aandresalvarez`. When syncing into
`susom/astra`, replace that owner with the owning `susom` maintainer account or
team before applying protection there.
