# PR #12 — Message links, idempotent sends and server-side send options (V07)

**Author:** timujinne · **Merged:** 2026-11-03 (`d7115d0`) · **Branch:** `pr/1-links-send-keys`
**Reviewer:** Claude · **Reviewed:** 2026-11-03 against `a8b57df` · **Scope:** `migrations/v07.ex`, `links.ex`, `link_resolver.ex`, the new schemas, the `messages.ex` / `identities.ex` / `external.ex` / `outbound.ex` / `mailboxes.ex` hunks, `identity_editor.ex`, their tests

## Summary

The PR adds four things:

- **V07:** links from messages to objects of the host, idempotent send keys,
  and a shared identity's `personalize_from_name` flag.
- **Server-side send options:** `links:`, `reply_to_trusted:`, `html_body:` and
  `idempotency_key:`.
- **Read-only previews:** `Messages.resolve_recipient_routes/2` and
  `Outbound.preview/2`.
- **`PhoenixKitInbox.Text`:** one place to ask what the database accepts.

Codex fixed `Links.resolve/2` taking any truthy `exists?/1` answer as
confirmation. I reviewed the code as it stands on `main`.

## Findings

### BUG - MEDIUM — The "sender's name in the From name" switch did nothing where it was offered — fixed

`IdentityEditor` showed the `personalize_from_name` toggle for every shared
identity. But `Identities.from_name/2` reads the flag only for a sender **bound
to a mailbox**. A common sender (bound to none) always puts the sender's name in
front, whatever the flag says.

The Settings form never binds a mailbox, so every sender made there is a common
one. The switch showed "off" while every email went out as
`"Alice | Company"`, and switching it changed nothing.

**Fix:** the toggle is shown only when editing a bound identity
(`@bound_edit?`). The `create_shared/2` doc and AGENTS.md now say the flag
applies to bound identities only.

**Tests:** the Settings tests check the switch is absent on create and on an
unbound edit, and present (and saved) on a bound edit.

### BUG - MEDIUM — A NUL byte or invalid UTF-8 in a recipient raised instead of answering — fixed

`Mailboxes.fetch_mailbox_by_recipient/2` passed the term straight into
`lower(u.email) = $1` and the like. Postgres refuses a NUL byte or non-UTF-8
bytes in a text parameter with an exception. I confirmed both against the
merged code:

- `Messages.resolve_recipient_routes(scope, ["a\0b@x.test"])` raised
  `Postgrex.Error`. That is the new public API this PR documents for checking
  routes as a person types.
- `Messages.send_message/3` with such a To raised as well. That part predates
  this PR.

`External.address?/1` would have taken a NUL address as an outside one: its
regex `[^\s@<>",;]` matches `\0`. The row insert would then raise.

This is the gap `Text` was added to close: it already guarded the subject, body,
key, HTML and links, but not recipients.

**Fix:**

- `fetch_mailbox_by_recipient/2` answers `{:error, :recipient_not_found}` unless
  `Text.storable?/1`.
- `External.address?/1` requires `Text.storable?/1` too.

The route is `:email`, and a send refuses the address as an unknown recipient
before the database sees it.

**Test:** routes and sends for a NUL address and an invalid-UTF-8 one, from a
sender who may write outside. No raise, `{:unknown_recipients, [addr]}`, no
message.

### IMPROVEMENT - MEDIUM — `phoenix_kit_inbox_send_keys` had no primary key — fixed in V07

It was the module's only table without one (`primary_key: false`, a unique index
on `key`). AGENTS.md's schema conventions call for a UUIDv7 `uuid` primary key.

It also matters in practice. Under a Postgres publication that replicates
deletes (`FOR ALL TABLES`, common with change-data-capture tools), a table
without a replica identity refuses every `DELETE`. Every keyed send purges
expired keys, and messages cascade into this table, so on such a host every
keyed send would roll back.

**Fix:** V07 gives the table a `uuid` primary key defaulting to
`Helpers.uuid_v7_call(prefix)`, like `message_links`. The unique index on `key`
stays, so `unique_constraint(:key)` and every test of the key race are
unchanged. The schema has `@primary_key {:uuid, UUIDv7, autogenerate: true}`.

**Tests:** both the public and the prefixed probe schema check the primary-key
column.

V07 has **not shipped**: the latest tag is `0.4.0`, cut before this PR, and
`mix.exs` is still at 0.4.0. So this is an edit to an unreleased migration, not
to an immutable one. A development database that already ran the old V07 from
`main` has to roll back to 6 and migrate again (I recreated the test database
for this).

### NITPICK — Small edges in the host options — fixed

- **A blank `reply_to_trusted: "  "`** was `:invalid_reply_to`, while `nil` and
  `""` meant none. Blank once trimmed now means none too (doc and test updated).
- **`html_body_option/1`** called `Text.fits?/2`, which builds a charlist of up
  to 262,144 elements on every send with HTML. The byte check before it already
  bounds the length, so it now asks `Text.storable?/1`.

## Checked and correct

- **V07 SQL is prefix-safe:** bare index names, `uuid_v7_call(prefix)`, FKs with
  `prefix:`, and the CHECK constraint is looked up by name **and** schema.
  `down/1` undoes `up/1`, and the coordinator is at 7.
- **Idempotency keys:**
  - They come from `opts` only and are checked after the write authorization.
  - A lost race becomes `:send_key_taken` and replays the rival's message,
    discarding our snapshots.
  - Another user's or mailbox's key is `:idempotency_key_taken`, never their
    message.
  - The purge uses `FOR UPDATE SKIP LOCKED`.
- **`html_body` never reaches a reader:**
  - Every read path goes through `lean/1` / `project_for_viewer/2` (folders,
    `fetch_delivered`, `list_thread`, `ObjectMail`, compose).
  - A caller's metadata copy is dropped.
  - It is kept only with external recipients.
- **No header injection:** `personalize_from_name` names go through
  `header_name/1` (CR/LF stripped), and Swoosh quotes the name.
- **Links:** written in the send's transaction, de-duplicated, ranked on
  conflict. Subject resolvers run after the commit and are guarded.
- **`resolve_recipient_routes/2`** uses the send's own lookup and circle, so it
  reveals no more than a send's errors would.

## Verification

Covered by the gate run recorded in the PR #15 review (this batch).
