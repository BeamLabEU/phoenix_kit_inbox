# PR #15 — `ComposeForm`: an embeddable compose form for a host's own pages

**Author:** timujinne · **Merged:** 2026-11-03 (`951c976`) · **Branch:** `pr/4-compose-form`
**Reviewer:** Claude · **Reviewed:** 2026-11-03 against `a8b57df` · **Scope:** `web/components/compose_form.ex`, the `attachments.ex` / `mail_explorer_hooks.ex` / `mix.exs` / `.gitignore` hunks, the four `compose_form_*_test.exs`; also Codex's follow-up in `a8b57df`

## Summary

`ComposeForm` is a LiveComponent a host puts on its own page. It keeps its own
state, sends through `ComposePipeline.run/4` under the module's task supervisor
with a watcher, and answers the page with `{:inbox_compose, id, …}`. That state
covers:

- recipient chips built from server-made suggestions;
- the sender and signatures;
- the host's files, picked files and the form's own uploads;
- a line above the button that previews the outside mail through the host's
  outbound filter.

Codex fixed account chips that showed an address other than the one the send
resolves. I reviewed the code as it stands on `main`, with the LiveView 1.2.13
source for uploads.

## Findings

### BUG - HIGH — Cancelling an upload a second time ended the host's page — fixed

`cancel_upload/3` on an entry with a live channel asks the channel to stop and
marks the entry `cancelled?: true`. The entry leaves `entries` only when the
channel's `:DOWN` reaches the page. Any second `cancel_upload` (or a consume) of
that entry before then calls a process that is gone. That exits the LiveView,
and the host's page goes with it.

It happened in the documented flow:

1. A letter with an upload is sent.
2. `finish_send/2` sends `{:sent, message}` to the page first, then cancels the
   sent uploads.
3. The host answers `{:sent, _}` with the next draft, as the moduledoc invites.
4. The component's `update/2` → `open_draft/2` → `drop_uploads(:all)` cancels
   the same entries again, before the `:DOWN`.

I reproduced it: the page died with
`exited in: GenServer.call(#PID<…>, :cancel, :infinity) ** (EXIT) no process`.
A new draft offered during the send (`open_pending_draft/1` after
`finish_send/2`) hit the same path within one `update/2`. A ✕ clicked twice
could too. The test "the file of one letter does not go with the next one"
missed it because it waits for the list to empty before handing the new draft.

**Fix:** `live_uploads/1,2` (entries not `cancelled?`) everywhere the form looks
at its uploads:

- `drop_uploads/2`, `limit_uploads/1` and `file_count/1`;
- the `cancel_upload` guard and the rendered list;
- the send's `collect_uploads/1`, which now consumes entry by entry with
  `consume_uploaded_entry/3` instead of `consume_uploaded_entries/3`, which
  would consume cancelled ones too.

**Test:** the test host can answer `{:sent, _}` with new attributes in the same
message (`{:test_on_sent, …}`). Upload, send, the host hands the next draft at
once; the page lives, and the next letter goes without the first one's file.
This failed against the merged code with the exit above.

**The same root in `ComposeLive`** (pre-existing, from the attachments PRs):

- Its `cancel_upload` handler cancelled any ref unconditionally. A ✕
  double-click, or a ref of no entry (`ArgumentError`), ended the page.
- `pending_uploads/1` / `clear_uploads/2` consumed cancelled entries.

Same fix, plus a test (two cancels of one ref and a forged one; the page lives).
It failed before the fix.

### BUG - MEDIUM — Every form's upload was called `:attachments`, so two on a page ended it — fixed

LiveView allows an upload name once per page, across the LiveView and all its
components. A second registration raises "existing upload for attachments
already allowed in another component". The form keeps postponed entries until
the send, so the name stays taken the whole time a letter is being written.

This crashed the page in two cases:

- two `ComposeForm`s on one page, after a file was chosen in each;
- a host page with an upload of its own called `:attachments`, a common name.

**Fix:** the upload is allowed on the first `update/2`, when the id is known, as
`"inbox_compose_<id>"`. `allow_upload/3` takes a string, so no atom is made per
id. `ComposeForm.upload_name/1` (`@doc false`) names it. Tests pass the new name
to `file_input/4`.

**Test:** two forms on one page, a file in each, each listed in its own form.
With the old fixed name it ended with the error above.

### IMPROVEMENT - MEDIUM — The host had no way to make the form re-read its senders — fixed

The form read its From options and signatures again only when `scope` changed.
Inbox's own access events change no scope: a grant revoked, a mailbox archived,
a sender added or changed. So a revoked mailbox stayed offered. The send still
refused it, so this was stale UI, not a bypass.

`MailExplorerHooks`' doc already told hosts to keep "a `ComposeForm` current",
but there was nothing to call. And a host refreshing with
`send_update(ComposeForm, id: id, scope: s)` emptied `recipient_sources` and
`attachment_picker`: an absent key became `nil`, then `[]`.

**Fix:**

- **`update(%{refresh: true}, socket)`** re-reads the senders and signatures
  (`assign_sender/2` + `refresh_summary/1`), as for a new scope.
- **An attribute left out of an update keeps its value** (`assign_list/3`).
- **The moduledoc says how:** subscribe with `ScopeRefresh.subscribe/2`, then
  `send_update(ComposeForm, id: id, refresh: true)`.
- **The explorer hook passes `{:inbox_access_changed, :mailboxes}` on to the
  page** after recording it. It used to consume it, so a page with an explorer
  could never refresh its form (see the PR #13 review).

**Tests:** a revoked mailbox leaves the choice on `refresh: true` under the same
scope; an update with only the scope keeps the host's sources. Both failed
against the merged code.

### IMPROVEMENT - MEDIUM — A refused pick left Send doing nothing — fixed

The sequence:

1. A line is full and the person picks one more from the host's list.
2. `add_entry/4` sets `recipient_error`; the field is empty.
3. On Send, `add_pending_input/1` skips everything while an error is set, and
   `submit` returns on the error.

The button looked enabled and nothing happened, however often it was pressed.

**Fix:** Send clears `recipient_error` first. Text still in a field is added
again by `add_pending_input/1` and refused again, so a typed recipient is still
never dropped silently.

**Test:** 20 in To, a pick from the host's list is refused, Send sends the 20.
This failed before.

### IMPROVEMENT - MEDIUM — The preview line could crash the page on a filter answer the send takes — fixed

`rewritten/2` did `email.to ++ email.cc ++ email.bcc` and matched
`{_name, address}` in the page process. `Outbound` takes a filter answer with a
`nil` list (`any_recipient/1` allows it), so a filter that leaves To unset and
puts everyone in Bcc worked for the send but crashed the form on every chip
change. Bare-string entries did too.

Now:

- a list is `List.wrap/1`ped;
- `{name, address}` and a bare address are both read;
- anything else makes the line say the outside mail "could not be checked"
  (`:unchecked`).

**Test:** three new test filters (`bcc_only`, `bare`, `odd_entry`).

### NITPICK — An upload could be cancelled under a running send — fixed

Where no hard link of its own can be made (another file system), the send reads
the upload's own temp file. Cancelling the entry meanwhile stops its channel and
deletes the file. `ComposeLive` already locks this. The form now ignores
`cancel_upload` while `@sending`, and the ✕ is disabled. Tested.

### NITPICK — Small items

- **Fixed: progress ticks no longer wipe a pick's refusal.** `limit_uploads/1`
  set `files_error: nil` on every tick; it now clears only its own "too many"
  message.
- **Fixed: AGENTS.md drift.** `refresh_summary/1` calls
  `ComposePipeline.effective_identity/3`, which can write an identity's
  `status` (its doc says so). AGENTS.md said only sends and `recheck/2` write
  it; now it names the form's sender line too.
- **Not changed: the pending draft after a lost send.** After `send_lost`, a
  later generic `update/2` opens the pending draft with a new key. The host
  offered that draft, and the page already warns the person to check the sent
  mail.
- **Not changed: one `access_level` query per shared mailbox in
  `from_options/1`.** This is bounded by the mailboxes the viewer holds.
- **Not changed: a host suggestion of `%{user: uuid}` with no label** shows
  "Unknown recipient" until resolved. The host gives a label.
- **Not changed: `RecipientSource.suggest_all/4` runs in the page process.** It
  is debounced to 300 ms, with sources under a timeout. A slow source holds the
  page for up to that timeout per query.

## Checked and correct

- **Double submit:** `sending` and `sent` are set in the same event, and the
  server guards them.
- **The send task:** runs under `Task.Supervisor.start_child`. Stale
  `send_result` / `send_lost` refs are dropped, and hard links are removed in
  the worker's `after`.
- **Browser input:** every value is resolved against server state — from key,
  signature, suggestion id, chip key, file key, role, upload ref, and pick UUIDs
  (cast, at most 50, host-authorized).
- **`update/2`** does no DB work unless the draft or scope changes (or the host
  asks for `refresh`).
- **Debounce and caps:** the suggest input is debounced, and lists are capped at
  8 and 30.
- **`mix.exs`** only adds doc groups; no path dependency ships.

## Verification (this batch: PRs #10–#15)

Run on 2026-11-03 against a private PostgreSQL 18 on loopback, because
`postgres-test` was rejecting connections in recovery. The test database was
recreated for the edited V07.

- Baseline before any change, published core 3.0.0: 1,294 tests, 0 failures,
  1 skipped.
- After the fixes, published core 3.0.0: **1,310 tests, 0 failures, 1 skipped**
  (the old-core case). Run twice, the second time after the last refactor.
- After the fixes, local core 3.2.6 (`e8d93343b` plus that checkout's
  uncommitted work), from a copy of this repository (`PHOENIX_KIT_PATH`, its
  own database, the working repository's lock untouched): **1,310 tests,
  0 failures, 1 skipped**.
  - A first local run, made while the Hex suite ran at the same time, failed
    "leaving the page while a send runs does not cut the send short". That test
    counts `phoenix_kit_inbox_upload_*` files in the shared system tmp dir, so
    another suite's in-flight send shows up there.
  - Alone, the file passed three times and the whole suite passed.
  - Recorded so the next reviewer does not run two suites at once.
- Every new regression test was run against the merged code and failed there,
  with three exceptions:
  - the NUL/invalid-UTF-8 one, which I confirmed with a probe (both calls raised
    `Postgrex.Error`);
  - the preview-shapes one, where `nil ++ list` raises;
  - the cancel-during-send lock.
- `mix gettext.extract --merge`: one new message, `%{name} (shared mailbox)`,
  translated for et and ru. No fuzzy or empty entries.
- `mix precommit` passes: compile with warnings as errors, unused deps, Hex
  audit, format, strict credo and dialyzer (its five existing suppressions,
  none added).
