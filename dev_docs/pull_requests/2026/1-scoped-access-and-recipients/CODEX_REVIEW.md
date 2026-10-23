# PR #1 — Scoped access and recipients

Reviewer: Codex. Rechecked on 2026-10-23 against `9610dc4`, including Claude's
follow-up fixes and the later merged PRs.

## BUG - HIGH — Compose trusted grants cached at mount — fixed

After a writer's grant was revoked, a URL patch could still select that mailbox
from the cached list and load a **new** draft, reply or forward through
`Messages.fetch_for_mailbox/2`. The context read intentionally assumes the caller
authorized the mailbox; Compose had not rechecked. Changing the From picker also
loaded newly created signatures after revocation.

Compose now reloads active writable mailboxes before selecting one, on both URL
changes and picker events. Tests create the private draft/signature after the
grant disappears and verify neither can be loaded. Recipient suggestions are
loaded with the authorized mailbox rather than unconditionally in mount.

## BUG - MEDIUM — Inbox kept reading after disable and retained a denied selection — fixed

`handle_params/3` trusted the mount-time access boolean. `has_module_access?/2`
also checks permission membership rather than whether the feature is enabled.
An already open socket could therefore load a new message after Inbox was
disabled. A failed mailbox switch cleared the list but left the previous
reading pane and recipient information visible.

Inbox now checks `Scope.can?/2` on each parameter change and uses
`Mailboxes.authorize_scope/3` before reading. Denial clears the selected message,
recipients, attachments, external status and folder counts. External-status
broadcasts reauthorize before fetching new data. Mount gates across the admin
LiveViews also use the enabled-feature check. Regression tests cover disable
and denied navigation.

## Verification and retained decisions

Confirmed that per-recipient state stays on deliveries, Bcc filtering is applied
to the reader's metadata, parent selection checks readability, and the previous
wildcard-escaping and context-level write checks remain intact. No migration was
edited. Archived mailbox reading and the set of valid filing destinations retain
their existing semantics; changing those is a product decision.

Shared-panel authorization findings are recorded with [PR #7](../7-shared-mail-roles/CODEX_REVIEW.md).
Final validation for all seven rechecks is recorded there too.
