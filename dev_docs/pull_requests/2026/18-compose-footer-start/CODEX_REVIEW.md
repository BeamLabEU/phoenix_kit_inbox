# PR #18 — Compose footer_start slot

**Author:** timujinne (Tymofii Shapovalov)
**Merged as:** `2cc2588`, follow-up `ca99359`
**Reviewer:** Codex · **Reviewed:** 2026-11-15
**Verdict:** No additional defect found.

Reviewed the slot, partial-update retention, placement, sending state,
denied render, tests and documentation through `81e65a7` as part of the
review since Hex 0.5.0.

- The host control is outside the compose form; its event belongs to the
  host LiveView and cannot submit the message accidentally.
- Omitting the slot in a partial update retains it; an explicit empty list
  removes it, consistent with the existing slot convention.
- The allowed render passes the send state. The denied render deliberately
  passes `sending: false` and keeps the host's way back while removing the
  mailbox UI, as the existing documentation specifies.
- The default row preserves Cancel and Send placement without a slot.
- No new user-facing strings or authorization bypasses were introduced.

The full suite includes this PR's footer tests. Validation and the complete
release-range scope are in [the PR #16 review](../16-compose-member-suggestions/CODEX_REVIEW.md).
