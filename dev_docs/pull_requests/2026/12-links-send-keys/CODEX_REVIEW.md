# PR #12 — Message links, idempotent sends and server-side send options

Reviewer: Codex. Reviewed on 2026-11-02 against `f6a3882`, including merge
`d7115d0` by Tymofii Shapovalov.

## BUG - MEDIUM — Indeterminate resolver answers created subject links — fixed

`Links.resolve/2` treated every truthy `exists?/1` answer as confirmation.
An error tuple or `:unknown` therefore linked a message to an object the host
had not confirmed existed. This also passes that link to later replies.
The documented contract requires `true`; the check now requires it exactly.

The regression supplies true, false, nil, an atom and an error tuple from the
same resolver. Before the fix three links were written; afterwards only the
explicitly confirmed object is linked. Resolver exceptions remain isolated.

## Review coverage

Checked V07 and the coordinator, prefix-safe SQL and foreign keys, link source
precedence and thread inheritance, manual authorization and events, send-key
ownership, uniqueness and rollback recovery, key expiry, trusted Reply-To,
HTML validation and reader projections, recipient previews, identity name
personalization and retry identity resolution. Checked the queue bypass and
post-commit transport path against the callers. No shipped migration changed.

The existing documented restrictions on sending inside a host transaction and
on globally shared, unguessable idempotency keys still apply.

## Validation

The added regression failed against the merged implementation. Final suite and
gate results for this review batch are recorded in PR #15's CODEX_REVIEW.md.
