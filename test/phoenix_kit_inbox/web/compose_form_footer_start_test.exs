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
      test_pid = session["test_pid"]

      {:ok,
       assign(socket,
         scope: fetch(session["scope"]),
         draft: fetch(session["draft"]),
         back?: session["back?"],
         test_pid: test_pid,
         # Holds every send until the test says :go, so a test can look at
         # the form while a send runs.
         around_send: fn _scope, draft, send_fun ->
           send(test_pid, {:around, self()})

           receive do
             :go -> send_fun.(draft)
           after
             5_000 -> {:error, :never_released}
           end
         end
       )}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <%= if @back? do %>
        <.live_component
          module={ComposeForm}
          id="demo"
          scope={@scope}
          draft={@draft}
          around_send={@around_send}
        >
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

  defp eventually(check, tries \\ 40) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(check, tries - 1)
    end
  end

  test "without the slot the last row holds Cancel and Send alone", %{conn: conn} = ctx do
    view = mount_page(ctx, conn, false)

    refute has_element?(view, "#compose-demo-footer-start")
    assert has_element?(view, "#compose-form-demo button[phx-click=cancel]")
  end

  test "the host's control sits at the start of the last row, before Cancel and Send",
       %{conn: conn} = ctx do
    view = mount_page(ctx, conn, true)

    # The form's last row: the slot first, then Cancel and Send after it.
    row = "#compose-form-demo > div:last-child"
    assert has_element?(view, "#{row} > #compose-demo-footer-start #host-back")
    assert has_element?(view, "#{row} > #compose-demo-footer-start ~ button[phx-click=cancel]")
    assert has_element?(view, "#{row} > #compose-demo-footer-start ~ button[type=submit]")
    # Not sending: the slot is told so.
    assert has_element?(view, "#host-back[data-sending=false]")
  end

  test "while a send runs the slot is told so, and again when it is over",
       %{conn: conn} = ctx do
    view = mount_page(ctx, conn, true)

    view
    |> form("#compose-demo-form", %{"subject" => "Offer", "body" => "Hello"})
    |> render_submit()

    assert_receive {:around, task}, 2000
    assert has_element?(view, "#host-back[data-sending=true]")

    send(task, :go)
    assert eventually(fn -> has_element?(view, "#host-back[data-sending=false]") end)
  end

  test "an update that leaves footer_start out keeps the host's control",
       %{conn: conn} = ctx do
    view = mount_page(ctx, conn, true)

    # Only the form gets the update; the page does not render again, so the
    # slot is not passed this time.
    Phoenix.LiveView.send_update(view.pid, ComposeForm, id: "demo", around_send: nil)
    render(view)

    assert has_element?(view, "#compose-demo-footer-start #host-back")
  end

  test "a viewer without access keeps the host's control, and nothing of the form",
       %{conn: conn, scope: scope} = ctx do
    denied = scope_for(scope.user, [])
    view = mount_page(%{ctx | scope: denied}, conn, true)

    assert has_element?(view, "#compose-form-demo > #compose-demo-footer-start #host-back")
    assert has_element?(view, "#host-back[data-sending=false]")
    refute has_element?(view, "#compose-demo-form")
    refute has_element?(view, "#compose-form-demo button[phx-click=cancel]")

    view |> element("#host-back") |> render_click()
    assert_receive :host_back
  end

  test "the control is the host's: its event goes to the page, the form stays",
       %{conn: conn} = ctx do
    view = mount_page(ctx, conn, true)

    view |> element("#host-back") |> render_click()

    assert_receive :host_back
    assert has_element?(view, "#compose-form-demo")
  end
end
