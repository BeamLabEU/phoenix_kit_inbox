# PR #6 — Mailbox switcher

Reviewer: Codex. Rechecked on 2026-10-23 against `9610dc4` and Claude's review.

No additional defect found in this PR. The sidebar select is inside the form
that owns `phx-change="select_mailbox"`; its field name matches the handler and
the resulting URL goes through mailbox authorization. The existing regression
drives the form element and asserts the patched mailbox/folder URL.

Related navigation issues found during the broader review were in preexisting
access/state handling, recorded and fixed with
[PR #1](../1-scoped-access-and-recipients/CODEX_REVIEW.md).

Final validation is in [PR #7](../7-shared-mail-roles/CODEX_REVIEW.md).
