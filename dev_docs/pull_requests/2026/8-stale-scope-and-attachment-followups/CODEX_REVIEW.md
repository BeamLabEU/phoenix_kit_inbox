# PR #8 — Scope refresh and attachment follow-ups

Reviewer: Codex. Reviewed on 2026-10-27 against `2edaea5`, including the merged
PR, `94f40b3`, `fd7078f`, and Claude's review.

## Findings

No additional correctness defect found in this PR after its existing follow-ups.

Checked all five pages' scope callbacks, the context write sites that emit
access events, external subscription changes, and Compose's asynchronous
send/save lifecycle. Context authorization re-reads stored grants. A refresh
during work waits until the task completes, and a successful draft save assigns
its UUID before applying the pending refresh and reading attachment chips.
The supervised work owns upload hard links and survives its LiveView caller.
Snapshot cleanup on errors, exceptions and exits still consults attachment
references before deleting anything.

The reading-pane policy refresh added in `fd7078f` is present. Previously noted
limitations remain: existing Compose chips retain their display verdict until
reloaded, and another administrator's edits do not refresh every settings list.
Sending and downloading recheck authorization and attachment policy. These
display limitations do not justify expanding this access-control fix.

## Validation

Covered by both full suites and the quality gate recorded in the
[PR #11 review](../11-mail-files-library/CODEX_REVIEW.md). No version change or
release is part of this review.
