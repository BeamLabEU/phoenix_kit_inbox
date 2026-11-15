# PR #17 — Compose form's own upload control

**Author:** timujinne (Tymofii Shapovalov)
**Merged as:** `cc361a1`
**Reviewer:** Codex · **Reviewed:** 2026-11-15
**Scope:** PR and follow-ups through `81e65a7`, as part of the review since Hex 0.5.0.

## BUG - MEDIUM — Hiding the control stranded an unfinished upload

Setting `own_upload: false` removed the upload form and input immediately,
including while a file was uploading. In the locked LiveView client,
`pushFileProgress` finds the owning view through the input's form and
`LiveSocket.owner` refuses a detached element. Later progress cannot reach
the component, so the entry can remain incomplete and block sending.

The form now stays mounted with `hidden` while an unfinished upload remains.
It is removed after completion or cancellation. There is still no upload
input when the option starts off, and completed upload chips retain their
existing cancellation behaviour.

Two regression tests start a real LiveView test upload at 50%, hide the
control, and require its input to stay attached and hidden. One finishes the
transfer; the other cancels it through the chip. Both verify that the hidden
form is then removed. Both failed before the fix.

The README documents this behaviour. Host picks still pass through
`authorize_attachments`; the option changes no send authorization or limits.

Validation and the complete release-range scope are in
[the PR #16 review](../16-compose-member-suggestions/CODEX_REVIEW.md).
