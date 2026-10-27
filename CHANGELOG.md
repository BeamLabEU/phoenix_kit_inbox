# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## 0.4.0 - 2026-10-27

### Changed

- **Core pin widened to accept core 3.x** (ceiling `< 4.0.0`; the floor is unchanged).

- Tests build `phoenix_kit_email_logs` by running the Emails module's chain (`phoenix_kit_emails` is a test-only dependency); core 3.0 no longer creates it. Hosts without Emails are unaffected.

## 0.3.0 - 2026-10-24

PRs #1–#7 and their Claude and Codex review fixes.

### Upgrade notes

- **Five new migrations, V02–V06.** Run `mix phoenix_kit.update`, then
  `mix ecto.migrate`.
  - **V02 can stop on existing data.** It adds a case-insensitive unique
    index on shared-mailbox addresses. If two shared mailboxes already share
    an address (ignoring case), the migration raises and lists them. Nothing
    is renamed automatically: give each one a distinct address, or clear one,
    and run it again. Check before upgrading:
    `SELECT lower(address), count(*) FROM phoenix_kit_inbox_mailboxes WHERE kind = 'shared' AND address IS NOT NULL GROUP BY 1 HAVING count(*) > 1;`
  - V02's `down` refuses while any mailbox has lost its owner.
  - V06 seeds data once, on the step from 5 to 6: every existing common
    sender is opened to the roles that hold `inbox.send_external` or `"*"`,
    so nobody loses a sender they could use before.
- **Requires `phoenix_kit ~> 2.16`** (was `~> 2.0`): sub-permissions and
  `Scope.can?/2`, the `before_user_delete/1` callback and
  `Activity.log(permanent:)`. Adds a `gettext ~> 1.0` dependency.
- **Attachments need core 2.64.0 or later** (hidden system libraries and
  `store_file_in_buckets/7` `dedup: false`). The requirement is not
  enforced: on an older core every attachment is refused with
  `{:error, :storage_unsupported}` and messages without attachments work as
  before.
- **Breaking: every context function that changes data takes the caller's
  `%Scope{}` and checks it** (#1): `Mailboxes.create_shared_mailbox/2`,
  `grant_access/4`, `revoke_access/3`, `update_mailbox/3`,
  `archive_mailbox/2`, `restore_mailbox/2`; `Messages.save_draft/4`,
  `delete_draft/3`, `mark_seen/3`, `mark_unseen/3`, `toggle_star/3`,
  `move_to_folder/4` and `purge/3` now take `(scope, %Mailbox{}, …)`
  instead of mailbox uuids or a bare owner uuid. `send_message/3` with a
  sender uuid still works and checks the same grant, but refuses
  attachments and external addresses.
- **Email nudges need a nudge sender now.** A nudge goes out only when
  `inbox_email_nudges_enabled` is on, a shared identity is set as the nudge
  sender (`set_nudge_identity/2`, `inbox_nudge_identity_uuid`), external
  sending is open (`inbox_external_enabled`) and the host has configured
  `outbound_filter` (or set it to `:none` explicitly). A host that had nudges
  on under 0.2.x sends none after upgrading until those are set.
- **Only members can be addressed.** Recipients and suggestions are limited
  to users with a role carrying `"inbox"` or `"*"`, plus the Owner. To
  change the rule, set `config :phoenix_kit_inbox, recipient_filter: {Mod, :fun}`.

### Added

- **Attachments** (#2, V03): uploads, existing Storage files (core's media
  picker, limited to the user's own Media files), host-provided files and
  bytes, and forwards. Each one is kept as a snapshot in the module's hidden
  Storage library and downloaded through the module's route,
  `GET /admin/inbox/files/:attachment_uuid`, only by people on the message.
  At most 50 files per message (`inbox_max_upload_bytes` each). Compose
  uploads stay out of Storage until the draft is saved or the message sent.
  A host can set `attachment_policy` to refuse files for chosen readers.
- **Sending identities, Reply-To and signatures** (#3, V04): shared and
  personal sending identities backed by mail integrations, checked on every
  send; Reply-To choices; per-mailbox Markdown signatures with one default,
  inserted after a `-- ` line and swapped while untouched. Message bodies are
  written in Markdown and shown sanitized, with remote images as links.
- **External recipients** (#4, V05): email addresses in To/Cc/Bcc next to
  internal recipients, sent as one email through the sender's integration
  after the message commits, with a status per address and a retry that
  never sends twice (`retry_external/3`). Every email the module sends goes
  through `PhoenixKitInbox.Outbound` and the host's `outbound_filter`. New
  settings `inbox_external_enabled` (off by default) and
  `inbox_external_max_bytes` (25 MB of base64 by default). Host-sent mail can
  be recorded in Sent with `Messages.record_sent/4`.
- **Shared mail opened to chosen roles** (#7, V06): a common sender bound to
  no mailbox has its own list of roles, edited on a new "Mail" page in core's
  admin Settings (`/admin/settings/inbox`). Shared-mailbox signatures are
  edited from the mailbox's row on the Mailboxes page. Users get "Mail" and
  "Mail settings" (`/dashboard/inbox-settings`: signatures, default Reply-To,
  personal senders) in the avatar menu.
- **`@username` addressing**, a recipient circle limited to members, and
  sub-permissions `inbox.manage_shared` and `inbox.send_external` (#1).
- **Correspondence survives user deletion** (#1, V02): a deleted user's
  mailboxes are archived, or a shared one is handed to an active admin
  (`before_user_delete/1`). A mailbox with mail in it can be archived but no
  longer deleted.
- Each send records a snapshot of its sender and recipients, and one
  permanent `inbox.message_sent` activity.
- **Translations** (#5): the module's own Gettext backend with `en`, `et`
  and `ru` catalogues, including permission labels. Notifications and nudges
  use the recipient's locale.

### Fixed

- **Bcc recipients were shown to every reader.** They are now visible only
  in the sender's copy, in the recipient list, the snapshot and the
  external-status pane.
- **Access checks**: `send_message` no longer trusts the sender passed in;
  Compose, Inbox and Mailboxes re-check grants on every navigation and panel
  open instead of trusting the list loaded at mount, so a revoked or demoted
  user can no longer load new drafts, messages, grants or signatures from an
  open page; a disabled module stops serving open sockets; Inbox no longer
  creates a mailbox for a user without Inbox access; the grants panel is
  admin-only and no longer crashes on a non-uuid.
- **Drafts**: saving keeps the recipients and the typed text; save, send and
  discard lock and recheck the draft, so a competing send cannot be
  overwritten, sent twice or have its attachments replaced; a draft uuid
  that does not name a draft in the sending mailbox is refused; discarding no
  longer reports success when the delete was refused; saved drafts can be
  reopened from the UI.
- Replies from another mailbox no longer fail the parent check, and a reply
  to a reply stays in the root's thread. Threads with messages inserted in
  the same second keep their order.
- Shared-mailbox notifications reach every grantee, not only the creator.
- A nil caller metadata no longer crashes send and save draft.
- `%` and `_` in a search term are matched literally.
- Colleague search accepts the `@username` form its hint advertises.
- Line breaks in a subject or generated From name can no longer add mail
  headers.
- External sends and retries refuse an archived sending mailbox.
- The only available Reply-To is submitted when the picker is hidden, so it
  is no longer lost.
- Concurrent edits of a shared sender's roles no longer merge into the union
  of both lists.
- The sidebar mailbox switcher works: picking another mailbox did nothing
  (#6).

### Changed

- Dependency refresh: `phoenix_kit` 2.64.1 and its transitive set.

## 0.2.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## [0.2.0] - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

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
- **Recipient resolution accepts usernames, emails, and shared mailbox names**,
  and reaches users who have never opened Inbox.

  Resolution originally matched a mailbox's `address` or `slug` only. A
  personal mailbox's slug is `"u-" <> uuid` and the username lives on the user
  record, never on the mailbox — so typing a colleague's username resolved to
  nothing while their full email worked, with no hint which was expected.
  Worse, personal mailboxes are created lazily on first visit, so a user who
  had not yet clicked into Inbox had no mailbox row at all and was
  unaddressable by *any* spelling.

  `fetch_mailbox_by_recipient/1` now falls back to an active-user lookup by
  username or email and creates that user's mailbox on demand, so an account is
  reachable from the moment it exists. Shared mailboxes also resolve by display
  name, not only by derived slug.

- **Compose suggests recipients.** To/Cc/Bcc are backed by a `<datalist>`
  populated from `Mailboxes.search_recipients/3`, which covers users *and*
  shared mailboxes — including users with no mailbox yet, which is exactly when
  a suggestion is most needed. A plain datalist rather than a JS picker: no
  hook to register and it survives `navigate/2`, which an inline `<script>`
  would not.
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
