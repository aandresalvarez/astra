# PR / CI Review Template

Template ID: `workspace-app.pr-ci-review`

Use this template when a workspace wants a compact App Studio surface for pull
request triage and CI status review.

## Intended Data

- Open pull requests for the current repository or an explicitly selected
  repository.
- Status check rollups and failing workflow details.
- Labels, reviewers, authors, and updated timestamps for queue scanning.

## Suggested Views

- PR Queue: sortable rows for pull requests that need attention.
- CI Review: grouped failing, pending, and passing checks.
- Detail drawer: file count, review state, branch, and direct GitHub link.

## Capability Provenance

This template references `github-workflow` so the user can see which capability
package it was designed around. The reference does not activate GitHub runtime
resources by itself.
