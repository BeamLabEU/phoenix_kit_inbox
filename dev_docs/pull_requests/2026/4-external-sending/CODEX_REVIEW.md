# PR #4 — External sending

Reviewer: Codex. Rechecked on 2026-10-23 against `9610dc4` and the previous
subject-header fix.

## BUG - MEDIUM — External tasks and retries could send from an archived mailbox — fixed

The initial send refused archived mailboxes. The post-commit task and retry
path rechecked the identity but did not consistently recheck mailbox status.
For a personal/common identity, mailbox fit checked its kind and owner without
requiring it to be active. Archiving that mailbox could therefore leave a
pending send or a failed-send retry able to deliver externally.

Both paths now authorize the stored sending mailbox for write and require its
status to be active before resolving the identity. A regression archives the
personal mailbox after commit and verifies the task fails its external rows,
the transport is not invoked, and retry returns `:mailbox_archived`.

## Confirmed boundaries

Every transport call still goes through `Outbound.deliver/2`; the enabled
setting and host filter both apply, and filter failures refuse delivery.
Address-only filter changes, explicit integration selection, `skip_queue: true`
and `queue: false` remain enforced. Internal delivery remains committed when
the external portion fails. Failed-row claiming remains one atomic update;
the optional email log remains guarded, and host-recorded messages cannot be
retried. The subject normalization introduced by Claude remains correct.

The documented log-sampling limitation and cached scope permissions during an
already running send remain explicit boundaries. Nudge subject inclusion is a
host-facing privacy choice, not changed here.

Final validation is in [PR #7](../7-shared-mail-roles/CODEX_REVIEW.md).
