# PR #3 — Identities, signatures and compose

Reviewer: Codex. Rechecked on 2026-10-23 against `9610dc4`, including the previous
changeset, UUID-validation and Edit draft fixes.

## BUG - MEDIUM — The sole Reply-To choice was lost on submit — fixed

Compose rendered the Reply-To select only when there were multiple choices.
With just the user's email, the default existed in socket state but no form
control submitted it. The sent message therefore had no Reply-To. For external
mail using a common From address, replies could go to the common sender rather
than the composing user.

A hidden input now submits the saved/default value whenever the select is
hidden. The regression submits the real form with one available address and
checks the stored message. The existing test for a shared mailbox without an
address still verifies that its empty default produces no Reply-To.

## BUG - HIGH — Draft saves, sends and deletion were unsafe around another send — fixed

This is a cross-cutting finding in the existing draft lifecycle. A supplied
draft UUID that no longer matched silently became a fresh message; a malformed
one raised a query cast error. Reusing a draft UUID after sending could thus
send another message. More seriously, a draft fetched before the transaction
could be updated or deleted after another writer promoted it to sent.

Explicit UUIDs now have to identify an existing draft in the sending mailbox.
The save/send transaction rechecks it under `FOR UPDATE`; discarding uses the
same lock and status check. Competing sends cannot both promote it, and stale
writes cannot rewrite sent content or attachments. Snapshots remain outside
the transaction and are released when the guarded write is refused.

Regression tests cover malformed/missing/already-sent UUIDs and a competing send
between planning and the transaction, for both saving and sending. Changing
the From mailbox clears the previous mailbox's draft UUID; another UI test
verifies a new draft is created there while the original remains available.

## BUG - MEDIUM — Generated From names bypassed line-break validation — fixed

The identity changeset rejected line breaks in an explicit `from_name`, but
fallback profile names, shared mailbox names and the nudge's identity label
could still contain them. Those generated names also become email headers.
Resolved display names now flatten CR/LF before leaving the identity context.
A regression checks common, personal, mailbox-bound and system/nudge senders.

## Checked and retained

Confirmed that identity ownership, integration ownership, mailbox fit and
Reply-To authorization are enforced by contexts; signatures only replace an
unedited inserted block; Markdown goes through the existing safe renderer.
The raw-HTML formats remain escaped. The earlier Edit draft links and nil-safe
changesets are correct. Shipped migrations were left intact.

Final validation is in [PR #7](../7-shared-mail-roles/CODEX_REVIEW.md).
