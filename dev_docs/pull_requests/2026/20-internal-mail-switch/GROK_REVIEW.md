# PR #20 — A switch for mail inside the application

**Author:** timujinne · **Merged:** `a935445` (2026-11-19)
**Reviewer:** Grok · **Reviewed:** 2026-11-23 · **Verdict:** approve, one fix

`inbox_internal_enabled` defaults to on when unset. Off: an email-shaped recipient is an outside address and is not looked up; a handle that names somebody inside is `:internal_mail_disabled` before anything is written; compose, the pipeline and the recipient source read `:internal` as `:email`.

## Checked and fine

- One read of the switch per send, and the preview uses the same lookup. An ambiguous handle is refused, not reported as ambiguous. `refuse_internal_only/1` runs before any mailbox is created.
- With no outside right the error is `:external_not_allowed`. `send_message/3` has no scope, so every email is `:external_needs_scope`.
- The toggle sets the clicked value. A manager's malformed payload is ignored. Anyone else gets `:forbidden`. A failed save re-reads the setting and renews the element. `set_internal_enabled/1` takes no scope, same as the other settings writers; the page guard is the check.
- Compose reads `@internal_mail` in `assign_mailbox/2` and follows the broadcast. The embedded form does not subscribe; the pipeline rechecks at send. Left on purpose.
- Every test that writes the setting is `async: false` and uses `internal_mail_setup/1`.

## Findings

### BUG - MEDIUM — An open settings page kept a stale switch (fixed)

The page that writes the switch did not subscribe to the broadcast `set_internal_enabled/1` sends. A second manager's checkbox stayed on the value from mount. The click sends the value the box shows, so the stale box was also the next write.

`SettingsLive` now subscribes to the shared-senders topic and, on `{:inbox_access_changed, _}`, re-reads only the switch. The element is renewed when the value changed, the same way a save that did not stick puts the box back. This page's own save already shows the new value, so the broadcast that follows does not renew it again. A shared-sender change, which uses the same topic, does not reload the sender editor.

`web/settings_live_test.exs` covers another manager turning the switch off and on with the editor open, and a sender broadcast that leaves both the switch and the open form as they are.

## Left as is

### NITPICK — The setting is read in `mount/3`

The page reads `internal_enabled?/0` while mounting, so the first render has the value. The same read already lived there. Moving it would not change what a connected page shows. Not changed.
