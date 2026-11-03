# PR #11 — Share attachment bytes with Media, show the attachments library in Media read-only, file attachments in folders

**Author:** timujinne · **Merged:** 2026-10-27 (`a9e4c16`) · **Branch:** `feat/mail-files-library`
**Reviewer:** Claude · **Reviewed:** 2026-11-03 against `a8b57df` · **Scope:** `attachments.ex` (the PR's parts), `attachments/folders.ex`, `attachments/maintenance.ex`, the relink mix task, the `messages.ex` hunks, their tests; also Codex's follow-up `4523ef5`

## Summary

The PR adds three things:

- **Shared bytes.** Snapshots share their stored objects with the file they came
  from (`Storage.link_copy/3`, counted by key).
- **A Media listing.** The attachments library is listed in Media as a managed
  library. It is read-only there for everyone, Owner included.
- **Folders.** Sent and draft snapshots are filed in folders
  (`<mailbox>/<YYYY-MM>/<stamp — subject>`, or `<mailbox>/Drafts`), and a host
  hook can choose the path.

A two-phase mix task relinks earlier full copies and purges the old objects.

Codex's review fixed three bugs:

- a delayed draft filing that moved a sent snapshot;
- duplicate manifest UUIDs that dropped the unverified-entry protection;
- the maintenance phases running inside a caller's transaction.

I reviewed the code as it stands on `main`. Every call into core's Storage was
checked against both the Hex core 3.0.0 and the local core 3.2.6.

## Findings

### BUG - MEDIUM — Folder names were cut by graphemes, but the column counts code points — fixed

`phoenix_kit_media_folders.name` is a `varchar(255)`, and Postgres counts that
length in **code points**. The folder code bounded names with `String.length/1`
and `String.slice/3`, which count **graphemes**:

- `message_folder_name/1`: subject cut to 80 graphemes;
- `mailbox_folder_name/1`: name cut to `255 - suffix`;
- `checked_name/1`: a host hook's name allowed up to 255.

Core's `Folder.changeset` uses `validate_length/3` (graphemes too), so nothing
stopped such a name before the insert. A grapheme can hold many code points
(combining marks: decomposed Vietnamese, Devanagari, "Zalgo" text).

**Failure:** an 80-grapheme subject of five code points each is 400 code points.
The folder insert raises 22001 (value too long). The whole filing transaction
rolls back, and the files stay in the root. Every later
`relink_attachments --apply` tries again, fails the same way, and reports the
message as not filed. A host name over 255 code points broke the documented
contract ("default path and a warning") the same way.

**Fix:** `fit/2` keeps whole graphemes while the code points fit.

- The subject keeps its 80-grapheme cut and is bounded to what is left of 255
  after the stamp, the dash and the longest `create_unique/5` suffix
  (" (" + 12 + ")").
- The mailbox name is bounded the same way, and so is the whole name with its
  ` (slug)`.
- A host name is checked by code points, so one over 255 now falls back to the
  default path with a warning.

**Tests:** a combining-mark subject is cut to exactly 44 whole letters (239 code
points), and a 200-grapheme / 400-code-point host name keeps the default path.
Both tests failed against the merged code.

### IMPROVEMENT - MEDIUM — Filing ran before the notifications and the external email — fixed

`Messages.send_message/4` called `Folders.lay_out_sent/2` right after the commit,
before `Notify.message_sent/4` and `start_external/4`. Filing does several things
none of the recipients need to wait for:

- it takes row locks on the message and on each file, which can wait on core's
  `link_copy` `FOR SHARE` and on a running maintenance relink;
- it runs several queries per file;
- it calls the host's `attachment_folder` hook, which has no timeout.

A slow hook held back the in-app notifications, the nudges and the external
hand-off. That goes against the stated intent for `Links.apply_to_new_message/1`,
which is placed last for exactly that reason.

Filing now runs after `start_external/4`, still in the sending process (so the
hook keeps the caller's `Process.get` context). I checked that the external task
writes only `phoenix_kit_inbox_external_recipients` rows and never the message's
`metadata`, so it cannot race the filing's `jsonb_set`.

**Test:** the hook checks that the recipient's `inbox.message_received` activity
already exists when it is called. This failed with the old order.

### IMPROVEMENT - MEDIUM — The manifest is rewritten in full twice per record (not changed)

`put_entry/4` → `write_manifest/4` re-encodes and renames the whole JSON manifest
before and after every `relink_file`, so I/O grows as O(N²). That is fine for
thousands of snapshots; a library of 100k would be slow.

Not changed. The atomic full rewrite **is** the crash-safety mechanism: the
manifest always holds an intent for the record being moved. A JSON-lines
journal with compaction would be a redesign of a carefully reviewed protocol for
a one-off task. Recorded here so the limit is known.

### NITPICK — "Dry-run by default" was ambiguous for phase 2 — doc fixed

`--purge-old --manifest PATH` deletes unless `--dry-run` is given with it. The
CLI semantics stay: `--purge-old` is an explicit, destructive verb like
`--apply`, and it only deletes keys nothing names. The task's moduledoc now says
so instead of a blanket "dry-run by default".

### NITPICK — A record that never relinked can be marked `verified` (not changed)

On a second `--apply` run, a pending entry whose `relink_file` failed both times
hashes its own unchanged full copy, matches, and is marked verified. This is
harmless: purge keeps every key a record still names (`named_keys` and core's
`delete_unreferenced_keys/1`), so nothing that is still used can go.

## Checked and correct

- **Lock order has no cycle.** Sent filing takes the message, then files in UUID
  order; draft filing takes files in sorted order. Folder creation goes through
  core's savepoint and re-reads after a lost unique race.
- **`managed: :owner`** is passed on every write to the library: create folder,
  move, link, delete and `relink_file`. `link_copy` doesn't need it.
- **`:persistent_term`** is written once per library and config, or once per
  retry window. An equal value causes no global GC.
- **Donor search:** matching sha256 and size, an active file that is not trashed,
  system-managed or being edited. Burned variants are never shared, and
  `judge_link/3` refuses foreign answers.
- **Purge:** only canonical keys under the prefix, never a key an unverified
  entry names, never a manifest of another library.
- **Hook validation:** catches raise, throw and exit. The `(n)` suffix stops at
  21 tries. DST is handled through `TimeZone.shift`.
- **Docs:** AGENTS.md matches the code (apart from the items fixed above).

## Verification

Covered by the gate run recorded in the PR #15 review (this batch).
