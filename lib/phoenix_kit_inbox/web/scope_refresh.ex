defmodule PhoenixKitInbox.Web.ScopeRefresh do
  @moduledoc """
  What every Inbox page shares about a scope that changes under it.

  Each page keeps its own `:scope` and `:current_user`, copied from core's
  `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`. Core's scope
  refresh (a role or permission change, or a switch of the role acted as)
  reassigns its two assigns and then calls the page's
  `phoenix_kit_scope_changed/1`; the page copies them again with
  `assign_scope/1` and recomputes every gate and everything it derived from
  them — the same code its `mount/3` runs. An admin page that lost its
  permission is moved away by core after that; this only keeps the state
  correct meanwhile. On an older core the callback is never called.

  Mailbox grants and senders are Inbox's own rows, which core knows nothing
  about: a page subscribes to the `PhoenixKitInbox.AccessEvents` it needs
  (`subscribe/2`) and runs the same recomputation on
  `{:inbox_access_changed, _}`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKitInbox.AccessEvents

  @doc "Copies core's scope and user onto the page's `:scope` and `:current_user`."
  @spec assign_scope(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_scope(socket) do
    socket
    |> assign(:scope, socket.assigns[:phoenix_kit_current_scope])
    |> assign(:current_user, socket.assigns[:phoenix_kit_current_user])
  end

  @doc """
  Subscribes a connected page to the access events of `topics`: `:user`
  (the current user's mailboxes and personal senders) and `:senders` (the
  shared senders).
  """
  @spec subscribe(Phoenix.LiveView.Socket.t(), [:user | :senders]) ::
          Phoenix.LiveView.Socket.t()
  def subscribe(socket, topics) do
    if Phoenix.LiveView.connected?(socket) do
      if :user in topics, do: AccessEvents.subscribe_user(user_uuid(socket))
      if :senders in topics, do: AccessEvents.subscribe_senders()
    end

    socket
  end

  defp user_uuid(socket) do
    case socket.assigns[:current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end
end
