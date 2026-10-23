# PR #7 — Shared mail: common senders open to chosen roles (V06), a Mail page in core's Settings, signatures on the Mailboxes page

**Author:** timujinne · **Merged:** 2026-10-23 · **Branch:** `feat/shared-mail-roles`
**Reviewer:** Claude · **Scope:** `migrations/v06.ex`, `schemas/identity_role.ex`, `identities.ex`, `mailboxes.ex`, `messages.ex`, `web/{identity_editor,mailboxes_live,settings_live,my_settings_live,compose_live}.ex`, `settings_tabs/0`, tests

## Summary

A common sender (a shared identity bound to no mailbox) used to be open to everyone
with `inbox.send_external`. It is now open to a **list of roles**, narrowing that right,
Owner always allowed. The list lives in `phoenix_kit_inbox_identity_roles` (V06); the
shared senders move out to a "Mail" page in core's Settings; shared-mailbox signatures
move to the Mailboxes page; the access panel lists grants by name and picks colleagues
from a search instead of a raw user UUID (which closes the "Grants take a raw user UUID"
gap in AGENTS.md).

This is careful work. Checked against the code, not the description:

- **The narrowing is enforced where the send is, not only where it is offered.**
  `Identities.resolve/3` calls `open_to?/2` for a common sender, and the list is read on
  every resolve and `list_usable`, so a role taken off stops a send already queued
  (`External` re-resolves in its task and on retry). The roles come from
  `Scope.user_roles/1`, so "acting as" is respected.
- **V06 is safe to ship.** `create_if_not_exists` for the table and both indexes, both FKs
  `ON DELETE CASCADE` in the same prefix, seed qualified with `Helpers.qualify_table/2`
  and `ON CONFLICT DO NOTHING`, run only on 5 → 6 (an `up` at 6 never reseeds, so roles
  taken away stay away). Owner is excluded from the seed because Owner needs no row. The
  immutability rule is kept: V01–V05 are untouched.
- **Writes are atomic.** `write_with_roles/3` writes the identity and its roles in one
  transaction and rolls back with the changeset, so `{:error, changeset}` keeps its old
  shape for the form. Binding to a mailbox clears the roles (a bound sender goes by its
  mailbox); unbinding starts with none — both documented and tested.
- **Input is narrowed twice.** `IdentityEditor` passes on only `@fields` (a forged
  `mailbox_uuid` is dropped), and `known_role_uuids/1` casts, dedups and drops Owner and
  unknown uuids. The hidden `identity[role_uuids][]` input means an all-unticked form
  clears the list instead of leaving it, which the edit path depends on.
- **Core API.** Everything new that is called from core (`Scope.owner?/1`,
  `Scope.user_roles/1`, `Permissions.get_permissions_matrix/0`, `Roles.list_roles/0`,
  `Role.system_roles/0`, the `settings_tabs/0` callback) exists in the pinned 2.63.0:
  a forced compile against Hex core shows only the two pre-existing hidden-library
  warnings from attachments.
- **The grant panel's search is not a new disclosure.** `search_users/3` returns the same
  members (`Members.keep/1`, the viewer excluded) that compose's recipient suggestions
  already offer to any `"inbox"` user, and `grant_search` is a no-op without an open panel
  (tested).

## Findings

### NITPICK — roles checklist is a raw checkbox, not `<.checkbox>`

`identity_editor.ex` renders `<input type="checkbox" class="checkbox checkbox-sm" …>`
inside a `<label>`. Per the umbrella's checkbox rules that is the shape `<.checkbox>`
exists for. **Left alone, deliberately:** the field is an array (`identity[role_uuids][]`),
`<.checkbox>` hardcodes `checkbox-primary` and adds a `value="false"` fallback input that
would put a bogus entry in the list, and the form already has its own `""` fallback
(which `known_role_uuids/1` drops). The `<label>` wraps the input, so clicking the name
toggles it — the bug the component fixes does not apply.

### NITPICK — a stale open Access panel still runs the colleague search after a demotion

If an admin is demoted while their Access panel is open, `grant_search` keeps returning
candidates (the mount-time `expanded` is not re-judged). Writes are refused by the
context (`grant`, `revoke`, `archive` have tests for exactly this), and the search shows
nothing the compose suggestions do not, so no check was added. If `search_users` ever
gains a field compose does not show, re-authorise there first.

### NITPICK — `admit_externals` runs `list_usable/2` only to pick an error atom

With no identity chosen, `Identities.list_usable(scope, mailbox) == []` decides between
`:external_not_allowed` and `:external_needs_identity`, and `list_usable` runs
`check_integration/2` per identity. It is DB-only and only on a send with an external
address and no identity, so not worth a cheaper path.

## Verification

`PHOENIX_KIT_PATH=../phoenix_kit mix test` — 611 tests, 0 failures. `mix precommit` —
passes (compile `--warnings-as-errors`, unused deps, `hex.audit`, `quality.ci`, dialyzer).
Against the Hex-pinned core the attachment suites fail with `:storage_unsupported`, as
AGENTS.md records; that is the environment, not this PR.

## Merge note

The PR conflicted with #6 only in the four gettext catalogues (source-line references).
Resolved by taking the PR side of each hunk and re-running `mix gettext.extract --merge`;
no msgid was added or lost.
