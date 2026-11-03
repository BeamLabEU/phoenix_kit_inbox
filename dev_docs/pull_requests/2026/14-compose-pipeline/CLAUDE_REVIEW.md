# PR #14 — The server-side half of an embedded compose form: `ComposeDraft`, `ComposePipeline`, `RecipientSource`

**Author:** timujinne · **Merged:** 2026-11-03 (`a628371`) · **Branch:** `pr/3-compose-pipeline`
**Reviewer:** Claude · **Reviewed:** 2026-11-03 against `a8b57df` · **Scope:** `web/components/{compose_draft,compose_pipeline}.ex`, `recipient_source.ex`, `recipient_sources/members.ex`, the `errors.ex` / `mailboxes.ex` / `messages.ex` hunks, their tests; also Codex's follow-up in `a8b57df`

## Summary

`ComposePipeline.run/4` turns a host's `ComposeDraft` and what a browser sent into
a checked send.

- It re-derives the sender, Reply-To, recipients and attachments from the
  scope and the draft.
- It calls the host's `around_send` wrapper with a `send_fun`.
- Inside `send_fun`, it checks that each recipient still travels the route it
  was chosen for, then calls `Messages.send_message/4`.

`RecipientSource` merges suggestions from the module's members and the host's
sources, under a supervisor with timeouts.

Codex fixed ASCII control characters echoed in `{:invalid_recipient, text}`. I
reviewed the code as it stands on `main`.

## Findings

### BUG - MEDIUM — The route check compared only the route, so a named account could reach a shared mailbox of the same name — fixed

A host names an account by UUID with `route: :internal`. `by_account/2` turns it
into the account's handle (`"@sales"`, or the login email when there is no
username). The send then resolves that **text**:

- `fetch_mailbox_by_recipient/2` looks for a member first; for `@name` and
  emails, a shared mailbox comes next.
- When the account is no member at send time, the member lookup finds nobody.
  That covers an inactive account, a customer outside the circle, and a circle
  the wrapper's process context narrows.
- The shared mailbox whose slug (or address) matches then takes the letter.

`check_routes/2` saw `:internal == :internal` and let it through, so the letter
meant for one person went to a shared mailbox other people read. The moduledoc
promised a recipient is refused when not reached "the way they were chosen".

**Fix:**

- `Messages.resolve_recipient_targets/2` (`@doc false`) is the same lookup as
  `resolve_recipient_routes/2`, plus `:user_uuid`: the owner of a personal
  mailbox, or the member who has none yet.
- `resolve_recipient_routes/2` is now that function without the key, so its
  public answer is unchanged.
- `check_routes/2` refuses an `:internal` entry chosen as an account
  (`:user`) unless it lands with that same account. The UUIDs are compared
  after `Ecto.UUID.cast/1`, so case does not matter.
- The refusal is the existing `{:route_mismatch, [...]}` ("…would not be reached
  the way they were chosen…").

**Test:** a non-member account with username `desk` next to the shared mailbox
`desk`. Before the fix the letter was delivered to the shared mailbox; now it is
refused and nothing is written. A member named by an upper-case UUID still goes.

### IMPROVEMENT - MEDIUM — `send_fun` still sent after its run was over — fixed

The "at most once" memo lives in the process dictionary and is deleted when the
wrapper returns. A wrapper that kept `send_fun` and called it later, from the
same process, therefore sent again. That repeat send used recipients, a sender
and a Reply-To authorized for an earlier run, with no read-back check. Only an
idempotency key in the draft would have stopped the duplicate; the form issues
one, an API host may not.

**Fix:** an `:atomics` flag closed by the pipeline when the wrapper answers or
ends. A later call answers `{:error, {:send_fun, :closed}}` and logs the bug,
like `:other_process`. It is garbage-collected with the closure, unlike a
process-dictionary marker. Moduledoc updated.

**Test:** a wrapper that keeps `send_fun` (after a send, and after refusing
without one); calling it later sends nothing.

### NITPICK — Labels kept the control and direction marks addresses may not have — fixed

`label/1` only trimmed. A label goes to the host's wrapper, to
`RecipientSource.remember/4` (where a NUL breaks a host's Postgres insert), and
is shown next to the address, where a bidi override could disguise it. It is now
cleaned with the same class `echo/1` strips: one `@hidden_marks` regex, shared.

### NITPICK — One person can be suggested twice (not changed)

A host source's `%{user: U}` and the members source's `%{address: "@u"}` for the
same person are merged by different keys, so both appear. The merge does what
its doc says. This is cosmetic.

### Outside the PR — fixed

`Mailboxes.shared_mailbox_suggestions/2` built `"#{name} (shared mailbox)"`
without gettext. That predates this PR (2026-08), but the members source now
shows it in compose. It is now
`gettext("%{name} (shared mailbox)", name: …)` with et and ru translations.

`ComposeForm` asks `RecipientSource.suggest_all/4` synchronously in the page
process, debounced to 300 ms. A slow source holds the page for up to its
timeout. That is PR #15's design and is recorded there.

## Checked and correct

- **Callbacks** are validated before any work: an unknown key, a wrong arity or
  a wrong container is `:invalid_callbacks`, never a direct send.
- **Sender:** taken from the scope at the send. The mailbox must be accessible;
  an identity goes through `list_usable/1` then `resolve/3`, and `:broken` is
  revealed only after `authorize_use`.
- **What comes from the draft only:** links, `html_body`, the parent, the
  idempotency key and the trusted Reply-To. Of the wrapper's draft only subject,
  body, HTML and attachments count, and they are re-checked.
- **Memo:** the key is a fresh `make_ref/0` per run, so one run's result cannot
  reach another.
- **Attachments:** picks need the host's callback, which is the only source of
  names and flags. UUIDs are cast and compared lower-case.
- **`RecipientSource`:** `async_stream_nolink` under the module's supervisor,
  `on_timeout: :kill_task`, locale handed over, a missing supervisor logged
  once.
- **Errors:** every error the pipeline or the send returns has an `Errors`
  clause; the catalogues have no empty or fuzzy entry.

## Verification

Covered by the gate run recorded in the PR #15 review (this batch).
