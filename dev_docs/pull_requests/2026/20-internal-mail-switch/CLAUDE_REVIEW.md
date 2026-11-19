# PR #20 — A switch for mail inside the application

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; one follow-up applied, and the catalogue merge
redone

Merged into `main` with a merge commit, after #19.

`inbox_internal_enabled` (`PhoenixKitInbox.internal_enabled?/0`) defaults to on when unset, through
`internal_mail_default`, so an upgrade keeps internal mail. With it off:
- Every email-shaped recipient is an outside address and is not looked up.
- A handle that names somebody inside is refused with `:internal_mail_disabled` before anything is written.
- The compose form, `ComposePipeline` and `RecipientSource` read `:internal` as `:email`.

Checked and fine:
- **The send path is the authority.** `deliver/5` reads the switch once per send, and `resolve_recipient_routes/2`
  uses the same `lookup_recipient/3`, so the preview and the send cannot disagree. An ambiguous handle is refused
  too, not reported as ambiguous, which is right: there is no inside route to choose.
- **The refusal comes first.** `refuse_internal_only/1` runs before `check_recipient_routes/2` and before any
  mailbox is created (`create: false` while off). A refused send writes nothing.
- **Message for a user without the outside right.** While off, such a user gets `:external_not_allowed`, not
  `{:unknown_recipients, …}`. A colleague they can see is not called "not found".
- **The toggle.** It sets the clicked state rather than flipping it, guards on `can_manage_shared`, and the failed
  save renews the element. The raw `toggle` input is correct: per the umbrella checkbox rules, a toggle is not
  migrated to `<.checkbox>`.
- **Tests and the node-wide setting.** Every test file that flips the setting is `async: false` (LiveCase's default,
  or explicit). ExUnit runs the sync modules after the async ones, so no concurrent test sees the switch off.
- **With #19.** While off, a member's address goes as an external email, so the sender's copy lands in Outbox and
  Compose navigates there. Nothing in the two PRs disagrees.

## Findings

### BUG - MEDIUM — The merge of #19 and #20 emptied the gettext catalogues (fixed before push)

The two PRs append to the same tail of `default.pot` and the en/et/ru `default.po`, as both PR descriptions warned.
My first resolution, a line-based union of the merge stages, wrote four empty files. A line union is also wrong for
PO files in general: where both sides end in the same lines, it keeps one copy and drops a `msgstr`.

The resolution I committed merges the catalogues by entry with Expo, keyed by `{msgctxt, msgid}`:
- #19's entries are kept;
- #20's new entries are added;
- the one msgid #20 reworded (the `inbox.manage_shared` description) is dropped in its old form.

`mix gettext.extract --merge` then normalised the references. Result: 332 entries, no untranslated `et`/`ru` string,
and `mix gettext.extract --check-up-to-date` is clean. Nothing broken was pushed: the bad merge commit was amended
before the push.

### IMPROVEMENT - MEDIUM — An open compose page did not follow the switch (fixed)

`ComposeLive` read `internal_enabled?/0` straight from the template (`identity_choices/1`, `to_placeholder/0`) and
from `default_identity/1`. A flip by an admin reached nobody. LiveView change tracking also never re-evaluates a
template call with no assigns in it, so even a re-render would have kept the old To hint and sender list.

A page open when the switch went off kept these until a reload:
- the "Inside the application only" sender, selected;
- the `@username` hint.

Its send then failed on the server's recheck (correctly), with no clue in the form. Turned back on, the page kept
offering no inside sender.

Fix:
- `set_internal_enabled/1` broadcasts `AccessEvents.senders_changed(nil)` after a saved change. This is the global
  senders topic every compose page already subscribes to, and it covers a host flipping the switch in code too.
- `ComposeLive` reads the switch as the `@internal_mail` assign, in `assign_mailbox/2`, the same re-read a refresh
  runs. The form, the sender choices and the To hint follow it.
- `keep_choices/1` counts a blank sender as not offered while off (when an identity exists), so it is replaced by
  the default and the reset is named in a flash.

New test in `web/compose_external_test.exs`: an open page loses the inside-only choice, selects the common sender
and shows the email-only hint when the switch goes off, and gets the inside-only choice back when it goes on. It
fails with the broadcast removed. `AccessEvents`' moduledoc, AGENTS.md and the README record the broadcast.

The embedded `ComposeForm` is left as it is. It is the host's component: a host that hears
`{:inbox_access_changed, _}` re-renders it, and its send rechecks the switch in `ComposePipeline`.

### NITPICK — `set_internal_enabled/1` takes no scope (left)

AGENTS.md asks every data-changing function to take the caller's `%Scope{}`. Module-level settings writers
(`set_external_enabled/1`, `set_email_nudges_enabled/1`) never have, and this one follows them. The page's
`can_manage_shared` guard is the check, and a forged-event test pins it. AGENTS.md says so explicitly.

## Gate

On the merged `main` with the follow-up: `mix precommit` (compile `--warnings-as-errors`, `deps.unlock
--check-unused`, `hex.audit`, format, `credo --strict`, dialyzer) — clean; full `mix test` — 1430 tests, 0 failures (1429 on the merge before the follow-up).
