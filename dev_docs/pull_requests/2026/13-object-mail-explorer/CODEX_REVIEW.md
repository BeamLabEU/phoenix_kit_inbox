# PR #13 — Object mail and the embedded mail explorer

Reviewer: Codex. Reviewed on 2026-11-02 against `f6a3882`, including merge
`4428bb1` by Tymofii Shapovalov.

## BUG - MEDIUM — Changed host callbacks left cached controls and labels stale — fixed

`MailExplorer.update/2` assigned a replacement `can_link?` or `link_label`
callback without invalidating `link_access` and `link_labels`. Revoking the
host's callback left unlink/link controls visible; adding or removing a label
callback left old object names in the reading pane. Action-time authorization
still refused a forbidden write, so this was stale UI, not a write bypass.

Both callback attributes now participate in invalidation. A picker already
open when linking is revoked is closed too. The integration regression changes
each callback independently on the same mounted component, checking controls,
labels and the open picker. It failed against the merged source.

## IMPROVEMENT - MEDIUM — Keep large scopes out of test session cookies — fixed

The explorer subscription tests serialized a full scope into the signed
session. On local PhoenixKit 3.2.6, two cases exceeded the browser's 4 KiB
cookie limit before mounting. Their helper now uses ComponentHostLive's
existing server-side stash, with cleanup after each test. This keeps the
integration tests working as core's scope grows; no product session changes.

## Review coverage

Checked mailbox-scoped object queries, deduplication, per-viewer Bcc and
identity projection, external status privacy, pagination and thread ordering,
attachment policy batching, component event validation and host callbacks,
subscription ownership, coalescing, detach cleanup and access-change reloads.
Read the consuming tests and the host component used to reproduce updates.

The documented hook ownership of PubSub subscriptions and consumed mailbox
access events remains unchanged; hosts embedding other Inbox components must
account for that contract.

## Validation

Final suite and gate results for this review batch are recorded in PR #15's
CODEX_REVIEW.md.

## Follow-up on 2026-11-11

### BUG - MEDIUM — An open picker could link to a newly selected object

Changing the host's effective link target while the picker was open preserved
the picker and its candidate buttons. A click from that picker could then
link the message to the new object. The component now closes the picker when
its effective target changes. The regression checks that a click from the
old picker is ignored and a fresh choice links to the new object.

### IMPROVEMENT - MEDIUM — Keep the explorer fixtures within the cookie limit

Five tests hit the signed session's 4 KiB limit with PhoenixKit 3.5.0 before
the explorer could mount. The shared mount helper now uses the test host's
server-side stash for the scope, including in the two-explorer case.
