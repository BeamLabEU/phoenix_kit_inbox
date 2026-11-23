# PR #22 — Fix the Mail settings page: draw the user dashboard shell

**Author:** timujinne · **State:** merged 2026-11-23 (`7d26a88`) · **Reviewed:** 2026-11-23

**Verdict:** merged, no findings.

## Checked, fine

- The fix follows the established pattern exactly: core's and the other modules' `/dashboard/…`
  pages render `<PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>` (e.g.
  `phoenix_kit_billing`'s user profile pages); `LayoutWrapper.app_layout` gives the admin shell
  to admin paths only and hands `/dashboard/...` to the host's layout, so a host with a bare
  `<main>` layout showed this page with no header/sidebar. Now it draws the dashboard shell
  itself.
- `dashboard_assigns/1` is core's `PhoenixKitWeb.LayoutHelpers.dashboard_assigns/1`
  (`Map.take(assigns, @dashboard_layout_keys)`); the dropped `project_title` assign was only
  consumed by the old wrapper.
- The new test asserts the shell's `#dashboard-theme-dropdown` (present in core's
  `layouts/dashboard.html.heex:261`). `my_settings_live_test.exs`: 16 tests, 0 failures
  (run against local core via `PHOENIX_KIT_PATH=../phoenix_kit`).
- The AGENTS.md line about the page was corrected to match.
- The behaviour change (host chrome replaced by core's dashboard shell on this page) is called
  out in the PR body; the pre-existing "no `/dashboard` route when `user_dashboard_enabled` is
  off" issue is correctly noted as out of scope.
