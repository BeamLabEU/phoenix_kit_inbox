# PR #9 — Personal mailbox creation and labels

Reviewer: Codex. Reviewed on 2026-10-27 against `2edaea5`, including `94f40b3`
and Claude's review.

## Findings

No additional correctness defect found. Compose ensures the personal mailbox
only after checking Inbox access, both on navigation and when access is gained
on an open page. The context's unique-index conflict recovery keeps this
idempotent under concurrent first visits. Sendable mailboxes put the personal
one first, while an explicitly requested writable shared mailbox is retained.

The merged result retains PR #8's refresh handling. The label changes keep
translations from being forced into the previous fixed-width columns, and the
unseen checkbox remains an instant toggle without a form field name. No
component migration is needed for that control.

## Validation

The full suites cover initial Compose visits, denied access, gaining access,
mailbox selection, and the existing label regressions. Suite and gate results
are recorded in the [PR #11 review](../11-mail-files-library/CODEX_REVIEW.md).
