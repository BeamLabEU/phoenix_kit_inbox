# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-08-02

Initial release.

### Added

- **Mailboxes** — one personal mailbox per user, created lazily on first visit;
  shared mailboxes (`support@`, `sales@`, …) with per-user `read` / `write` /
  `admin` grants. Ownership implies `admin`.
- **Messages** — a message body is stored once and delivered as one row per
  recipient mailbox, so folder / seen / starred state is per person.
- **Folders** — Inbox, Sent, Drafts, Spam, Trash, Archive.
- **Compose, reply, forward** — quoted bodies, `Re:` / `Fwd:` subjects,
  threading inherited from the parent message.
- **Drafts** — saved as real messages and promoted in place on send, so the
  uuid stays stable for anything already linking to them.
- **Search** — case-insensitive over subject and body, plus an unseen-only
  filter.
- **Admin UI** — `Web.InboxLive` (three-pane mailbox, patched navigation),
  `Web.ComposeLive`, `Web.MailboxesLive` (shared mailboxes and grants).
- **Notifications** — a delivered message raises an `inbox.message_received`
  activity event with a `target_uuid`, which core turns into that user's in-app
  notification with a deep link back to the message.
- **Optional email nudges** — when the host also runs `phoenix_kit_emails`, a
  short "you have a new message" email can be sent to the recipient's real
  address. Soft integration: no dependency in `mix.exs`, guarded with
  `Code.ensure_loaded?/1`, off by default behind
  `inbox_email_nudges_enabled`.
- **Module-owned versioned migrations** — `PhoenixKitInbox.Migrations` (+ `V01`)
  create the four tables, tracked by a `COMMENT ON TABLE` and applied by
  `mix phoenix_kit.update`. This module's schema does not live in core's
  versioned chain and does not require a core release to change.

  `migrated_version_runtime/1` catches `:exit` as well as rescuing — a dead
  connection pool exits rather than raising, and this function is called by
  `mix phoenix_kit.status` across every installed module, so an uncaught exit
  from one coordinator would take the whole report down.

- **Identifier-length conformance test** (`test/identifier_length_conformance_test.exs`)
  — fails the build when a migration would create a database identifier longer
  than Postgres' 63-character limit. Postgres does not reject those, it
  silently truncates and logs a notice, which leaves a name that is neither
  what the code says nor stable across hosts.

  The delivery folder index was the motivating case:
  `phoenix_kit_inbox_deliveries_mailbox_uuid_folder_inserted_at_index` is 66
  characters. It now has an explicit `name:`. The test checks explicit names
  *and* reconstructs the `<table>_<cols>_index` names Ecto derives for unnamed
  indexes, which is where the bug came from — nobody counts characters on a
  composite index over a long table name.

[0.1.0]: https://github.com/BeamLabEU/phoenix_kit_inbox/releases/tag/0.1.0
