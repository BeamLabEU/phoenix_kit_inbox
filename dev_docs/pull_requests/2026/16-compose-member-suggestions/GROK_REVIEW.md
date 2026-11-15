# PR #16 — Add a member_suggestions option to the compose form

**Author:** timujinne · **Merged:** `ad74aaf` (commits `9b76ca1`, `62a2974`, `1d3db4f`)
**Reviewer:** Grok · **Reviewed:** 2026-11-15 · **Verdict:** fixes applied
**Scope:** everything on `main` after the 0.5.0 tag (`c38f6e1`), with this PR's behaviour in `ComposeForm`. PRs #17 and #18 have their own notes. The floor raise (`06e0f90`), the lock updates (`3eaf7f9`, `9f80dbf`) and the ExDoc fix (`3abd9a0`) are covered here because they shipped with no PR.

## Summary

`ComposeForm` takes `member_suggestions`. A literal `false` drops `PhoenixKitInbox.RecipientSources.Members` from the typed suggestions. Anything else, or leaving the key out, keeps today's behaviour. The send path does not read the option, so hiding members widens nothing. Typing an address that is inside the application stays refused.

## Findings

### BUG - MEDIUM — The "offered" check did not use the send's recipient lookup — fixed

With members hidden, typing an internal address asks the host's sources again and says "choose them from the list" when one of them offers that person. The check compared an entry's `:user` with `Auth.get_user_by_email/1`.

That read is not the send's. `Messages.resolve_recipient_routes/2` goes through `Mailboxes.fetch_mailbox_by_recipient/2` (recipient circle, user before shared mailbox, `create: false`). `get_user_by_email/1` returns any user with that login. When the address is a shared mailbox and a non-member happens to have the same login, the check could name that non-member. It also missed the handle the suggestion list actually shows: Members, and a host source shaped the same way, offer `@username`, and a shared mailbox is offered by its slug. A host that copied the module's own source got the plain "cannot be added here" for a person who was in the list.

The keys now come from `fetch_mailbox_by_recipient/2` with `create: false`. An entry counts when its address is the typed address, that handle (or the shared mailbox's address or slug), or the account the lookup resolved. A source that searches by name alone still gets the plain message. Tests cover a handle in another case, a shared mailbox named by its slug, and the earlier address and account cases.

### IMPROVEMENT - MEDIUM — Changing `member_suggestions` threw away a list that was still valid — fixed

A change of the option set `list: nil`. That stopped a stale member id being picked, and it also closed the host's picker (which never lists members) and left a typed query on screen with no suggestions until the next keystroke, even when the host's sources still matched that query.

An open typed list is asked again for the same query under the new setting, so its ids belong to the sources now in force. A picker stays. Tests cover both, and turning the option back on.

### BUG - MEDIUM — The README still described a maintenance refusal the floor removed — fixed

`06e0f90` dropped `Maintenance.supported?/0` and the task's `:core_unsupported` exit. `Storage.delete_unreferenced_keys/1` became a direct call. The README still said the task needs `Storage.relink_file/3` and otherwise "says so and does nothing". A host following that would wait for a message the task no longer prints. The sentence now says the floor's core has both functions and the task uses them.

`relink_file/3` stays `apply/3`. A direct call makes dialyzer mark the "answer outside the spec" clause dead (`pattern_match_cov`), and that clause is what reports a wrong reply for the one record. `delete_unreferenced_keys/1` has no such clause, so its direct call is right. The attachments moduledoc and the pin test no longer describe `relink_file/3` as a lookup that degrades when the function is missing; `link_copy/3` and managed libraries stay run-time lookups so the test seams can stand in for a core without them.

### Verified from the earlier pass, and still right

- `mix.lock` no longer carries `:ex_aws_ec2`. Nothing in this package required it after core 3.6.0, and `deps.unlock --check-unused` is what stopped `mix precommit`.
- `test/core_pin_conformance_test.exs` admits `3.5.0` through `3.9.9` and rejects `2.64.0`, `3.4.9` and `4.0.0`. It skips when `PHOENIX_KIT_PATH` is set and fails on a committed path dep.
- The dead `link_copy/3` skip in `compose_filing_test.exs` and the `ShortCode` `Code.ensure_loaded?` guard in `attachments_linked_test.exs` are gone.

## Checked and fine

- The pipeline's route check does not read `member_suggestions`. An internal address is never stored as an outside one.
- Both refusal texts say the address is inside the application. The difference is whether the host's own source offers that recipient, which the same query would show in the list.
- Leaving the key out of a later update keeps the value. `nil` and `true` keep members.
- The new string is translated in `et` and `ru`.
- `mix docs` is not re-run here; the ExDoc fix (`c:RecipientSource.remember/4`, `put_gettext_locale` named without a missing arity) is a reference change only.

## Left as is

- A source that offers the person by display name only still gets the plain message. Matching that would mean resolving every entry. The moduledoc calls it best effort, and the refusal is the same either way.
- `offered?/2` waits on the sources the way a keystroke does (up to 1.5 seconds each). It runs only when the typed address is already internal.

## Gate

`mix precommit` is clean (compile `--warnings-as-errors`, unused deps, `hex.audit`, format, Credo `--strict`, dialyzer). `mix test`: 1339 tests, 0 failures.

## For the release (not done here)

Minor bump to **0.6.0**. No new migration. Upgrade note: PhoenixKit core **3.5.0** or later (was 2.64.0). Added: `member_suggestions` (#16), `own_upload` (#17), `footer_start` (#18). Removed: `Maintenance.supported?/0` and the task's "core cannot do it" exit.
