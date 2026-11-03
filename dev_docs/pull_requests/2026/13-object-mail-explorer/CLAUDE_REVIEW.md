# PR #13 — The mail of an object: `ObjectMail` and an embeddable `MailExplorer`

**Author:** timujinne · **Merged:** 2026-11-03 (`4428bb1`) · **Branch:** `pr/2-object-mail-explorer`
**Reviewer:** Claude · **Reviewed:** 2026-11-03 against `a8b57df` · **Scope:** `object_mail.ex`, `web/components/{mail_explorer,mail_explorer_hooks,mail_tree}.ex`, the `access_events.ex` / `attachments.ex` hunks, the test host and tests; also Codex's follow-up in `a8b57df`

## Summary

`ObjectMail` reads the conversations about a host object that the viewer's own
mailboxes hold. `MailExplorer` is a LiveComponent a host page embeds to show
them; it can link, unlink, reply and pick letters to link.
`MailExplorerHooks` keeps the explorers current: it subscribes to link,
external-status and access events and turns them into coalesced `send_update`s.

Codex fixed stale controls and labels after a host changed its `can_link?` or
`link_label` callback. It did that by adding both callbacks to the keys that
force a reload. I reviewed the code as it stands on `main`, including that fix.

## Findings

### IMPROVEMENT - MEDIUM — A new callback from the host reloaded every page and dropped "Show more" — fixed

Codex's fix made a change of `can_link?` or `link_label` do the same as a new
filter:

- `assign(:pages, 1) |> load()` — every page of conversations read again, plus
  the picker and the attachments;
- the person sent back to page one.

That is right for a new filter, but not for a callback. A host typically writes
the callback inline:

```heex
can_link?={fn s, k, r -> Orders.can_link?(s, @order, k, r) end}
```

HEEx compiles `@order` to `assigns.order`, so the closure captures the host's
assigns. Each re-render of the host that re-evaluates the component call hands a
new closure, `!=` the old one. So an order update arriving by PubSub reset the
explorer to page one and re-read every thread. The tests used
`Function.capture/3`, which is equal each time, so they did not show it.

**Fix:** callbacks are split from the reload keys. A changed `can_link?` or
`link_label` now only clears `link_access` / `link_labels`, asks the host again
for the objects shown, and re-decides `can_pick?` (an open picker still closes
when linking is no longer allowed). No thread is read, and `pages` is kept.
`assign_pick/1` is factored out of `assign_shown/1` for this. Codex's regression
test passes unchanged.

**Test:** Show more, then the host hands new inline closures for both callbacks;
the 52 rows stay. This failed against the merged code.

### IMPROVEMENT - MEDIUM — The hook consumed the page's own events — partly changed

The hook `:halt`s every `{:inbox_message_linked, _}`,
`{:inbox_external_updated, _}` and `{:inbox_access_changed, :mailboxes}`. The
messages do not say which topic they came on, so one from a subscription of the
page's own is taken too.

- **Link and status events: kept as they are.** It is a deliberate, tested
  design, and the hook is the page's mail follower. The doc now says plainly
  that they are consumed **whatever topic brought them**, not only "the same
  topics".
- **`{:inbox_access_changed, :mailboxes}`: now passed on (`:cont`)** after the
  explorers have recorded it. A page that keeps a `ComposeForm` current needs
  it: the form's senders come from those mailboxes, and since the PR #15 review
  the host refreshes the form with `send_update(..., refresh: true)`. The hook
  already passed `:senders` on for the same reason: it cannot tell the host's
  subscription from its own. The page must have a catch-all `handle_info/2`
  anyway, as the doc requires. The test "a change of mailboxes is the
  explorer's alone" became "…is read by the explorer and passed on to the page".

### NITPICK — "Not on every render" was not tested against a host re-render — fixed

The test rendered the view twice, which only reads the client's copy. It now
also has the host re-render the component with a changed title and the same
callbacks, and checks the host is asked nothing. A comment in the
prepared-assigns test said `threads` was absent while the map passed
`threads: []`; it now says what the test does.

### NITPICK — Not changed, recorded

- **"Show more" re-reads page by page.** `read_threads/4` calls
  `list_threads/3` once per page, on every event. It is correct (duplicates are
  kept once) and bounded by the page count. One call with
  `limit: pages * @page` would be cheaper.
- **`linked_objects/1`** runs one `Links.for_message/1` per linked letter at a
  flush. It is bounded at 20 (`@max_looked_up`), and flushes are coalesced.
- **`MailTree`** draws a second root (a reply whose parent the viewer cannot
  read) indented like a reply. This is cosmetic.

## Checked and correct

- **Read scoping:**
  - Every `ObjectMail` query goes through `visible/1`: a sent message with an
    active delivery in `inbox`/`sent` of a mailbox the viewer reaches **now**
    (grants re-read, archived excluded).
  - Bcc and external statuses follow `recipient_snapshot/2` and
    `External.list_for_viewer/2`.
  - Attachments go through `list_for_viewer_many/2`, with the same policy as the
    reading pane.
  - `html_body` is stripped twice.
- **Events act only on what was loaded.** Select, reply, link and unlink act
  only on UUIDs already loaded. Links are re-checked in the context, and the
  host's `can_link?` is asked at the click.
- **Lifecycle:**
  - DOM ids are prefixed with the explorer id.
  - `attach/3` is idempotent; `detach/2` lets go of only what is unused.
  - The last detach tears everything down, including the flush timer.
- **Other:** `update/2` does no DB work when its attributes are equal. Every new
  string has et and ru translations.

## Verification

Covered by the gate run recorded in the PR #15 review (this batch).
