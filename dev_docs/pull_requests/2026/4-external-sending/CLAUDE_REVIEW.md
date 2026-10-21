# PR #4 — Sending to external addresses through one Outbound seam, host-sent mail in Sent, the nudge through the same seam

**Author:** timujinne · **Merged:** 2026-10-21 (`8895f71`) · **Branch:** `feat/external-sending`
**Reviewer:** Claude · **Scope:** `outbound.ex`, `outbound/mailer.ex`, `external.ex`, `email_log.ex`, `notify.ex`, `migrations/v05.ex`, `schemas/external_recipient.ex`, the external paths of `messages.ex`, `web/inbox_live.ex`

## Summary

This is the riskiest PR (it lets mail leave the application) and the seam is
built the way the risk deserves. `Outbound.deliver/2` is the only caller of core's
mailer; it is closed unless *both* the setting and a filter are configured; a
filter that raises, throws, exits or answers anything unexpected refuses
(`:filter_failed`) and its log line carries the *shape* of the answer, never the
addresses; only To/Cc/Bcc/Reply-To of its answer are taken, so a filter cannot
rewrite the body or From. `skip_queue: true` and `queue: false` on every call
keep a queued message from being re-sent through core's default integration.

The send itself is right too: external rows are `pending` inside the send's
transaction, the email goes after the commit under `TaskSupervisor`, the
identity and the right to write externally are checked again in the task, the
rows become `sent`/`failed` with a broadcast on the sending mailbox's topic,
and a crash while recording leaves rows `pending` (rendered `:unknown` after 15
minutes) rather than `failed`, which would offer a retry of something that may
have gone. `claim_failed/1` takes `failed → pending` in one `UPDATE … RETURNING`,
so two concurrent retries send once. An external Bcc is blind to everyone but the
sending mailbox.

One defect worth fixing here, two things to record.

## Findings

### BUG - MEDIUM — a line break in the subject could add mail headers behind the filter — **fixed**

The message subject goes to `Swoosh.Email.subject/2` unchanged — in the external
email (`External.build_email/3`) and in the nudge ("New message: …"). The only
constraint was `validate_length(:subject, max: 500)`. The compose form is a
single-line input, but `Messages.send_message/4` and `save_draft/4` are public
and a LiveView event is whatever the browser sends, so a subject containing
`\r\nBcc: someone@elsewhere.test` reaches the header block. The host's
`outbound_filter` runs on the *struct* and looks at its `to`/`cc`/`bcc`, so an
injected header is the one addressing it cannot see — which defeats the point of
the seam (the schema already forbids line breaks in `from_name` for this reason).
Whether the SMTP adapter in use folds or rejects it is the adapter's business;
the module should not hand it the question.

Fix: `Message.changeset/2` flattens runs of CR/LF in the subject to one space
(and trims) before the length check, which covers drafts, sends and the nudge
(the nudge reads the stored message). Test: a send with
`"Hello\r\nBcc: …\nX-Evil: 1"` stores `"Hello Bcc: … X-Evil: 1"`.

### IMPROVEMENT - MEDIUM — the nudge email carries the subject — **recorded, not changed**

`Notify.nudge_email/5` puts the message subject in the email's subject and body.
The module docs call it a short "you have a new message" email, and the code
comments elsewhere are careful to keep personal data out of the permanent
activity log ("counts only, no subject, no addresses"). The nudge goes to the
recipient's real address, through the host's filter and into the email log with
the subject in it. Whether that is wanted is a privacy decision for the host;
worth a setting (`inbox_email_nudge_subject`) before a host with sensitive mail
turns nudges on. Not changed.

### NITPICK — documented limits, confirmed against the code

- **Retry guard is only as good as the log.** `retry_check/1` returns `:ok` when `EmailLog.rows/1` is `[]` (`Enum.all?([], …)`), so a send the emails module did not log (sampling below 100 %) is offered for retry after a failed transport answer. Stated in the moduledoc; the alternative (refuse when there are no rows) would make a genuine first-try failure unretriable, so it is the right trade-off.
- **The task checks the scope it was started with**, whose `cached_permissions` were read when the scope was built; a `send_external` withdrawn mid-send is seen by the next send or retry, not the running task. Stated in the moduledoc.

## Checked and fine

- `Outbound.send_options/2` builds `message_tags` from the context only; nil values are rejected so an unset `inbox_message_uuid` is not written as `null`.
- `EmailLog.rows/1` filters on `message_tags->>'inbox_message_uuid'` and `inbox_kind` defaulting to `'message'`, so nudges are not counted as the message's sends; `phoenix_kit_emails` stays a soft dependency (`Code.ensure_loaded?` + `apply/3`, with the credo disable commented).
- `record_sent/4` refuses typed recipients, internal addresses and bad entries; stores no file; marks `source: "host"`, which `retry_check/1` refuses.
- V05 checks `role` and `status` with schema-anchored `pg_constraint` lookups, like V04.
- `deliver_later/4` fails the rows at once when the task cannot start, instead of leaving them `pending` forever.

## Gate

`mix test` green against `../phoenix_kit`; `mix precommit` clean.
