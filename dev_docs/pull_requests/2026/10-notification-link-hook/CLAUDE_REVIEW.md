# PR #10 — Let the host choose where a received message's notification leads

**Author:** timujinne · **Merged:** 2026-10-27 (`f2d804b`) · **Branch:** `feat/notification-link-hook`
**Reviewer:** Claude · **Reviewed:** 2026-11-03 against `a8b57df` · **Scope:** `notify.ex`, `paths.ex`, README, `notification_link_test.exs`; also Codex's follow-up `4523ef5`

## Summary

A host can set `config :phoenix_kit_inbox, notification_link: {Mod, :fun}`. Then a
recipient's in-app notification can lead to a page of the host (a client portal,
say) rather than to the Inbox. The hook is asked once per reader, with
`(message, recipient_mailbox, reader_uuid)`. It answers a local path or `nil`.
Anything else falls back to the module's link: a non-local answer, a raise, a
throw or an exit.

Codex's review fixed the one real bug: the default link was the raw, unprefixed
path. Since `4523ef5` the default is `Paths.message_path/3`, built with the
reader's own locale (`reader_locales/1`, one query for all readers). I checked the
code as it stands on `main`.

## Checked against the code

- **The hook runs after the commit, in the sending process.** `Messages` calls
  `Notify.message_sent/4` after the `Multi` and the attachment handling. A slow
  or failing hook cannot poison the send. A host that reads `Process.get`
  context there gets the sender's process, as AGENTS.md says. It does not when
  Compose's send task runs it.
- **Every failure is contained.** `host_link/4` catches all three kinds.
  `log_activity/5` still rescues around the whole activity write. The
  notification is written whatever the hook does.
- **`local_path?/1` against core's renderer.** Core stores
  `metadata["notification_link"]` and follows it verbatim. The bell's `href`
  is that string. So the check must stop protocol-relative and scheme URLs:
  - It requires a leading `/`.
  - It refuses `//` and `/\` (browsers read both as an authority).
  - It refuses every C0 control and DEL anywhere in the path. The WHATWG
    parser strips tab and newline, so `/\t/evil` would otherwise turn into
    `//evil`.

  A non-binary answer reaches the catch-all clause and is refused. A regex
  without the `u` flag works on raw bytes, so invalid UTF-8 cannot crash the
  check.
- **Per-reader answers and locales.** `notify_recipient/3` looks up the locales
  for all readers at once. It then asks the hook once per reader, so the owner
  and the grantees of a shared mailbox can get different answers (tested). A
  dialect preference (`"et-EE"`) goes through core's `Routes.url_locale/1`, so
  the default link uses the segment the locale plug serves.
- **Docs match the behaviour.** The `Notify` moduledoc, the `Paths` docs, the
  README and AGENTS.md all say a stored link is followed as given, the host
  builds its own prefix and locale, and the nudge still links to Inbox.

## Findings

### NITPICK — gendered pronoun in a test name — fixed

`"asked per reader: each reader of a shared mailbox gets his own answer"` now
reads "their own answer".

No other findings. The PR is small, the trust boundary (`local_path?/1`) is
right, and Codex's follow-up closed the routing gap.

## Verification

Covered by the gate run recorded in the PR #15 review (this batch).
