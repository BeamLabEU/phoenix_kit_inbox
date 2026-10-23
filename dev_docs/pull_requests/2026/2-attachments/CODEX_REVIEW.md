# PR #2 — Attachment snapshots

Reviewer: Codex. Rechecked on 2026-10-23 against `9610dc4` and Claude's review.

## IMPROVEMENT - MEDIUM — Optional core APIs caused compile warnings — fixed

The runtime feature guard refused attachments on older cores correctly, but
literal calls to `Libraries.get_hidden_library_by_slug/1` and
`Libraries.hidden?/1` still generated undefined-function warnings against
Hex core 2.63.0. That defeats the warnings-as-errors gate even for hosts using
only text messages.

The guarded hidden-library calls now use `apply/3`, like the existing soft-dependency
pattern in `EmailLog`. The hidden-library requirement and refusal behavior stay
in place. Attachment suites still require local core with those APIs.

## BUG - HIGH — A stale draft write could alter sent attachments — fixed

Attachment planning preceded the message transaction, while the transaction
updated a previously fetched draft without rechecking its status. A competing
send could win first; the stale save/send would then change sent content and
replace its attachment rows. The draft transaction now locks and rechecks the
row before any message or attachment mutation. A deterministic regression uses
the policy seam to complete the winning send between planning and writing,
then verifies the stale save/send is refused and its new snapshots are cleaned
up. See [PR #3](../3-identities-signatures/CODEX_REVIEW.md) for the full draft fix.

## Checked boundaries and retained limitations

Rechecked snapshot admission, hidden-library isolation, forwarded flags,
creator-only policy exemption, readers of the sending and recipient mailboxes,
download authorization, and attachment response headers. The earlier review's
adapter-specific temporary-file cleanup and check-then-delete release race
remain limitations; neither warrants switching large downloads into memory or
changing core Storage's deletion contract in this review. Process-death orphan
cleanup remains the documented omission.

Final validation is in [PR #7](../7-shared-mail-roles/CODEX_REVIEW.md).
