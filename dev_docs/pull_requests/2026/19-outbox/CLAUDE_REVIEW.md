# PR #19 — Outbox folder: queued and unsent mail with the reason

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; no code change needed

Merged into `main` with a merge commit, before #20. It conflicted only in the gettext catalogues (see the #20 review).

The sender's copy of a message with external recipients is filed in a new fixed folder, `"outbox"`, in the send's
transaction. `External.record_outcome/3` moves it to `"sent"`, in one transaction with the rows, once no external row
is unsent. It moves the copy only out of `"outbox"`, so a copy the user archived or trashed stays where they put it. A
failure is shown as a translated reason (`ExternalReason.label/1`) and never as the stored transport text.

Checked and fine:
- **Every reader of the folder column.** `rg` for `"sent"`, `folder ==` and `folder in` across `lib/`. Forward
  authorization, attachment filing (by `sent_at`), the notification links and the per-object mail all key on the
  message or the delivery's status, not on the `"sent"` folder. `ObjectMail` adds `"outbox"` to its folders. No DB
  CHECK limits `folder` (V01 is a plain string), so no migration is needed.
- **Draft promotion.** `upsert_delivery/5` updates the existing `"from"` row's folder, so a draft with an external
  recipient moves to Outbox as the same row.
- **The sender's copy stays seen.** `seen_at` is set for `role == "from"` on insert, so Outbox has the counter badge
  and no unseen badge.
- **The move transaction.** `{:ok, :ok} = repo().transaction(...)` sits inside the existing `rescue`. A refused move
  leaves the rows `pending`, which reads "unknown", and never "sent" with the copy stuck. The PR's trigger test pins
  this.
- **`ExternalReason` parsing.** It creates no atom: names come from a fixed map, and a cut-off 500-character text
  still matches by its opening. Every reason it can produce has an `Errors.message/1` clause, including the
  `nil`-payload tuples.
- **`move_to_folder(…, "outbox")`.** It authorizes first and then refuses, so it reveals nothing about a message
  in a mailbox the caller cannot write.

## Findings

### NITPICK — An external update for another mailbox reloads the open list (left)

`InboxLive` subscribes to the external topics of every listed mailbox. `{:inbox_external_updated, uuid}` now
reloads the open Outbox or Sent list, or the open mailbox's counters, whichever mailbox sent `uuid`. That is one or
two extra queries per update, for a user who holds several sending mailboxes. Telling the mailboxes apart would need
the sending mailbox in the message, which is a change to a broadcast hosts may also hear. Not worth it.

### Known limits (on record, as the PR states)

These letters can stay in Outbox with no Retry:
- rows left `pending` by a task that died;
- any letter on a host without `phoenix_kit_emails`;
- a `record_sent/4` with a failed recipient.

The user archives or deletes them. Letters that failed before this release stay in Sent, with no data migration.

## Gate

Covered in the #20 review: both PRs were validated together on the merged `main`.
