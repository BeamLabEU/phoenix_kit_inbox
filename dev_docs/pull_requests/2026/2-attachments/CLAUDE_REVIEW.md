# PR #2 — Attachments: Storage files as snapshots in a hidden library, served only to the message's participants

**Author:** timujinne · **Merged:** 2026-10-21 (`aa28b85`) · **Branch:** `feat/attachments`
**Reviewer:** Claude · **Scope:** `attachments.ex`, `web/attachment_controller.ex`, `web/routes.ex`, `migrations/v03.ex`, `schemas/attachment.ex`, the attachment paths of `messages.ex` and `web/compose_live.ex`

## Summary

The design closes the obvious holes and the code follows it. Every way in
(upload, own library file, readable Storage file, host-vouched file, host
bytes, forward) is checked in the context, never from the form; `flags` is put
with `put_change/3` and cannot be cast; another module's hidden library is
refused even when `Libraries.can?/3` would allow it; downloads answer one
`404` for "missing", "not yours" and "bytes gone"; the response carries
`attachment`, `nosniff` and `Content-Security-Policy: sandbox`, and the stored
content type is reduced to a plain `type/subtype` token. The
"the creator is exempt, the sender of a forward is not" rule in
`check_policy/3` / `download_policy/3` is the right call and is explained where
it lives.

No defect found that needed a code change. Three things worth knowing.

## Findings

### Environment — the suite is red against the Hex-pinned core

`mix.lock` pins `phoenix_kit 2.63.0`, which has no hidden system libraries
(`Libraries.get_hidden_library_by_slug/1`). Against it, 70 tests fail — all of
them attachment paths returning `{:error, :storage_unsupported}`:
`AttachmentsTest` (46), `AttachmentControllerTest` (10), `AttachmentsLiveTest`
(9), `ExternalSendTest` (5). With `PHOENIX_KIT_PATH=../phoenix_kit` the same
suite is **546/546**. This is the documented "first release after 2.63.0"
requirement, not a regression, but it means the default `mix test` is not a
usable signal until that core is released, and `mix.exs` cannot name the pin.
`AGENTS.md` now says so under "Testing".

### NITPICK — `send_file/3` followed by `File.rm/1` assumes a synchronous adapter

`AttachmentController.show/2` sends the temp copy with `send_file/3` and removes
it in `after`. Bandit (core's adapter) writes the file inside the call, so this
is correct. Under Cowboy `send_file` hands the file to the connection process
and returns, and the `after` can delete it first. Core ships Bandit, so not
changed; noted for a host that swaps the adapter. Reading into memory
(`send_resp`) would remove the dependency at the cost of up to
`inbox_max_upload_bytes` per download.

### NITPICK — `release/1` is check-then-delete

`Attachments.release/1` asks "does any row name this file?" and then deletes. A
forward that attaches the same snapshot between the two statements loses its
file. The window is the gap between two queries on a draft being discarded or
edited, and the module docs already call the clean-up best-effort, so not
changed. If it ever matters, delete with the `NOT EXISTS` in the same statement.

### NITPICK — `File.write!/2` outside the rescue

For `attachments_data: [%{binary: …}]` (host-supplied only), `snapshot/3` writes
the temp file with `File.write!/2` before `store_snapshot/5` — whose `rescue`
turns failures into `{:attachment_store_failed, …}`. A full disk raises instead
of returning that tuple. Server-side input only; not changed.

## Checked and fine

- Snapshots are stored before the transaction and discarded if it rolls back (`finish_attachments/2`); `store_file_in_buckets` never runs under the `Multi`.
- `write_rows/3` keeps, repositions, drops and inserts in one pass and returns the dropped file uuids for `release/1` *after* the commit.
- `fetch_for_download/2`: module on → `"inbox"` → participant (sender, or an active delivery in a mailbox the user can open) → policy for the viewer unless they created the snapshot.
- `AttachmentController` is mounted behind `:browser` + `:phoenix_kit_admin_only`, at the configured admin path.
- V03 has no FK on `file_uuid` on purpose (Storage can hard-delete); `read_file/1` answers `:not_found` for a gone file.
- The compose upload sets `max_file_size` from `inbox_max_upload_bytes`; sizes of kept and forwarded rows are not re-measured, as documented.

## Gate

`mix test` green against `../phoenix_kit`; `mix precommit` clean.
