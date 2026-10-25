# PR #9 — Fix Compose missing the personal mailbox and two clipped labels

**Author:** timujinne · **Merged:** 2026-10-25 · **Branch:** `fix/compose-personal-mailbox-and-labels`
**Reviewer:** Claude · **Scope:** `web/compose_live.ex`, `web/inbox_live.ex`, gettext catalogues, `compose_live_test.exs`, `inbox_live_test.exs`; also the follow-up `94f40b3`

## Summary

Before this PR, Compose never created the personal mailbox. A user whose first
Inbox page was Compose was offered only their shared mailboxes, with one of them
as the default sender and its address as the Reply-To. `handle_params/3` now calls
`Mailboxes.ensure_user_mailbox/1`, as `InboxLive` does. Two labels that cut off
longer translations were also fixed.

Checked against the code:

- **Only with Inbox access.** The call sits in the `module_access` branch of
  `handle_params/3`. Since `94f40b3`, `ensure_personal_mailbox/1` also matches on
  `module_access: true` itself. A visitor without `inbox` gets no row (tested).
- **Idempotent and race-safe.** `ensure_user_mailbox/1` reads first. On a lost
  insert race against the partial unique index (`kind = 'user'`) it reads the
  winner's row back. It runs on the dead render too, as in `InboxLive`, which is
  harmless for the same reason. It broadcasts nothing, so calling it from a
  refresh cannot loop.
- **The personal mailbox becomes the default.** `list_accessible_mailboxes/1`
  orders `kind = 'user'` first, and `assign_mailbox/2` falls back to the first
  entry (tested: the personal mailbox is `option[selected]`).
- **The edge case the PR left open is closed.** The PR noted that a user who
  *gains* Inbox on an open Compose page would get the mailbox only on reload.
  `94f40b3` (right after the merge) makes `refresh_sender/1` call
  `ensure_personal_mailbox/1` too. `refresh_sender/1` is the path both core's
  refresh and Inbox's access events run. The test in `scope_refresh_test.exs`
  checks the row is created and selected.
- **Labels.** The "Unseen only" toggle drops daisyUI's `label` class. That is
  right: in v5, `.label` is `white-space: nowrap` and is meant as an addon inside
  `.input`/`.select`, not as a field label (see the umbrella's daisyUI 5 notes).
  The checkbox stays raw. It is a `phx-click` instant toggle with no `name`, which
  the umbrella's checkbox rules leave alone. The Compose row labels move from a
  fixed `w-16` to `min-w-24 shrink-0 whitespace-nowrap`.

## Findings

### NITPICK — the label tests assert class strings (not changed)

`refute html =~ "text-sm w-16 shrink-0"` and `label span.min-w-0.break-words`
guard the fix, but by its CSS, not its effect. A class rename that keeps the
layout would fail them. LiveViewTest can't measure layout, though, and the PR
reports a manual check at 390–1920 px, so they stay.

## Merge note

Merged on top of #8 in `b24e11d`. `compose_live.ex` conflicted: both sides were
kept (#8's scope refresh and this PR's `ensure_personal_mailbox/1`). The gettext
catalogues conflicted on line references only and were re-extracted. I checked the
merge result against both parents, and nothing from either side was lost.

## Verification

Covered by the run recorded in the PR #8 review: `mix test` 705 tests, 0 failures;
`mix precommit` passes.
