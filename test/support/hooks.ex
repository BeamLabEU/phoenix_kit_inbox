defmodule PhoenixKitInbox.Test.Hooks do
  @moduledoc """
  `on_mount` hooks used by the LiveView test endpoint.

  Production runs LiveViews inside `live_session :phoenix_kit_admin`,
  which is configured by core `phoenix_kit` to populate
  `socket.assigns[:phoenix_kit_current_scope]` and
  `socket.assigns[:phoenix_kit_current_user]` from the host app's
  authentication. Our test endpoint doesn't load core's hooks, so this
  module replicates the same effect by pulling scope data from the
  test session.

  Tests set scope via `LiveCase.put_test_scope/2` (which calls
  `Plug.Test.init_test_session/2`); the `:assign_scope` hook below
  reads it back and mirrors it onto socket assigns.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_navigate: 2, put_flash: 3]

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Users.Auth

  @doc """
  `on_mount` callback. Reads `"phoenix_kit_test_scope"` from session and
  assigns `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`
  onto the socket. No-op when session has no scope (LiveView mounts
  with the same nil-scope state production sees for logged-out users).
  """
  def on_mount(:assign_scope, _params, session, socket) do
    put_locale(session, socket)
    socket = attach_hook(socket, :inbox_test_scope_refresh, :handle_info, &scope_refresh/2)

    case Map.get(session, "phoenix_kit_test_scope") do
      nil ->
        {:cont, socket}

      %{user: user} = scope ->
        socket =
          socket
          |> assign(:phoenix_kit_current_scope, scope)
          |> assign(:phoenix_kit_current_user, user)

        {:cont, socket}
    end
  end

  # What core's scope refresh does once it has re-read the user
  # (`PhoenixKitWeb.Users.Auth`, `refresh_scope/3`): reassign its two assigns,
  # hand the socket to the page through core's own dispatch
  # (`refresh_view_scope_assigns/1` → `phoenix_kit_scope_changed/1`), then
  # ask core's own `scope_refresh_decision/4` whether to move the visitor
  # and, if so, navigate as core does (to `@eviction_path` here) — after the
  # page, so a page that navigated too crashes as it would in production.
  # Only the re-read of the user is left out. Tests send it through
  # `LiveCase.refresh_scope/2`.
  defp scope_refresh({:inbox_test_scope_refresh, %{user: user} = scope}, socket) do
    was_admin? = Scope.can_access_admin_area?(socket.assigns[:phoenix_kit_current_scope])

    socket =
      socket
      |> assign(:phoenix_kit_current_scope, scope)
      |> assign(:phoenix_kit_current_user, user)
      |> Auth.refresh_view_scope_assigns()

    case Auth.scope_refresh_decision(
           was_admin?,
           scope,
           socket.view,
           socket.assigns[:phoenix_kit_current_module_key]
         ) do
      :stay ->
        {:halt, socket}

      decision ->
        {:halt,
         socket
         |> put_flash(:error, "core eviction: #{decision}")
         |> push_navigate(to: eviction_path())}
    end
  end

  defp scope_refresh(_message, socket), do: {:cont, socket}

  @doc "Where the test hook sends a visitor core's scope refresh evicts."
  def eviction_path, do: "/core-eviction"

  # What core's locale hook does for every LiveView of a page: install the
  # request's locale for core's backend and the process-wide one the modules'
  # backends read. Tests ask for a locale through `LiveCase.put_test_locale/2`.
  defp put_locale(session, socket) do
    case Map.get(session, "phoenix_kit_test_locale") do
      nil -> :ok
      locale -> Auth.put_gettext_locale(locale, socket.view)
    end
  end
end
