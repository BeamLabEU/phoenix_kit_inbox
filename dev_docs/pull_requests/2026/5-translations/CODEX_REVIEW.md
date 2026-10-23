# PR #5 — Translations

Reviewer: Codex. Rechecked on 2026-10-23 against `9610dc4` and Claude's review.

## IMPROVEMENT - MEDIUM — Plural translations escaped catalogue validation — fixed

The catalogue test checked only singular messages. A missing Russian plural
form or a changed placeholder in a plural translation could pass that test.

Added checks for every plural entry and every form required by the locale's
plural rules, for both Estonian and Russian. Each form must be nonempty and
preserve the singular and plural source placeholders. Existing runtime checks
still exercise Russian counts 1, 3, 21 and 50.

## Confirmed

The backend and all three catalogues ship in the package. Tab and permission
metadata carry the module backend; notification and nudge localization still
use recipient locale. Extract/merge updates source references without adding,
removing or rewording any of the 226 messages. The rare persisted fallback
display name remains a snapshot in its creation locale, as previously noted.

Final validation is in [PR #7](../7-shared-mail-roles/CODEX_REVIEW.md).
