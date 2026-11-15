# PR #18 — Add a footer_start slot to the compose form

**Author:** timujinne · **Merged:** `2cc2588`, follow-up `ca99359`
**Reviewer:** Grok · **Reviewed:** 2026-11-15 · **Verdict:** approve, no further change
**Scope:** `web/components/compose_form.ex`, `README.md`, `test/phoenix_kit_inbox/web/compose_form_footer_start_test.exs`

## Summary

`ComposeForm` takes an optional `footer_start` slot, rendered at the start of the last row, opposite Cancel and Send, with `%{sending: sending?}`. The row is `items-center` plus a `flex-1` spacer, so Cancel and Send stay on the right. The slot is kept when a later update leaves it out (`assign_list/3`, same rule as `attachment_picker`). A viewer without `inbox` still gets the slot, with `sending: false`, and none of the form.

## Checked and fine

- No caller in this repo passes the slot. A missing key starts as `[]`, so existing embeds are unchanged.
- The slot sits outside `<.form>`. A host button there does not submit the letter. The test clicks it and the form stays.
- `@sending` is a boolean once the draft is open. The denied render passes `false` on purpose: the control is the host's way back, including when access is lost mid-send.
- A slot entry with a false `:if` arrives as `[]`, so the host can take the control away. Omitting the key keeps the last one. The test covers the omit.
- While a send runs the slot is told `sending: true`, and `false` again when the task finishes.
- The README example disables the host button with `state.sending`.

## Left as is

### NITPICK — The last row does not wrap

Back, Cancel and Send sit on one row. A narrow host window can overflow. Wrapping around the `flex-1` spacer puts the spacer on a row of its own often enough that the rule is worse than the overflow. Not changed.
