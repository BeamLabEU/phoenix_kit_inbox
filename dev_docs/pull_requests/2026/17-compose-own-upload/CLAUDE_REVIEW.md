# PR #17 — Compose form: option to hide its own upload control

**Author:** timujinne · **Branch:** `feat/compose-own-upload` (2 commits, `87e5f3e`, `fe61bb1`)
**Reviewer:** Claude · **Reviewed:** 2026-11-12 · **Scope:** `web/components/compose_form.ex`, `README.md`, `test/phoenix_kit_inbox/web/compose_form_own_upload_test.exs`

## Summary

A new `ComposeForm` attribute, `own_upload`. A literal `false` drops the form's
own «Upload files» `<form>` (and its `live_file_input`), so a host whose
`attachment_picker` slot already uploads shows one button, not two. Anything
else keeps the control; a later update that leaves the key out keeps the value
it had (`assign_own_upload/2`, same shape as `assign_list/3` and PR #16's
`assign_member_suggestions/2`). It is a view option only: `allow_upload/3`
still runs, the slot still renders, and picks still go through
`authorize_attachments` — the tests cover that the check is not bypassed.

## Merge

The PR branched before PR #16 (`member_suggestions`) landed and conflicted with
it in four places, all "both sides added next to each other":

- the moduledoc's attribute list — both entries kept, `member_suggestions`
  first;
- the `update/2` pipeline — `assign_member_suggestions/2` then
  `assign_own_upload/2`;
- the private helpers — both functions kept;
- `README.md` — the example passes both attributes, one paragraph each.

No behaviour of either PR changed in the resolution.

## Findings

### IMPROVEMENT - MEDIUM — No test that hiding the control leaves existing uploads reachable — added

A host may turn `own_upload` off after the person has already uploaded a file
(e.g. once its own picker becomes available). The upload chips and their ✕
live in the attachments `<ul>`, outside the hidden `<form>`, so they stay —
but nothing locked that in, and a later refactor that moved the chips into the
upload form would strand an entry that is still sent with the letter and can
no longer be removed. Added "an upload made before own_upload goes off keeps
its chip and can be cancelled".

### NITPICK — In-flight uploads when the control is removed mid-upload — not fixed

If `own_upload` flips to `false` while the browser is still sending a file,
the `live_file_input` that drives the client-side upload is removed from the
DOM. The server keeps the entry (its chip and ✕ remain, and the send waits for
unfinished uploads as before), but whether the client finishes the transfer is
up to LiveView's JS. Keeping the input mounted while entries are in flight
would cover it, at the cost of a less obvious render rule, for a host
behaviour (toggling the option mid-compose) that nothing does today. Left as
is; recorded here.

### NITPICK — `own_upload={false}` with no `attachment_picker` — not fixed

The form then has no way to add files, but still shows the "Attachments"
heading and an empty button row. The README says so. A host that wants no
files at all is not a case the option was made for; not worth a render rule.

## Verified

- `upload_form?` selector `#compose-<id>-upload-form` is referenced only by the
  render and tests; no JS hook or `form=` attribute depends on it, and the form
  has no `phx-drop-target` elsewhere that would expect the input.
- The send path (`own_uploads/1`, `drop_uploads/2`, `cancel_upload`) works off
  `@upload_name`, not the DOM form, so it is unaffected.
- No new user-facing strings (gettext catalogue unchanged).

## Gate

`mix precommit` and the full `mix test` run after the merge — see the commit.
