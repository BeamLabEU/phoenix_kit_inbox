# PR #19 — Outbox folder: queued and unsent mail with the reason

**Author:** timujinne · **Merged:** `4b12df2` (2026-11-19)
**Reviewer:** Grok · **Reviewed:** 2026-11-23 · **Verdict:** approve, no further change

The sender's copy of a message with external recipients is filed in `"outbox"` inside the send's transaction, and moves to `"sent"` only from `"outbox"` once every external row is `"sent"`. A failure is shown as `ExternalReason.label/1`. The stored transport text is not rendered.

## Checked and fine

- The status update and the folder move are one transaction. The move requires `role == "from"`, `folder == "outbox"` and `status == "active"`, so a copy the user archived, trashed or purged stays. A refused move rolls the rows back to `pending`. A throw inside the transaction comes back as `{:error, _}`, the match raises, and the rescue leaves the rows `pending`.
- `ExternalReason` creates no atom. A `gen_smtp` tuple and an API `{status, body}` both read "The mail server did not take the email." A cut 500-character text still matches on its opening. Unknown text reads "Sending failed." and is never returned as stored.
- Inbox's pane, list and badge tooltip call `label/1`. `ObjectMail` puts that label on `error` for the sending mailbox and `nil` for every other viewer. `list/1`, `list_for_viewer/2` and `list_external_recipients/2` still return the raw column.
- Retry claims `failed` rows in one `UPDATE … RETURNING`. `record_sent/4` files a failed recipient in Outbox and offers no Retry.
- The sidebar count and the "unknown" state agree: `failed` is attention immediately, `pending` only after more than 15 minutes. The page authorizes the mailbox before the bare-uuid queries.
- Moving into Outbox is refused after the write check. Moving out is allowed, and a copy that has left Outbox is not moved back when the mail finishes.
- No migration. `folder` is a string with no check constraint. `ObjectMail` lists `"outbox"` and still treats that mail as sent.

## Left as is

### NITPICK — An external update reloads the open list

`{:inbox_external_updated, _}` reloads the message list when the open folder is Outbox or Sent, including an update for a message that is not on the page. The count is what has to stay current. Reloading one page is cheap. Not changed.
