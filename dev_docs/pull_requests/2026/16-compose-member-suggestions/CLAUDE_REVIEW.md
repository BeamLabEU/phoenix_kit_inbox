# PR #16 — Add a member_suggestions option to the compose form

**Author:** timujinne · **Branch:** `feat/compose-member-suggestions` (3 commits: `9b76ca1`, `62a2974`, `1d3db4f`; merged as `ad74aaf`)
**Reviewer:** Claude · **Reviewed:** 2026-11-15 · **Verdict:** approve, no code change needed
**Scope:** `web/components/compose_form.ex`, `README.md`, gettext catalogues, `test/phoenix_kit_inbox/web/compose_form_recipients_test.exs`

This review also covers the commits on `main` since the 0.5.0 Hex release
that came with no PR: the core floor raise (`06e0f90`), the two lock updates
(`3eaf7f9`, `9f80dbf`) and the ExDoc fix (`3abd9a0`). PRs #17 and #18 have
their own reviews next to this one.

## Summary

`ComposeForm` takes `member_suggestions`. A literal `false` drops
`PhoenixKitInbox.RecipientSources.Members` from the typed suggestions
(`all_sources/1`), so a host embedding the form for one object offers only its
own `recipient_sources`. Anything else, or leaving it out, keeps the old
behaviour; an update without the key keeps the value it had. A change of
the value drops the open list (`list: nil`), so a suggestion id made under
the other setting cannot be picked after it.

Typing the address of someone inside stays refused, as before, because the
pipeline would refuse the send. With members hidden the refusal says "choose
them from the list" only when a host source offers that address
(`offered?/2`: the sources are asked again with the address as the query,
and an entry counts when it carries the address or names the account
that owns it). Otherwise it says "That address is inside this application and
cannot be added here." The new string is translated in `et` and `ru`.

## Checked and fine

- **Send-side checks unchanged.** The option affects only `all_sources/1`,
  which is called by `suggest/3` and `offered?/2`. The pipeline's route check
  (`resolve_recipient_routes`, `check_recipient_routes`) does not read it, so
  hiding the members widens nothing.
- **No new disclosure.** `offered?/2` runs only after `internal?/2` has already
  said the address is inside the recipient circle, and both outcomes say so.
  The two messages differ only by whether the *host's* source offers the
  address, which the viewer could find out by typing it into the suggestions.
  `Auth.get_user_by_email/1` is used only to compare against a host entry's
  `:user`, never shown.
- **Case.** `phoenix_kit_users.email` is `citext` (checked on the test DB),
  so the lookup of the downcased address finds a mixed-case login. The
  address comparison is downcased on both sides.
- **Entry shape.** `RecipientSource.normalize/1` keeps only `:user` when a
  source gives both `:user` and `:address`, so the first-match `fn` in
  `offered?/2` (address clause, then user clause) never compares an address
  while skipping the user of the same entry.
- **The picker button** (`toggle_picker`) lists `recipient_sources` only, and
  always did, so the option does not affect it.
- **A host that lists `Members` in its own `recipient_sources`** gets members
  back with `member_suggestions={false}`. That is the host's explicit choice
  and is consistent with "only the host's sources".

## Findings

### NITPICK — A host source that offers the person by handle gets the plain message — not fixed

With members hidden, typing `alice@example.com` while the host's source
offers that person as `%{address: "@alice"}` gives "inside this application"
rather than "choose them from the list". The source matches neither the
address nor (no `:user`) the account. The moduledoc already calls the check
"best effort, the refusal is the same", and resolving every offered entry
through the recipient lookup to compare mailboxes would cost a query per
entry while typing. Left as is.

## Commits since 0.5.0 without a PR

### `06e0f90` — core floor 3.5.0

The pin goes from `>= 2.64.0 and < 4.0.0` to `>= 3.5.0 and < 4.0.0`. The
maintenance task's `supported?/0` / `:core_unsupported` path is gone and
`Storage.delete_unreferenced_keys/1` is a direct call. `link_copy/3` and the
managed-library calls are still looked up at run time, through the
`:storage_module` / `:storage_libraries` test seams. That is correct: the
seams stand in for cores without them.

**Verified against the floor itself.** In a scratch copy pinned to
`phoenix_kit == 3.5.0`, `MIX_ENV=test mix compile --warnings-as-errors` is
clean and the full suite passes (1334 tests, 0 failures, same as on the locked
3.6.0). So nothing in `lib/` calls a function that only 3.6 has.

#### IMPROVEMENT - MEDIUM — No core-pin conformance test — added

The floor commit says the "pin-conformance … tests follow the new floor", but
this repo never had one. Every sibling module carries
`test/core_pin_conformance_test.exs`, and the workspace AGENTS.md says to copy
it into each module. Added it here, with the same admit/reject lists and the
floor's reason. It skips when `PHOENIX_KIT_PATH` is set (`pk_dep/3` then
yields a path dep with no requirement), and fails on a committed path dep.

#### NITPICK — Two core-version guards left in tests — removed

The floor commit removed the run-time skips from five test files but missed
two:

- `web/compose_filing_test.exs` still had a `@moduletag skip:` for cores
  without `link_copy/3` or managed libraries. No admitted core lacks them, so
  it was dead and its moduledoc was wrong.
- `attachments_linked_test.exs` still guarded `ShortCode` with
  `Code.ensure_loaded?/1` ("core 2.65+"). It now always sets the short code.

### `3eaf7f9`, `9f80dbf` — lock updates

`mix hex.outdated` shows every dependency at its latest: `phoenix_kit` 3.6.0,
`phoenix_kit_emails` 0.10.0 (test only), `phoenix_live_view` 1.2.13.

#### BUG - MEDIUM — `9f80dbf` left an unused lock entry, failing the gate — fixed

`mix precommit` failed at `deps.unlock --check-unused`, because
`:ex_aws_ec2` was in `mix.lock` and nothing required it any more. Core 3.6.0
no longer pulls it in. The tests passed anyway, so only the gate showed it,
and a release from that tree would have stopped at step 3 of the checklist.
`mix deps.unlock --unused` removed it.

### `3abd9a0` — ExDoc references

`mix docs` builds with no warning from this package.

## For the release (not done here)

This is a minor bump to **0.6.0**: new `ComposeForm` options and a raised
core floor. The CHANGELOG entry should cover:

- **Upgrade note:** requires PhoenixKit core **3.5.0** or later (was 2.64.0).
  No new migration.
- **Added:** `member_suggestions` (#16), `own_upload` (#17) and the
  `footer_start` slot (#18) on `ComposeForm`.
- **Removed:** the maintenance task's "core cannot do it" exit and
  `Maintenance.supported?/0`, since no admitted core lacks `relink_file/3`.

## Gate

`mix precommit` is clean. `mix test`: 1335 tests, 0 failures (the 1334 above
plus the new pin test).
