# PR #11 — Linked snapshots, Media library, filing and maintenance

Reviewer: Codex. Reviewed on 2026-10-27 against `2edaea5`. Also records final
validation for the independent reviews of PRs #8–#10.

## BUG - MEDIUM — A delayed draft filing could move a sent snapshot — fixed

Draft filing read `folder_uuid == nil` without locking the file. A draft save
can finish its transaction before another page sends that same snapshot. The
delayed draft filing could then read the root location, lose a race to sent
filing, and move the file back into Drafts. It also treated a root snapshot
already named by sent mail as a draft when that sent filing had failed.

Draft filing now locks each file before checking its current location and
whether any sent message names it. Files are locked in UUID order, matching
sent filing. A sent snapshot is left for sent filing or maintenance. The
regression reproduces delayed draft filing after a sent filing failure, then
checks that sent filing still repairs the snapshot. It failed before the fix.

## BUG - MEDIUM — Duplicate manifest entries discarded unverified protection — fixed

Manifest decoding used a map keyed by UUID, with the last entry winning. An
unverified entry followed by a verified duplicate vanished from the protection
set. Purge could then delete the old keys the unverified entry needed for
recovery. Valid manifests written by this tool contain unique UUIDs, but a
malformed or manually combined manifest must still preserve the refusal rule.

Both phases now refuse duplicate UUIDs before changing files or rewriting the
manifest. The regression demonstrates actual deletion against the original
implementation, and verifies refusal, an unchanged manifest and intact objects
with the fix.

## BUG - HIGH — Maintenance writes ran inside caller transactions — fixed

The public maintenance API is documented for release `eval` as well as Mix.
It did not enforce the documented requirement to run outside a transaction.
Relinking could persist a verified filesystem manifest for changes later rolled
back. Purging could observe a caller's uncommitted deletion of an instance,
delete its stored object, then leave a restored database reference pointing to
missing bytes after the caller rolled back.

Both applying phases now return `{:error, :in_transaction}` before filesystem
or database changes. Dry runs remain read-only and allowed. The Mix error
formatter explains the refusal. Regressions for both phases failed before the
guard and check that no manifest, lock, relink or deletion occurs. The purge
test removes an instance inside a transaction and rolls it back, then checks
that both the restored reference and its stored object remain.

## Confirmed

Reviewed library creation/upgrades and retry caching, optional core API guards,
donor selection and full-copy fallback, ownership options, post-commit filing,
the first-sent-message ownership rule, folder links and name-conflict recovery,
manifest intent writes and verification, canonical-key filtering, and both
maintenance phases. Checked the consuming calls against core's Storage code,
including its savepoint behavior for folder/link conflicts.

Existing tests cover failures without partial filing, creator exemptions,
attachment-policy checks, Media permissions, managed-library writes, burned
variants, donor deletion, repeated maintenance runs and failed verification.
Media's administrator visibility and the existing process-kill snapshot leaks
remain as documented in AGENTS.md. No shipped migration, dependency constraint,
version or CHANGELOG is changed.

## Validation

- Baseline `mix test`: 838 tests, zero failures, 121 skipped for optional
  Storage features absent from the published core.
- `PHOENIX_KIT_PATH=../phoenix_kit mix test`: 844 tests, zero failures,
  one skipped (the test for an unsupported core, which is supported here).
- `mix test`: 844 tests, zero failures, 125 skipped on the published core.
- Final focused local-core run after strengthening the rollback regression:
  41 tests, zero failures.
- The three initial regressions failed against the merged source and passed
  after their fixes. Both maintenance transaction regressions also failed
  before the guard was added.
- `mix gettext.extract --merge`: 236 messages unchanged; only source-line
  references changed in the catalogues.

- `mix precommit`: passes warnings-as-errors compilation, unused-dependency
  checking, Hex audit, formatting, strict Credo and Dialyzer. Dialyzer retains
  its five existing suppressed warnings; no suppressions were added. Its
  existing PLT needed a forced refresh to include Mix for PR #11's new task.

The six added tests run where their core features are supported. No dependency
or release changes are included in the review commit.
