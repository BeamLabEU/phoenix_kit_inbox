# PR #18 — Add a footer_start slot to the compose form

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; one follow-up applied

Merged into `main` as 2cc2588 with a merge commit, no conflicts.

`ComposeForm` takes an optional `footer_start` slot, rendered at the left end of the form's last row, opposite
Cancel and Send. It is rendered with `%{sending: @sending}`. The slot is collected through `assign_list/3` like
`attachment_picker`, so an update that leaves it out keeps it. The row went from `justify-end` to `items-center`
plus a `flex-1` spacer, which keeps Cancel and Send on the right. Without the slot there is no wrapper.

Checked and fine:
- **Existing callers.** No call site in this repo or the `phoenix_kit*` siblings passes the slot, and an absent key
  falls back to `[]` (`assign_new`), so nothing changes for them.
- **Forms.** The form ids (`compose-<id>-form`, `-upload-form`, the From form) and `phx-change` are untouched. The
  slot sits outside `<.form>`, so a host button in it cannot submit the letter.
- **Sending flag.** `@sending` is a boolean from `open_draft/2` on (`false`, then `true` during a run), so
  `state.sending` is never nil on the allowed path.
- **Removal by the host.** A slot entry with a false `:if` still sends the key, as `[]`, so a host can take the
  control away. Leaving the slot out entirely keeps the last one, which is the documented keep-on-omit rule shared
  with `attachment_picker`.

## Findings

### IMPROVEMENT - MEDIUM — The host's «Back» disappeared for a viewer without access (fixed)

`render(%{allowed?: false})` rendered an empty `<div>`, so the slot vanished along with the form. The slot exists for
a host window whose second step is this form. When the viewer lacks `inbox` (opened without it, or lost it
mid-session through a scope refresh), that step went blank, and the host's way back went with it. The control is the
host's, not the module's, so showing it leaks nothing.

Fix: the denied render now shows the slot alone, in `#compose-<id>-footer-start` and with `sending: false`, inside
the otherwise empty `#compose-form-<id>`. A new test checks that a viewer without access gets the control and its
click, and none of the form. It fails without the fix.

### NITPICK — The README did not mention the slot (fixed)

The README's "Embedding → The compose form" section lists the host-facing options of `ComposeForm`, and the slot
was documented only in the moduledoc. The README now has a paragraph and an example with `disabled={state.sending}`.
The moduledoc also notes the denied case.
