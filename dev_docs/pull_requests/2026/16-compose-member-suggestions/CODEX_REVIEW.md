# PR #16 — Compose member suggestions and review since Hex 0.5.0

**Author:** timujinne (Tymofii Shapovalov)
**Reviewer:** Codex · **Reviewed:** 2026-11-15
**Release baseline:** Hex `0.5.0`, git `c38f6e1`
**Reviewed through:** `81e65a7`

Reviewed every change in `0.5.0..81e65a7`, including previously reviewed
follow-ups. PR #16 merged as `ad74aaf`; PRs [#17](../17-compose-own-upload/CODEX_REVIEW.md)
and [#18](../18-compose-footer-start/CODEX_REVIEW.md) have separate records.
The Hex package API confirmed that 0.5.0 was the latest published release.

## Findings and fixes

### BUG - MEDIUM — Open suggestions outlived their sources and permissions

Changing `member_suggestions` rebuilt a typed list, but replacing
`recipient_sources`, changing `scope`, or sending `refresh: true` left the
previous entries and their server-issued IDs intact. A removed host source
could still supply a selectable recipient; a scope-sensitive source's old
results could remain visible after a role change. The host picker had the
same problem. Archiving a shared mailbox and refreshing the component also
left that mailbox offered.

The component now rebuilds an open list after its sources or scope change,
and after an access refresh. Each rebuild gives entries new IDs. Removing
all host sources closes their picker. Unrelated partial updates keep the
current list. The send pipeline still makes the final recipient and route
checks; source selection remains a presentation option.

Regression tests cover typed-source removal, picker-source removal, a scope
losing the permission a host source uses, and an archived shared mailbox.
Old suggestion IDs cannot add a recipient after removal.

### BUG - MEDIUM — Rebuilding suggestions ran before the access gate

A simultaneous scope revocation and `member_suggestions` change invoked
`resuggest/1` inside attribute assignment, before recalculating `allowed?`.
It asked host sources with a scope that could no longer open Inbox. A new
draft arriving in the same update could also cause an unnecessary lookup
against the preceding draft's context.

Attribute assignment is now side-effect free. Rebuilding happens after the
scope gate and draft update, and denial clears the old list. A regression
test observes the source callback and verifies that it is not called when
access is revoked while the option changes.

## Other changes since the release

- Checked the handle/account offer matching in `81e65a7` against the real
  `Mailboxes.fetch_mailbox_by_recipient/2` result shapes and
  `RecipientSource` normalization. The lookup is read-only (`create: false`),
  runs after the internal-route check, and does not broaden send access.
- The core requirement is now `>= 3.5.0 and < 4.0.0`. Removing the maintenance
  task's older-core guard is consistent with that floor. Snapshot linking
  and managed-library fallbacks still work through their test seams.
  No migration or schema changed.
- Reviewed the lock updates, removed version skips in attachment tests,
  core-pin conformance test, gettext catalogues, README and ExDoc references.
  No further defect found. No additional dependency changes were needed.

## Validation

- Baseline full suite: **1,339 tests, 0 failures**.
- Six initial regression cases failed before the fixes; their focused suite
  passed after the fixes. The additional access-gate regression passed too:
  **58 tests, 0 failures** across the recipient and upload test files.
- Final full suite, with PostgreSQL integration tests: **1,346 tests,
  0 failures** (seven new regression tests).
- `mix precommit`: **passed** — warning-free production compilation,
  no unused lock entries, clean Hex audit, formatting, strict Credo, and
  Dialyzer with the existing Ecto/Gettext exclusions (no unnecessary skips).
- `mix docs --warnings-as-errors`: **passed**.
- `git diff --check`: **passed**.

The test harness still emits its pre-existing module-redefinition and cache
service warnings, also present in the baseline run. Upload verification uses
LiveView integration tests plus inspection of the locked client's DOM-owner
routing; no browser end-to-end run was performed.

Version and changelog remain unchanged; this review does not publish a release.
