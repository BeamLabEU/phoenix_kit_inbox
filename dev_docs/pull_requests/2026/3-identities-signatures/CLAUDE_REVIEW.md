# PR #3 — Sending identities, mailbox signatures, Markdown bodies and a Mail settings page

**Author:** timujinne · **Merged:** 2026-10-21 (`ad15558`) · **Branch:** `feat/identities-signatures`
**Reviewer:** Claude · **Scope:** `identities.ex`, `signatures.ex`, `body.ex`, `schemas/{identity,signature}.ex`, `migrations/v04.ex`, `web/{identity_editor,signature_editor,settings_live,my_settings_live}.ex`, the compose/inbox changes

## Summary

The authorization model is tight: every write takes the scope and judges the
*stored* row (`fetch/1` then `authorize_manage/2`), a shared identity is
`manage_shared`-only, a personal one is its owner's from their own personal
mailbox only, and `resolve/3` — not `resolve/2` — is what a send uses, so a
bound identity cannot go out from another mailbox. The From address is the
integration's login and is never typed. `from_name` rejects line breaks, quotes
and angle brackets in the schema, and Reply-To must be one of
`reply_to_options/2`. V04's CHECK keeps the two identity shapes apart.

`Body.markdown_html/1` was probed rather than read: an `alt` or `src` carrying
`<b>`, quotes or `onerror=` comes out inert (quotes become `&quot;`, the tag
text is dropped), `javascript:`/`data:` links lose the link, and links core
emits with a `style` attribute still get `target`/`rel`.

Three real defects, one of them the most user-visible thing in the five PRs.

## Findings

### IMPROVEMENT - HIGH — a saved draft could not be reopened from the UI — **fixed**

`ComposeLive` reopens a draft from `?draft=<uuid>` and PR #3 built a lot on that
(`draft_sender/1`, "a reopened draft keeps its body and its Reply-To", the
signature `:edited` path), and `Paths.compose/1` accepts `:draft`. But nothing in
the UI links there: the Drafts folder opened the draft in the reading pane,
whose only actions were Reply and Forward — replying to your own half-written
message, with `readable_by?/2` then silently dropping the parent because a
draft is not `"sent"`. The only way back into a draft was typing the URL, which
is what the tests do.

Fix: `message_actions/1` shows **Edit draft** (`#edit-draft`, to
`Paths.compose(mailbox:, draft:)`) for a draft and hides Reply/Forward for it;
other messages are unchanged. The string is in the `en`/`et`/`ru` catalogues
(`Muuda mustandit`, `Редактировать черновик`). Two LiveView tests: a draft gets
the edit link and no Reply/Forward; a received message the reverse.

### BUG - MEDIUM — clearing a field raised in the identity and signature changesets — **fixed**

`Identity.changeset/2` does `update_change(:label, &String.trim/1)` and
`update_change(:from_name, …)`. `cast/3` turns `""` into `nil`, and when the
stored value was non-nil that is a *change* to `nil`, which `update_change/3`
hands to `String.trim/1` — `FunctionClauseError`. Reproduced with a probe test
(`update_identity(scope, identity, %{"from_name" => ""})`). The same line exists
for `Signature` `:label` (an explicit `nil`; `empty_values: []` keeps `""` as
`""`, so the form path was safe).

The settings pages offer no "edit" for an identity today, which is why no user
hit it — but `Identities.update_identity/3` is public API and documents
`"label"` and `"from_name"` as changeable. Both changesets now pass `nil`
through (`trim/1`), leaving `validate_required/2` to say "can't be blank" for
the label; clearing `from_name` stores `nil`. Tests added for both schemas.

### BUG - MEDIUM — a forged `sig_delete` crashed the LiveView — **fixed**

`Signatures.fetch/1` did `repo().get(Signature, uuid)` on the string the
browser sent in `phx-value-uuid`. A non-uuid raises `Ecto.Query.CastError`.
`Identities.fetch/1` right beside it casts first, and the editor's moduledoc
says "a forged event names nothing it may change" — true for another user's
uuid, not for garbage. `fetch/1` now casts and answers `{:error, :not_found}`;
a test covers `update_signature/3` and `delete_signature/2`.

### NITPICK — identities have no edit form — **recorded**

`update_identity/3` (with its integration re-check) exists and is tested, but
`IdentityEditor` offers only add, check and delete. Changing a label or From
name means delete and re-add. A feature gap, not a defect.

## Checked and fine

- `Signatures.swap_block/3` replaces the block only while the body still ends with exactly what was inserted; an edited block is never rewritten.
- A new default clears the old one in the same transaction; the partial unique index backs it.
- `MySettingsLive` guards every event on `module_access`, and `personal: true` + `permission:` on the tab keeps it out of the menu for users without `"inbox"`.
- `put_status/2` only writes when the status changes, so `resolve/3` is not a write per send.

## Gate

`mix test` green against `../phoenix_kit`; `mix precommit` clean.
