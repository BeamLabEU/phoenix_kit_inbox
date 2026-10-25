# PR #8 — Fix open pages acting on a stale scope; attachment follow-ups F3–F9

**Author:** timujinne · **Merged:** 2026-10-25 · **Branch:** `fix/scope-changed-and-attachment-nits`
**Reviewer:** Claude · **Scope:** `access_events.ex`, `web/scope_refresh.ex`, `mailboxes.ex`, `identities.ex`, `external.ex`, `attachments.ex`, `messages.ex`, all five LiveViews, `test/support/{hooks,live_case}.ex`, tests

## Summary

Three parts. (1) Every page exports core's `phoenix_kit_scope_changed/1` and
recomputes its gates from the new scope, and `AccessEvents` tells open pages about
Inbox's own rows (grants, mailbox status/address, senders), which core cannot see.
(2) F3–F9 from the #2 review: withheld attachments shown without name or size,
snapshots cleaned up on raise/exit, Compose sending and saving in a detached task,
and tests for the guards and the old-core path. (3) The core pin goes to `~> 2.64`.

Checked against the code rather than the description:

- **The core contract holds.** Core attaches its refresh hook in
  `mount_phoenix_kit_current_scope/3`, so it runs on every authenticated live
  session, the user dashboard included. It calls `refresh_view_scope_assigns/1`
  (→ the page's callback) and then `scope_refresh_decision/4`. `was_admin?` comes
  from the scope from before the refresh, which is also the scope the page held,
  so `MySettingsLive.core_evicts?/2` matches core's `:evict_admin_area` branch.
  Holding `inbox` counts as admin-area access (`can_access_admin_area?/1` is true
  for any permission), so `:evict_admin_area` can't fire on an admin page that kept
  Inbox. InboxLive's `push_patch` after a lost grant therefore never collides with
  core's navigation. The test hook runs core's real decision after the page, which
  is what makes a double navigation fail the suite.
- **Every write that changes reach broadcasts, and only after the commit.** That
  covers grants, revokes (only when a row was deleted), create, archive, restore,
  `update_mailbox/3`, account deletion (the people who reached a mailbox are read
  before `hand_over/2` and told after the transaction) and every identity
  write. Refused writes broadcast nothing (tested). Payloads carry no data, so
  per-user topics leak nothing even if they were guessable.
- **The detached send survives the page.** I checked separately that work started
  with `Task.Supervisor.async_nolink` keeps running when its caller is killed
  (Elixir 1.19 / OTP 28). So the `start_async` task dying with the LiveView does
  not cut a send between its commit and the external part. `Task.await(task,
  :infinity)` turns a crash in the work into `{:exit, _}` for `handle_async/3`.
  The upload hard links are removed in an `after`.
- **The lock covers what the task works on.** `@locked_while_saving` refuses
  send, save, discard, mailbox switch, picker, chip removal and upload cancel, and
  `handle_info({:media_selected, _})` is ignored while saving. `validate` and
  `select_signature` stay open, which is harmless because the task's attrs are
  taken at click time. A refresh meanwhile only sets `@refresh_pending`, and
  `idle/1` runs it after the draft uuid is assigned.
- **Snapshot cleanup can't delete committed files.** `with_snapshots/2` and
  `snapshot_or_discard/4` discard on raise/exit through `release/1`, which re-reads
  the rows naming each file first. So even a raise after a commit keeps the
  message's files.
- **External subscriptions are diffed.** `follow_externals/1` subscribes to and
  unsubscribes from the difference between two MapSets. A topic is never
  subscribed twice (which would deliver duplicates), and the open mailbox is
  followed even when it is not listed (archived, opened by URL).
- It also closes the #7 review's NITPICK "a stale open Access panel still runs the
  colleague search after a demotion": a demotion is a `grant_access/4` to the
  viewer, which now broadcasts to them, and `recheck_grants_panel/1` closes the
  panel.

## Findings

### IMPROVEMENT - MEDIUM — the reading pane kept its attachment verdicts across a refresh (fixed)

F3 makes the reading pane ask the host's `attachment_policy` per row
(`Attachments.list_for_viewer/2`), and the policy gets the **scope**. But on a scope
refresh or access event, `InboxLive.reselect/1` re-read the open message and its
externals and left `@attachments` as computed at open time. So with a policy that
depends on roles or permissions, a viewer who lost access kept seeing the file's
name and size, and a viewer who gained it kept seeing "Attachment not available"
until they reopened the message. Downloads were never affected: the controller asks
the policy again. But the pane contradicted what F3 promises, and it broke
AGENTS.md's rule that a refresh recomputes everything derived from the gates.

**Fix:** `reselect/1` reassigns `@attachments` from `list_for_viewer/2` with the
refreshed scope. **Test:** `attachments_live_test.exs`, "an access change under an
open message": a policy answering by `inbox.send_external`, with the scope refreshed
up and back down. The pane flips from withheld to downloadable and back, and the
name is gone again at the end. The test fails without the fix. AGENTS.md's "What a
refresh does" now says so.

### NITPICK — Compose chips keep the verdict they were shown with (not fixed)

The same applies to a forward's or reopened draft's chips (`chips_for/2`, judged at
prefill). `refresh_sender/1` keeps `@attachments` as they are, by design ("keeps
the typed form and attachments"). Left alone because:

- the chips are always submitted and the send asks the policy, so nothing goes out
  that shouldn't;
- re-judging needs the message each chip came from, and chips don't keep it;
- after a revocation the name shown is one the user had already seen.

### NITPICK — a shared-sender change re-reads every open Compose page (not fixed)

Compose subscribes to the global senders topic. One edit to a shared sender makes
every connected Compose page run `assign_mailbox/2` in full:

- the mailbox list;
- the 200-entry recipient datalist, which doesn't depend on senders;
- signatures and Reply-To options;
- `list_usable/2`, with its integration checks.

Shared-sender edits are rare admin actions, so this was not narrowed. If it ever
matters, `refresh_sender/1` could skip `recipient_suggestions/1` on a
`:senders` event.

### NITPICK — lists that are not access-derived don't follow other admins' edits (not fixed)

`grant_access/4` tells only the holder. So admin A's open Access panel doesn't
show a grant admin B just gave user C on the same mailbox. `SettingsLive` doesn't
subscribe to the senders topic either. Neither list decides what the viewer may
do, and every write re-checks the stored row, so this is ordinary staleness. It is
outside what the PR set out to fix.

### NITPICK — the Inbox search form had no `id` (pre-existing, fixed)

`<form phx-change="search">` had no `id`. LiveView can't recover a form without one
after a reconnect, and LiveViewTest printed a `missing_form_id` warning for every
test that mounted Inbox. It now has `id="inbox-search-form"`. This predates the
PR; it was fixed here because every suite run showed it.

## Verification

- `mix test`: 705 tests, 0 failures (704 before, plus the test above).
- `mix precommit`: passes (`compile --force --warnings-as-errors`,
  `deps.unlock --check-unused`, `hex.audit`, `format --check-formatted`,
  `credo --strict`, dialyzer). The 5 dialyzer skips are the existing
  `.dialyzer_ignore.exs` entries.
- `mix gettext.extract --check-up-to-date` passes after re-extraction. The
  changes are source line references only, with no msgid added or lost.
