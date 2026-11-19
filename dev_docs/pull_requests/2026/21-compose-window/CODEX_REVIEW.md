# Review of PR #21 · Embedded compose window

Reviewed the compact recipient menu, always-visible Cc and Bcc fields, batched account lookup, template changes, and asynchronous send completion.

- **BUG - HIGH** Rendering an earlier template under the same letter key after a successful send could reset the form and generate a fresh idempotency key. The component now remembers the 32 most recent templates replaced by keyed renders. The user can still switch back to them while composing. A LiveView test sends the letter, renders the earlier template, and verifies a repeat submission is ignored.
- **BUG - HIGH** Ticking a menu recipient cleared the pending address on that line. The menu now preserves the line input on selection. The send test types a Cc address, selects a second recipient, and checks the draft handed to the send callback.
- **BUG - MEDIUM** An options-only update during a send could discard the next letter queued by the parent. Partial updates now preserve the queued draft. The test changes the visible recipient lines before releasing the send task and checks that the expected draft opens.
- **BUG - MEDIUM** An open suggestion list could outlive a change in draft context, or lack the addresses required after switching to compact layout. A template change closes the list, and a layout change rebuilds it.
- **IMPROVEMENT - MEDIUM** The batched address query loaded complete user records. It now selects only the UUID, username and email fields used to resolve addresses.

## Verification

The full suite passed with 1,502 tests. The precommit gate passed, including strict compilation, the dependency audit, Credo and Dialyzer. Gettext extraction reported the catalogs current. Menu tests exercised LiveView events and rendered markup. Browser focus, positioning and mobile layout were not manually tested.
