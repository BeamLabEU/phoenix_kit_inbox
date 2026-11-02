# PR #14 — Compose draft, pipeline and recipient sources

Reviewer: Codex. Reviewed on 2026-11-02 against `f6a3882`, including merge
`a628371` by Tymofii Shapovalov.

## IMPROVEMENT - MEDIUM — Strip ASCII controls from recipient error echoes — fixed

The pipeline refused addresses containing NUL, newlines, escape and DEL, but
returned those same control bytes in `{:invalid_recipient, text}`. Its echo
sanitizer already stripped C1 controls and direction marks, and described
itself as stripping controls. API hosts consume this public error tuple
directly, so sanitizing only the eventual UI error formatter was insufficient.

The sanitizer now strips the whole ASCII control range as well. A regression
checks NUL, CR, LF, tab, ESC and DEL, with no message written. An existing
newline rejection assertion now expects the sanitized echo. The new regression
failed against the merged source.

## Review coverage

Checked callback configuration refusal, sender and mailbox authorization,
trusted account UUIDs versus browser input, recipient limits and route checks
inside the host wrapper, Reply-To choices, attachment authorization and flags,
wrapper mutation limits, same-process send callbacks, send result memoization
and persisted-message verification. Reviewed supervised recipient source
isolation, timeouts, locale transfer, deduplication and remembering addresses.

The documented prohibition on host transactions around `send_fun` remains a
host obligation. Recipient source tasks still require hosts to establish their
own tenant/process context from scope and context.

## Validation

Final suite and gate results for this review batch are recorded in PR #15's
CODEX_REVIEW.md.
