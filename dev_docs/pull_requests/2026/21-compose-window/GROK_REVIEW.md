# PR #21 — Compose window: compact menu, retext, letter key

**Author:** timujinne · **Merged:** `01d344b` (2026-11-19), with the follow-ups through that merge
**Reviewer:** Grok · **Reviewed:** 2026-11-23 · **Verdict:** approve, two fixes

The compact layout, the always-visible Cc and Bcc lines, `retext`, `letter_key`, and the menu behind «+». The follow-ups on the branch already covered the earlier template after a send, the tick that cleared a pending address, a queued draft dropped by an options-only update, a suggestion list that outlived its draft, and the address query loading whole user records.

## Checked and fine

- A new `letter_key` wins. The draft the form holds, one a retext replaced, and — after the send — the newest 32 keyed templates stay the same letter, so the button stays off. A draft the form never held is a new letter, including under the same key.
- While a send runs, a new draft wins over a waiting retext. The retext is applied after an error and dropped when the letter went. The send copies the letter at the click; later edits of the form are not what goes out.
- Tick restores the line's typed text and the open menu after adding or removing, so a menu press does not clear the field or close the menu.
- An id from a list that has already been replaced still does nothing. The tests in `compose_form_recipients_test.exs` pin that. A click is not given a second chance at the previous list.
- `letter_key` accepts a binary, an integer, or an existing atom. Anything else is no key, and `Atom.to_string/1` is only reached for an atom the caller already held.

## Findings

### BUG - MEDIUM — Escape let a debounced suggestion reopen the list (fixed)

Escape is a window binding on the wrapper, so it is not swallowed by the field's 300 ms debounce. That kept the last characters. It also closed the list at once, and the field's timer then ran `suggest/3` and opened the list again.

`close_list/3` now blurs the line's field first. The blur flushes the pending change, the close is the next event, and the timer cannot open the list afterwards. The focus then returns to the line. A menu search pending at the same moment is sent after the close, and `picker_search` with no open list does nothing.

`compose_form_compact_test.exs` decodes the binding: blur, then `close_picker`, then focus. LiveViewTest does not run the timer.

### BUG - MEDIUM — A fast click on a row missed, because the field blurred first (fixed)

The line's field and the menu search use `phx-debounce="300"`. A click on a row blurs that field, LiveView flushes the pending change before the click, and the new list has new ids. `tick` and `pick` look the id up in the list that is open now, so the click did nothing.

The row buttons use `onmousedown="event.preventDefault()"`, which keeps the focus in the field. The list is not rebuilt before the click, and the id is still in it. An id from a list that has already changed is still ignored, which is the rule the recipient tests lock.

The compact tests assert the attribute on the menu rows and on the typed suggestions, and that a tick of an id from the previous search still adds nobody.

## Left as is

### NITPICK — Escape also reaches a host dialog

The module ships no script, so it cannot stop the key. The moduledoc says so. Not changed.

### NITPICK — `fit_height` needs a core hook that is not released yet

`PkFitHeight` is opt-in. A core without it logs an unknown hook. Documented. Not changed.

### NITPICK — The form can still be edited while a send runs

`add`, `remove` and `tick` are not frozen while `@sending` is set. The task already holds the letter from the click, so the send is the letter that was submitted. The form on screen can diverge until the answer. Freezing every control would also freeze the text the person is still looking at. Not changed.

Browser focus, menu position and a narrow viewport were not exercised. The checks are the LiveView tests and the markup of the key binding.
