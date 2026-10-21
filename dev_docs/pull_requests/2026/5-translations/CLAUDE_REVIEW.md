# PR #5 — Translate the module: its own Gettext backend with et, ru and en catalogues

**Author:** timujinne · **Merged:** 2026-10-21 (`6e840ae`) · **Branch:** `feat/translations`
**Reviewer:** Claude · **Scope:** `gettext.ex`, `priv/gettext/**`, the `gettext` calls across `lib/`, `mix.exs`, `.dialyzer_ignore.exs`, the catalogue/i18n tests

## Summary

Mostly mechanical and done carefully. The module owns a backend
(`PhoenixKitInbox.Gettext`, `otp_app: :phoenix_kit_inbox`) instead of borrowing
core's, so its strings ship with it; `priv` is added to the package `files` (without
that the catalogues would not reach Hex), `:gettext` to `extra_applications`.
Tabs and permission metadata use `gettext_noop/1` with `gettext_backend:` so core
translates them at render time in the viewer's locale. The notification text is
rendered once, in the *recipient's* locale (`RecipientLocale.in_locale/2`), and the
email nudge likewise — not in the sender's. Core's `put_gettext_locale/2` sets the
process-wide locale as well as its own backend's, which is what a module backend
with no locale of its own reads (checked in core's `users/auth.ex`).

Verified, not assumed: `mix gettext.extract --check-up-to-date` is clean at the
head of `main`; the `ru` catalogue has `nplurals=3` with all three forms on the one
plural message, and `1`/`3`/`21`/`50` render `файла`/`файлов`/`файла`/`файлов`
(tested); every `et`/`ru` singular is translated with placeholders intact.

## Findings

### IMPROVEMENT - MEDIUM — the catalogue test skips plural messages — **recorded**

`GettextCatalogueTest` iterates `%Expo.Message.Singular{}` only, so a
`msgid_plural` entry with an empty or short `msgstr[n]` would pass. The one plural
message today (`A message can carry at most %{max} file(s)`) was checked by hand
and has its own `ru` test, but the next `ngettext` has no guard. A second
comprehension over `%Expo.Message.Plural{}` checking `msgstr[0..nplurals-1]` are
all non-empty and keep their placeholders would close it. Not changed here.

### NITPICK — a translated fallback name is persisted in the writer's locale

`Mailboxes.user_display_name/1` now ends in `gettext("User %{id}", …)`. The result
is stored: it becomes the personal mailbox's `name` at creation and the sender and
recipient names in the message's `metadata` snapshot. For an account with no name,
username or email (rare), the stored string is in whatever locale the creating
process had and will not follow the reader later. Not changed — fixing it means
deciding whether snapshots should store a key rather than a string.

### Docs drift — **fixed**

`AGENTS.md` still said strings go through a local `gettext_str/1` helper over
`PhoenixKitWeb.Gettext`; neither exists any more. It now names the module backend,
the three catalogues, and the extract/merge/translate step the catalogue test
enforces (this review had to follow it for the new "Edit draft" string). The code
map lists `gettext.ex`.

## Checked and fine

- The `.dialyzer_ignore.exs` entry for `gettext.ex` is the known Gettext 1.0 + Expo opaque-struct false positive, scoped to the generated backend file only.
- `permission_metadata/0`'s `gettext_domain: "default"` matches the catalogue name.
- `Errors.message/1` still returns binaries for every clause, and `message(reason) when is_binary(reason)` precedes the catch-all.
- No user-facing literal was left behind in `web/`: the remaining `"…"` strings are CSS classes, ids and event names.

## Gate

`mix test` green against `../phoenix_kit` (557 tests with this review's additions); `mix precommit` clean.
