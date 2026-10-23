# PR #6 — Mailbox switcher in the Inbox sidebar: put it in a form so picking a mailbox works

**Author:** timujinne · **Merged:** 2026-10-23 (`17da24a`) · **Branch:** `fix/inbox-mailbox-switcher`
**Reviewer:** Claude · **Scope:** `web/inbox_live.ex` (sidebar), `inbox_live_test.exs`, the four catalogues

## Summary

A one-element fix, correctly diagnosed: LiveView sends a `phx-change` only from an
input inside a `<form>`, so the bare `<.select phx-change=…>` never fired. The select
now sits in `<form id="mailbox-switch-form" phx-change="select_mailbox">`; the handler
(`%{"mailbox" => uuid}`) already matched the field name, so nothing else moved.

Verified, not assumed:

- the `select_mailbox` handler only `patch_to`s; a hand-edited uuid still goes through
  `apply_params/2`'s re-check, so the form adds no new trust in the client value;
- the new test drives the real element (`render_change` on `#mailbox-switch-form`) and
  asserts the patch, which the old markup could not have satisfied;
- the catalogues were refreshed for the moved source lines (no msgid changed).

## Findings

None. The form carries no `phx-submit`, so Enter in the select does nothing — which is
right for a switcher.
