# PR #7 — Shared sender roles and mailbox settings

Reviewer: Codex. Rechecked on 2026-10-23 against `9610dc4`, including Claude's
review and merge follow-ups. This also records validation of the independent
rechecks of PRs #1–#6.

## BUG - HIGH — Concurrent role-only edits could combine allow-lists — fixed

Wrapping identity and role writes in a transaction did not serialize role-only
updates. When no identity field changed, Ecto skipped its UPDATE, so no identity
row lock was held. Starting from an empty role list, two editors could both
delete zero rows and then insert their different choices, yielding the union
rather than either requested replacement. Interleaving with mailbox binding
could also apply role changes using an obsolete binding.

`update_identity/3` now starts its transaction before fetching the identity and
locks that row with `FOR UPDATE`. Authorization, structural checks, field
updates and role replacement operate on that locked stored row.

A regression uses two actual database connections, pausing the first editor
between its DELETE and INSERT. The second must wait; after both finish its
chosen list must be the whole result. This test fails against the original
merged implementation and passes with the fix. Committed test fixtures and
the telemetry pause hook are cleaned up.

## BUG - HIGH — A demoted admin could reopen Access and load new grants — fixed

The previous review treated stale Access state as only a colleague-search
nitpick. `admin_of?/2` also trusted the mount-time mailbox list when reopening
the panel, so a demoted or revoked admin could load grants added **after** their
demotion. This exposed mailbox-specific membership, beyond ordinary compose
suggestions.

Opening Access now checks the stored mailbox with `authorize_scope/3` at admin
level. A search on a stale open panel rechecks that authorization and clears
the panel/candidates on denial. Regression tests cover reopening after a new
grant and searching after demotion; the original implementation fails both.

## BUG - MEDIUM — The Signatures panel trusted a stale admin grant — fixed

Its new button used the same cached access list before loading signatures.
Opening it now checks the stored active shared mailbox with
`Signatures.can_manage?/2`, including `inbox.manage_shared`. A regression checks
the stale button after demotion. Context-level write checks remain intact.

## BUG - MEDIUM — Colleague search rejected its advertised @username syntax — fixed

The picker hints “Name, @username or email”, but searched the stored username
with the leading `@` still present. Typing `@cora` found nobody even when `cora`
was an addressable colleague. Member searches now strip a leading `@` before
matching. The real access-panel search regression covers the typed handle as
well as bare names and excludes the other candidate.

## Confirmed and retained

The role allow-list narrows `inbox.send_external`, uses roles in effect from
the scope, and is enforced during identity resolution and external delivery.
Owner bypass, personal identities, bound identities, and the system nudge keep
their intended semantics. V06's prefix-safe tables, cascades and one-time seed
are unchanged; already shipped migrations were not edited. Settings form
whitelists and the all-unticked hidden input remain correct. The array checkbox
markup is appropriate here; the extra usable-identity query on an error path
does not need a separate optimization.

Removed AGENTS.md's obsolete raw-UUID grant-picker omission. Left the pushed
merge commit's attribution trailer intact: rewriting published history is
outside this fix. New commits contain no attribution trailer. No version or
CHANGELOG change, tag, or publication is part of this review.

## Final validation

- Baseline before fixes: `PHOENIX_KIT_PATH=../phoenix_kit mix test` — 611 tests,
  zero failures.
- Final full suite: `PHOENIX_KIT_PATH=../phoenix_kit mix test` — **627 tests,
  zero failures**, including the integration suites with real PostgreSQL and
  Storage. Sixteen additional tests, plus expanded picker-search coverage.
- `PHOENIX_KIT_PATH=../phoenix_kit mix precommit` — passes: warnings-as-errors
  compilation, unused-dependency check, Hex audit, format check, strict Credo
  and Dialyzer. Dialyzer uses the existing five suppressions, with none added.
- Hex-pinned core 2.63.0: `mix compile --force --warnings-as-errors` passes.
  Focused identity, role, mailbox-panel and compose suites: **119 tests,
  zero failures** there.
  Full attachment tests still require the newer local core; the compatibility
  fix makes the older core compile cleanly and still refuses unsupported
  attachment operations.
- `mix gettext.extract --merge` — 226 messages unchanged; only source references
  refreshed. Plural catalogue checks pass for Estonian and Russian.
- The concurrent-role regression was also run against the original merged
  implementation: it fails there and passes with the row lock.

The current local core requires newer `etcher`/`fresco` than the committed lock.
Local validation used a temporary dependency resolution; the committed lockfile
was restored afterwards. No dependency update is included.
