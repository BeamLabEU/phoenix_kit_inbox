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

## Follow-up on 2026-11-11

### BUG - HIGH — A second recipient lookup could change the route

The pipeline checked the recipient circle and account inside the host wrapper.
The send then looked up the same address again. A change in membership between
lookups could turn a checked internal recipient into an external address or a
different mailbox. The send now checks and uses the same lookup results.
It creates a recipient's personal mailbox after the route check passes.
The regression changes the host filter's answer after the first lookup and
verifies that the message is delivered only to the chosen account.

### BUG - MEDIUM — A wrapper could retry an interrupted send callback

The callback recorded its result after delivery returned. A wrapper that caught
an interruption could invoke it again, even if the first call had committed
before the interruption. The callback now records the attempt before delivery
and replaces that record with the result when delivery returns. The regression
catches an interruption inside the wrapper and verifies that a second call
does not deliver a message.

### Follow-up validation

All three new regressions failed before their fixes. The full suite passed
against PhoenixKit 3.0.0 from Hex and the local PhoenixKit 3.5.0 checkout
(`ebffa12c2`), with 1,313 tests, zero failures and one expected skip in each
run. Each core used a fresh PostgreSQL test database.

`mix precommit` passed compilation with warnings as errors, the Hex audit,
formatting, strict Credo and Dialyzer with its five existing suppressions.
