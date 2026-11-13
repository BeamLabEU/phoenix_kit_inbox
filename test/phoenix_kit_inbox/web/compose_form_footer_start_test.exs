defmodule PhoenixKitInbox.Web.ComposeFormFooterStartTest do
  @moduledoc """
  `footer_start` of the compose form: the host's own control at the start of
  the form's last row, on the other side from Cancel and Send (a «Back» of a
  host window whose second step is the form). The slot gets whether a send
  runs; what the control does is the host's.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Test.ComponentHostLive
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposeForm

  defmodule BackHostLive do
    @moduledoc false
    # A page that opens the form with a «Back» of its own in `footer_start`.
    use Phoenix.LiveView

    @impl true
    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         scope: fetch(session["scope"]),
         draft: fetch(session["draft"]),
         back?: session["back?"],
         test_pid: session["test_pid"]
       )}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <%= if @back? do %>
        <.live_component module={ComposeForm} id="demo" scope={@scope} draft={@draft}>
          <:footer_start :let={state}>
            <button
              type="button"
              id="host-back"
              data-sending={to_string(state.sending)}
              phx-click="back"
            >
              Back
            </button>
          </:footer_start>
        </.live_component>
      <% else %>
        <.live_component module={ComposeForm} id="demo" scope={@scope} draft={@draft} />
      <% end %>
      """
    end

    @impl true
    def handle_event("back", _params, socket) do
      send(socket.assigns.test_pid, :host_back)
      {:noreply, socket}
    end

    @impl true
    def handle_info(_message, socket), do: {:noreply, socket}

    defp fetch({:stash, ref}), do: :persistent_term.get({ComponentHostLive, ref})
  end

  @external ["inbox", "inbox.send_external"]

  setup :outbound_setup

  setup do
    enable_inbox!()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    {:ok, _} = Mailboxes.ensure_user_mailbox(alice)
    senders = grant_role!(alice, @external)
    %{scope: scope_for(alice, @external, [senders])}
  end

  defp mount_page(ctx, conn, back?) do
    scope = ComponentHostLive.stash(ctx.scope)

    draft =
      ComponentHostLive.stash(%ComposeDraft{
        to: [%{address: "client@example.com", route: :email}],
        subject: "Offer",
        body: "Hello"
      })

    on_exit(fn ->
      ComponentHostLive.unstash(scope)
      ComponentHostLive.unstash(draft)
    end)

    {:ok, view, _html} =
      live_isolated(conn, BackHostLive,
        session: %{"scope" => scope, "draft" => draft, "back?" => back?, "test_pid" => self()}
      )

    view
  end

  test "without the slot the last row holds Cancel and Send alone", %{conn: conn} = ctx do
    view = mount_page(ctx, conn, false)

    refute has_element?(view, "#compose-demo-footer-start")
    assert has_element?(view, "#compose-form-demo button[phx-click=cancel]")
  end

  test "the host's control sits at the start of the last row, before Cancel and Send",
       %{conn: conn} = ctx do
    view = mount_page(ctx, conn, true)

    assert has_element?(view, "#compose-demo-footer-start #host-back")
    # Not sending: the slot is told so.
    assert has_element?(view, "#host-back[data-sending=false]")

    html = render(view)
    {back_at, _} = :binary.match(html, "host-back")
    {cancel_at, _} = :binary.match(html, ~s(phx-click="cancel"))
    assert back_at < cancel_at
  end

  test "the control is the host's: its event goes to the page, the form stays",
       %{conn: conn} = ctx do
    view = mount_page(ctx, conn, true)

    view |> element("#host-back") |> render_click()

    assert_receive :host_back
    assert has_element?(view, "#compose-form-demo")
  end
end
