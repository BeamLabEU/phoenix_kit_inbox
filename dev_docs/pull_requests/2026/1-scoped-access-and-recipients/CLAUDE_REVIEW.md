# PR #1 — Access checks inside the contexts, @username addressing, a recipient circle, and mail that survives user deletion

**Author:** timujinne · **Merged:** 2026-10-21 (`21eda99`) · **Branch:** `feat/scoped-access-and-recipients`
**Reviewer:** Claude · **Scope:** `mailboxes.ex`, `members.ex`, `messages.ex`, `notify.ex`, `migrations/v02.ex`, `web/{inbox,compose,mailboxes}_live.ex`

Reviewed at the head of `main` after PR #5, so findings are against the code as it stands, attributed to the PR that introduced it.

## Summary

The load-bearing idea is right and consistently applied: every mutating context
function takes the caller's `%Scope{}` and re-reads the mailbox
(`Mailboxes.authorize_scope/3`), reads are scoped through the delivery
(`fetch_for_mailbox/2`), and a hand-built struct grants nothing. Bcc is filtered
in all three places it can leak (`recipient_snapshot/2`, `list_recipients/2`,
`External.list_for_viewer/2`). V02 finds its foreign keys in the catalog by
table, column and schema rather than by name, refuses on duplicate shared
addresses instead of picking a winner, and `down/1` refuses rather than losing
ownerless mailboxes. The `parent_uuid` read check (`readable_by?/2`) closes the
"reply into someone else's thread" hole.

Four things to fix, three to record.

## Findings

### BUG - MEDIUM — `toggle_grants` was not gated, and a non-uuid crashed the page — **fixed**

`MailboxesLive.handle_event("toggle_grants", …)` called `Mailboxes.list_grants/1`
for whatever uuid the browser sent. The button is drawn only for `"admin"`, but
the event was open: a `read` or `write` grantee could fire it for their own row
and get the panel listing every grantee's user uuid and level
(`list_grants/1` documents that it takes a mailbox the caller has already
authorized — this caller had not). A string that is not a uuid reached
`where: g.mailbox_uuid == ^uuid` and raised `Ecto.Query.CastError`, taking the
LiveView down.

Fix: `admin_of?/2` checks the uuid against the page's own mailbox list with
`access == "admin"` before loading anything; anything else is a no-op. The
existing "forged admin events" tests relied on the open event to get a panel to
refuse *from*; they now model the real stale-page case instead (the user is
demoted while the panel is open), which is the scenario the context checks
exist for. New tests: a write grantee's forged toggle lists nobody, a non-uuid
does nothing, an admin still sees the grants.

### IMPROVEMENT - MEDIUM — `%` and `_` in a search term were wildcards — **fixed**

`Messages.maybe_search/2` and `Mailboxes.filter_by_term/3` interpolated the
trimmed term straight into an `ILIKE` pattern. Searching `50%` matched every
message containing `50`; a lone `_` or `%` matched everything. Not an injection
(the pattern is a bound parameter) but the result is wrong, and the recipient
suggestion list inherits it. Both now escape `\`, `%` and `_`. Tests cover both
paths.

### NITPICK — dead `search_mailboxes/3` clause — **removed**

`def search_mailboxes(_, _, _), do: []` sat alone after `filter_by_term/3` —
a public function with no other clause, referenced nowhere, left over from the
rename to `search_recipients/3`.

### IMPROVEMENT - MEDIUM — database work in `mount/3` — **recorded, not changed**

`InboxLive.mount/3` runs `load_mailboxes/1` (which *writes*: `ensure_user_mailbox/1`
on first visit) and `ComposeLive.mount/3` loads `sendable_mailboxes/1` and up to
200 recipient suggestions. `mount/3` runs twice (static render, then the socket),
so each is done twice per page load.

Not changed: `handle_params/3` also runs on both renders, so moving the code
there does not help. The real fix is a `connected?/1` guard (or `assign_async`)
plus a placeholder for the static render, which changes what the first paint
looks like — a UI decision, not a review fix. The comment at `load_mailboxes/1`
already records the "stable for the life of the socket" intent.

### IMPROVEMENT - MEDIUM — archiving hides a mailbox but does not close it — **recorded, not changed**

`archive_mailbox/2` removes the mailbox from the sidebar
(`list_accessible_mailboxes/1`), from recipient resolution and from sending
(`ensure_active/1`), but `InboxLive.resolve_mailbox/2` + `Mailboxes.authorize/3`
check only the grant. An owner or grantee can still open, mark, move and purge
an archived mailbox through `?mailbox=<uuid>`. That may be the intent
("archived = read-only"), but it is not written down and no test pins it. Decide
and document; if archived should mean closed, `authorize_scope/3` is the one
place to add a status check.

### IMPROVEMENT - MEDIUM — `move_to_folder/4` accepts every folder — **recorded, not changed**

All six folders pass `Delivery.changeset/2`, so a writer can move a received
message into `sent` or a draft's delivery into `trash`/`inbox`. Own mailbox
only, so no cross-user effect, but `sent` and `drafts` are assigned by the send
and draft paths and a draft moved out leaves a `status: "draft"` message that
nothing lists. Not changed because the intended set of legal moves (is
"Restore" from `trash` to `sent` ever right?) is a product decision.

## Checked and fine

- `Members.scope_query/1` + `keep/1` — SQL narrowing when the default rule applies, host filter applied after; a raising filter counts as `false`.
- `thread_uuid` minted on the insert (`ensure_thread_uuid/1`), with `backfill_thread_uuid/2` kept as the fallback.
- `dedupe_recipients/1` keeps the stronger role, matching the unique index.
- `handle_user_deletion/1` runs in one transaction; a failing `update!/1` rolls back and raises rather than half-handing-over.
- V02 identifier names stay under 63 bytes (`identifier_length_conformance_test.exs`).

## Gate

`mix test` green (against `../phoenix_kit`, see PR #2), `mix precommit` clean.
