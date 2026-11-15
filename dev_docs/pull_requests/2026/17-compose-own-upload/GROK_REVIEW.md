# PR #17 — Compose form: option to hide its own upload control

**Author:** timujinne · **Merged:** `cc361a1` (commits `87e5f3e`, `fe61bb1`)
**Reviewer:** Grok · **Reviewed:** 2026-11-15 · **Verdict:** approve, no further change
**Scope:** `web/components/compose_form.ex`, `README.md`, `test/phoenix_kit_inbox/web/compose_form_own_upload_test.exs`

## Summary

`ComposeForm` takes `own_upload`. A literal `false` omits the form's own «Upload files» form and its `live_file_input`. Anything else, or a later update that leaves the key out, keeps the control (`assign_own_upload/2`, the same shape as the other keep-on-omit attributes). `allow_upload/3` still runs. The `attachment_picker` slot still renders. Picks still go through `authorize_attachments`.

The branch landed after #16 and the merge kept both attributes. Nothing in either option changed in that resolution.

## Checked and fine

- The chips and their cancel button live in the attachments list, outside the upload form. A file uploaded before `own_upload` goes off keeps its chip and can be cancelled. The test locks that in.
- The send path reads `@upload_name`, not the DOM form. Hiding the control does not change what a send uploads.
- No JS hook or `form=` attribute points at `#compose-<id>-upload-form`.
- No new user-facing string.

## Left as is

### NITPICK — Removing the input while a transfer is in flight

If `own_upload` becomes `false` while the browser is still sending a file, the `live_file_input` leaves the DOM. The server keeps the entry. Whether the client finishes is LiveView's. Keeping the input mounted while entries are in flight would cover a toggle nothing does today. Not changed.

### NITPICK — `own_upload={false}` and no `attachment_picker`

The form then has no way to add files, and the "Attachments" heading and an empty button row stay. The README says there is no way to add files. A host that wants no files at all is outside what the option is for. Not changed.
