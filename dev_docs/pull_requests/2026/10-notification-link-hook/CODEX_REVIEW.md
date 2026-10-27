# PR #10 — Notification link hook

Reviewer: Codex. Reviewed on 2026-10-27 against `2edaea5`.

## BUG - MEDIUM — Default and fallback links bypassed host routing — fixed

The hook correctly keeps a host's answer verbatim, but its default used
`Paths.raw_message_path/2`. On a host mounted at `/portal`, the notification
therefore opened `/admin/inbox?...` instead of `/portal/.../admin/inbox?...`.
It also missed localized paths and a configured admin segment. This default
predates the PR; the PR documents core's actual behavior without correcting it.

Checked both the published and local core implementations:
`PhoenixKit.Notifications.Render` returns metadata links verbatim, and the
notification bell follows them. AGENTS.md's claim that core prefixes these links
was stale and contradicted the PR's corrected `Paths` documentation.

The default now uses `Paths.message_path/3`, which applies core's route builder
with the locale already resolved for that reader. Nil, invalid and failing
hooks fall back to this same routed path. Valid host paths are still stored
exactly as returned. The raw helper remains available. README and AGENTS.md
now describe the verified contract.

Regression tests cover a host prefix, multilingual routing with a recipient
whose language differs from the sender's, nil/invalid/raising hooks, and a host
answer that already includes its prefix and locale. The prefix regression
failed before the fix. Existing tests retain per-reader shared-mailbox hooks
and refusal of external URLs, backslash authorities, control characters,
raises, throws and exits.

## Validation

See the [PR #11 review](../11-mail-files-library/CODEX_REVIEW.md) for both full
suites and the quality gate. Existing stored notifications are not rewritten;
the fix applies to newly emitted notifications.
