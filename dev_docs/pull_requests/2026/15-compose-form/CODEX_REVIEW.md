# PR #15 — Embedded compose form

Reviewer: Codex. Reviewed on 2026-11-02 against `f6a3882`, including merge
`951c976` by Tymofii Shapovalov.

## BUG - MEDIUM — Account chips could display a different address from the send — fixed

When a recipient contained both a user UUID and an address, the form displayed
the supplied address, while the pipeline resolved the account UUID first.
The person could approve a displayed destination different from the one the
send actually used. A deleted account with a supplied address also appeared
resolved in the form, although sending would refuse it.

The form now resolves a supplied account before its address, matching the
pipeline. A missing account stays visibly unresolved and blocks Send. The
regression opens a draft with a real account and a conflicting address, then
replaces it with a deleted account; it checks the actual handle, absence of
the conflicting address, and the disabled Send button. It failed against the
merged source.

## Review coverage

Checked draft resets and pending replacement drafts, scope and sender changes,
server-owned recipient chips and suggestion IDs, recipient limits, attachment
picks and reauthorization, upload ownership and cleanup, supervised send and
watcher behavior, retries, idempotency keys, wrapper failures, signatures,
outbound preview and recipient remembering. Reviewed the other three merged
PRs that provide this component's dependencies, with one review record each.

The documented reconnect/idempotency boundary and upload hard-link fallback
remain unchanged. Version, CHANGELOG, dependency constraints and shipped
migrations are unchanged by this review.

## Validation

- All four new regressions failed against the merged implementation in a
  focused run (172 tests, four failures).
- Published PhoenixKit 3.0.0: full suite, 1,294 tests, zero failures, one
  expected skip (the unsupported-core case).
- Local PhoenixKit 3.2.6 (`a1d0ae624`): full suite, 1,294 tests, zero failures,
  the same expected skip. The local-core run used a temporary validation
  checkout and resolved its newer Etcher requirement there; the working
  repository's dependency lock is unchanged.
- After extending the callback fix to close an open picker, the final explorer
  and subscription suites passed against both cores: 60 tests, zero failures
  each.
- `mix format` and `git diff --check`: clean.
- `mix precommit`: warnings-as-errors compilation, unused dependency check,
  Hex audit, formatting, strict Credo and Dialyzer pass. Dialyzer retains its
  five existing suppressed warnings; no suppressions were added.

Integration tests used an isolated PostgreSQL 15 instance on loopback, because
`postgres-test` was rejecting connections in recovery. The passing full runs
used separate test databases for the two cores. The suite still emits its
existing test-support redefinition and scope-refresh helper warnings.

This validation covers all four review documents in this batch.
