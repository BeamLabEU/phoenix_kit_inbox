defmodule PhoenixKitInbox.Web.ComposeFormCompactTest do
  @moduledoc """
  The compact layout of the compose form: its rows, the line that keeps the
  outside-mail warnings, the menu behind «+», the rule that a person is in
  one line, the host's slot before the subject, and a real send from it.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.RecipientSource
  alias PhoenixKitInbox.Schemas.ExternalRecipient
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Test.ComponentHostLive
  alias PhoenixKitInbox.Test.OutboundFilters
  alias PhoenixKitInbox.Test.Repo
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposeForm

  @external ["inbox", "inbox.send_external"]

  defmodule People do
    @moduledoc false
    # The people a host offers: `context.people`, narrowed by the query.
    @behaviour PhoenixKitInbox.RecipientSource
    @impl true
    def suggest(_scope, context, query) do
      for entry <- Map.get(context, :people, []),
          query == "" or String.contains?(String.downcase(entry.label), String.downcase(query)),
          do: entry
    end
  end

  defmodule Host do
    @moduledoc false
    # The wrapper of the host: tells the test what it got, and holds the send
    # while the test says so (`:compact_send_mode`).
    def around(_scope, draft, send_fun) do
      if pid = Process.whereis(:compose_compact_test), do: send(pid, {:around, self(), draft})

      case Application.get_env(:phoenix_kit_inbox, :compact_send_mode, :pass) do
        :pass ->
          send_fun.(draft)

        :hold ->
          receive do
            :go -> send_fun.(draft)
            :stop -> {:error, {:refused, "Stopped by the test."}}
          after
            5_000 -> {:error, :never_released}
          end
      end
    end
  end

  defmodule SlotHostLive do
    @moduledoc false
    # A page with the form and a host's control in its `before_subject` slot.
    use Phoenix.LiveView

    alias PhoenixKit.Users.Auth.Scope

    @impl true
    def mount(_params, session, socket) do
      [scope, draft] = Enum.map(session["stashed"], &fetch/1)

      {:ok,
       assign(socket,
         scope: scope,
         draft: draft,
         slot: session["slot"],
         test_pid: session["test_pid"],
         allowed?: Scope.can?(scope, "inbox")
       )}
    end

    @impl true
    def render(%{slot: true} = assigns) do
      ~H"""
      <.live_component
        module={ComposeForm}
        id="demo"
        scope={@scope}
        draft={@draft}
        compact={true}
        recipient_lines={:all}
        around_send={&PhoenixKitInbox.Web.ComposeFormCompactTest.Host.around/3}
      >
        <:before_subject :let={state}>
          <span id="host-slot" data-sending={to_string(state.sending)}>template</span>
        </:before_subject>
      </.live_component>
      """
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={ComposeForm}
        id="demo"
        scope={@scope}
        draft={@draft}
        compact={true}
        around_send={&PhoenixKitInbox.Web.ComposeFormCompactTest.Host.around/3}
      />
      """
    end

    @impl true
    def handle_info({:inbox_compose, _id, _what} = message, socket) do
      send(socket.assigns.test_pid, message)
      {:noreply, socket}
    end

    defp fetch({:stash, ref}), do: :persistent_term.get({ComponentHostLive, ref})
  end

  setup :outbound_setup

  setup do
    enable_inbox!()
    Process.register(self(), :compose_compact_test)
    on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :compact_send_mode) end)

    admin = user_fixture()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture(%{username: "compact_bob", first_name: "Bob"})
    {:ok, _} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, _} = Mailboxes.ensure_user_mailbox(bob)
    smtp = mail_integration_fixture(:system, username: "noreply@company.test")
    senders = grant_role!(alice, @external)
    manager = scope_for(admin, ["inbox", "inbox.manage_shared"])

    {:ok, _common} =
      Identities.create_shared(manager, %{
        "label" => "Common",
        "from_name" => "Company",
        "integration_uuid" => smtp
      })

    %{alice: alice, bob: bob, scope: scope_for(alice, @external, [senders])}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp people(ctx) do
    [
      %{
        user: ctx.bob.uuid,
        label: "Bob M",
        route: :internal,
        group: "Team",
        note: "  Designer  "
      },
      %{address: "Carol@Client.test", label: "Carol", route: :email, group: "Client"},
      %{address: "dave@client.test", label: "Dave", route: :email, group: "Client"}
    ]
  end

  defp draft(ctx, attrs \\ []) do
    struct!(
      ComposeDraft,
      Keyword.merge(
        [to: [], subject: "Offer", body: "Hello", context: %{people: people(ctx)}],
        attrs
      )
    )
  end

  defp mount_form(ctx, conn, draft, extra \\ %{}) do
    scope = ComponentHostLive.stash(ctx.scope)
    stashed = ComponentHostLive.stash(draft)

    on_exit(fn ->
      ComponentHostLive.unstash(scope)
      ComponentHostLive.unstash(stashed)
    end)

    base = %{
      id: "demo",
      draft: stashed,
      scope: scope,
      compact: true,
      recipient_sources: [People],
      around_send: {:capture, Host, :around, 3}
    }

    conn =
      Plug.Test.init_test_session(conn, %{
        "component" => ComposeForm,
        "assigns" => Map.merge(base, extra),
        "test_pid" => self()
      })

    {:ok, view, _html} = live(conn, "/component-host")
    view
  end

  defp q(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp texts(view, selector), do: view |> q(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))
  defp attr(view, selector, name), do: view |> q(selector) |> LazyHTML.attribute(name)
  defp chips(view, role), do: texts(view, "#compose-demo-#{role} li[id^=compose-demo-chip-]")

  defp forge(view, event, value),
    do: view |> with_target("#compose-form-demo") |> render_click(event, value)

  defp open_menu(view, role),
    do: view |> element("#compose-demo-#{role}-picker") |> render_click()

  defp menu?(view, role), do: has_element?(view, "#compose-demo-#{role}-menu")

  defp tick(view, role, label),
    do: view |> element("#compose-demo-#{role}-menu button[role=option]", label) |> render_click()

  defp done(view, role), do: view |> element("#compose-demo-#{role}-menu-done") |> render_click()

  defp type_add(view, role, text),
    do: view |> form("#compose-demo-#{role}-form", %{"query" => text}) |> render_submit()

  defp submit(view), do: view |> form("#compose-demo-form") |> render_submit()

  defp mount_slot_host(ctx, conn, slot?, scope \\ nil) do
    scope = ComponentHostLive.stash(scope || ctx.scope)
    stashed = ComponentHostLive.stash(draft(ctx, to: [%{user: ctx.bob.uuid, route: :internal}]))

    on_exit(fn ->
      ComponentHostLive.unstash(scope)
      ComponentHostLive.unstash(stashed)
    end)

    {:ok, view, _html} =
      live_isolated(conn, SlotHostLive,
        session: %{"stashed" => [scope, stashed], "slot" => slot?, "test_pid" => self()}
      )

    view
  end

  # ── the rows ────────────────────────────────────────────────────────────────

  describe "the compact layout" do
    test "has the rows a host can rely on", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx), %{recipient_lines: :all})

      for id <- ~w(from to cc bcc attachments form subject body to-input cc-input bcc-input
                   to-form to-picker) do
        assert has_element?(view, "#compose-demo-#{id}"), "no #compose-demo-#{id}"
      end

      refute has_element?(view, "#compose-demo-summary")
      refute menu?(view, "to")
    end

    test "the default layout has no picker button inside the field", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx), %{compact: false})

      refute has_element?(view, "#compose-demo-to-picker")
      assert has_element?(view, "#compose-demo-summary") == false
      assert has_element?(view, "button[phx-click=toggle_picker][phx-value-role=to]")
    end

    test "a chip's list keeps its semantics and the plus announces its menu",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx, to: [%{address: "a@example.com", route: :email}]))

      assert has_element?(view, "#compose-demo-to ul[role=list]")
      assert attr(view, "#compose-demo-to-picker", "aria-haspopup") == ["true"]
      assert attr(view, "#compose-demo-to-picker", "aria-controls") == ["compose-demo-to-menu"]
      assert attr(view, "#compose-demo-to-picker", "aria-expanded") == ["false"]

      open_menu(view, "to")
      assert attr(view, "#compose-demo-to-picker", "aria-expanded") == ["true"]
    end
  end

  # ── the outside-mail line ───────────────────────────────────────────────────

  describe "the line about outside mail" do
    defp outside(ctx, attrs \\ []),
      do:
        draft(
          ctx,
          Keyword.merge([to: [%{address: "client@example.com", route: :email}]], attrs)
        )

    defp notice(view), do: view |> q("#compose-demo-summary-notice") |> LazyHTML.text()

    test "is not there when the rows say it all", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx, to: [%{user: ctx.bob.uuid, route: :internal}]))

      refute has_element?(view, "#compose-demo-summary-notice")
      refute has_element?(view, "#compose-demo-summary")
    end

    test "says where the outside mail goes out as", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, outside(ctx))

      assert notice(view) =~ "Company <noreply@company.test>"
      refute has_element?(view, "#compose-demo-summary")
    end

    test "says that outside mail is not set up", %{conn: conn} = ctx do
      {:ok, _} = PhoenixKitInbox.set_external_enabled(false)
      view = mount_form(ctx, conn, outside(ctx))

      assert notice(view) =~ "Outside mail is not set up, so it will not go out."
    end

    test "says that the mail rules refuse it", %{conn: conn} = ctx do
      PhoenixKitInbox.DataCase.outbound_filter({OutboundFilters, :refuse})
      view = mount_form(ctx, conn, outside(ctx))

      assert notice(view) =~ "the mail rules refuse it"
    end

    test "says where the mail rules send it", %{conn: conn} = ctx do
      PhoenixKitInbox.DataCase.outbound_filter({OutboundFilters, :redirect})
      view = mount_form(ctx, conn, outside(ctx))

      assert notice(view) =~ "outside mail goes to"
      assert notice(view) =~ "redirect@test.example"
    end

    test "follows the line as people come and go", %{conn: conn} = ctx do
      view =
        mount_form(ctx, conn, draft(ctx, to: [%{user: ctx.bob.uuid, route: :internal}]), %{
          recipient_lines: :all
        })

      refute has_element?(view, "#compose-demo-summary-notice")

      open_menu(view, "cc")
      tick(view, "cc", "Dave")
      assert has_element?(view, "#compose-demo-summary-notice")

      tick(view, "cc", "Dave")
      refute has_element?(view, "#compose-demo-summary-notice")
    end
  end

  # ── the menu behind «+» ─────────────────────────────────────────────────────

  describe "the menu" do
    test "opens with tabs, the people, their addresses and notes", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      open_menu(view, "to")

      assert menu?(view, "to")
      assert texts(view, "#compose-demo-to-menu [role=tab]") == ["All", "Team", "Client"]
      assert has_element?(view, "#compose-demo-to-menu-q[phx-mounted]")

      rows = texts(view, "#compose-demo-to-menu button[role=option]")
      assert length(rows) == 3
      assert Enum.any?(rows, &(&1 =~ "Bob M" and &1 =~ "Designer" and &1 =~ "@compact_bob"))
      assert Enum.any?(rows, &(&1 =~ "Carol" and &1 =~ "Carol@Client.test"))
    end

    test "a note is a neutral badge", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      open_menu(view, "to")

      assert has_element?(view, "#compose-demo-to-menu .badge.badge-ghost", "Designer")
      refute has_element?(view, "#compose-demo-to-menu .badge-warning")
    end

    test "a press ticks a person in, another takes them off; the menu stays",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      open_menu(view, "to")

      tick(view, "to", "Carol")
      assert menu?(view, "to")
      assert Enum.any?(chips(view, "to"), &(&1 =~ "Carol"))
      assert has_element?(view, "#compose-demo-to-menu button[aria-selected=true]", "Carol")

      tick(view, "to", "Carol")
      assert menu?(view, "to")
      assert chips(view, "to") == []
      assert has_element?(view, "#compose-demo-to-menu button[aria-selected=false]", "Carol")
    end

    test "Done closes it and the field gets the focus back", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      open_menu(view, "to")
      tick(view, "to", "Dave")

      assert attr(view, "#compose-demo-to-menu-done", "phx-click") |> hd() =~
               "compose-demo-to-input"

      done(view, "to")

      refute menu?(view, "to")
      assert Enum.any?(chips(view, "to"), &(&1 =~ "Dave"))
    end

    test "the plus is inside what a press outside closes", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      refute has_element?(view, "[phx-click-away]")

      open_menu(view, "to")

      # One element holds the field, the plus and the menu: LiveView sends a
      # click-away before the click's own event, so on the plus (inside it)
      # none is sent, and the plus alone closes the menu.
      assert has_element?(
               view,
               ~s(#compose-demo-to [phx-click-away="close_picker"] #compose-demo-to-picker)
             )

      assert has_element?(
               view,
               ~s(#compose-demo-to [phx-click-away="close_picker"] #compose-demo-to-menu)
             )

      refute has_element?(view, "#compose-demo-to-menu[phx-click-away]")

      open_menu(view, "to")
      refute menu?(view, "to")
      refute has_element?(view, "[phx-click-away]")
    end

    test "a press outside closes it, and Escape too; the typed text stays", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      open_menu(view, "to")
      forge(view, "close_picker", %{})
      refute menu?(view, "to")

      open_menu(view, "to")
      assert has_element?(view, ~s(#compose-demo-to [phx-key=Escape][phx-keydown]))

      view
      |> element("#compose-demo-to [phx-keydown]")
      |> render_keydown(%{"key" => "Escape"})

      refute menu?(view, "to")
    end

    test "a tab shows one group, the field searches", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      open_menu(view, "to")

      view |> element("#compose-demo-to-menu [role=tab]", "Client") |> render_click()
      rows = texts(view, "#compose-demo-to-menu button[role=option]")
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1 =~ ~r/Carol|Dave/))
      assert has_element?(view, "#compose-demo-to-menu [role=tab][aria-selected=true]", "Client")

      view |> form("#compose-demo-to-menu-search", %{"q" => "dav"}) |> render_change()
      assert [row] = texts(view, "#compose-demo-to-menu button[role=option]")
      assert row =~ "Dave"

      view |> form("#compose-demo-to-menu-search", %{"q" => "nobody"}) |> render_change()
      assert has_element?(view, "#compose-demo-to-menu", "No addresses found.")
    end

    test "says where a person already is", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx), %{recipient_lines: :all})
      open_menu(view, "to")
      tick(view, "to", "Carol")
      done(view, "to")

      open_menu(view, "cc")
      assert has_element?(view, "#compose-demo-cc-menu [data-menu-elsewhere]", "To")
    end

    test "a full line says so and takes no more", %{conn: conn} = ctx do
      many =
        for n <- 1..6,
            do: %{address: "p#{n}@client.test", label: "Person #{n}", route: :email, group: "G"}

      view = mount_form(ctx, conn, draft(ctx, context: %{people: many}), %{recipient_lines: :all})
      open_menu(view, "cc")

      for n <- 1..6, do: tick(view, "cc", "Person #{n}")

      assert length(chips(view, "cc")) == 5
      assert has_element?(view, "#compose-demo-cc-error[role=alert]")
      assert menu?(view, "cc")
    end

    test "an account with no address is shown and cannot be ticked", %{conn: conn} = ctx do
      gone = %{user: Ecto.UUID.generate(), label: "Ghost", route: :email, group: "G"}
      view = mount_form(ctx, conn, draft(ctx, context: %{people: [gone]}))
      open_menu(view, "to")

      assert has_element?(view, "#compose-demo-to-menu button[disabled]", "Ghost")
      assert has_element?(view, "#compose-demo-to-menu [data-menu-no-address]", "No address")

      [id] = attr(view, "#compose-demo-to-menu button[role=option]", "id")
      forge(view, "tick", %{"id" => String.replace_prefix(id, "compose-demo-to-tick-", "")})

      assert chips(view, "to") == []
      assert menu?(view, "to")
    end

    test "events the page never offers change nothing", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))

      forge(view, "tick", %{"id" => "s-1"})
      forge(view, "picker_tab", %{"group" => "Team"})
      forge(view, "picker_search", %{"q" => "x"})
      assert chips(view, "to") == []

      open_menu(view, "to")
      forge(view, "tick", %{"id" => "s-999"})
      forge(view, "tick", %{"id" => 5})
      forge(view, "picker_tab", %{"group" => ["a"]})
      forge(view, "picker_tab", %{"group" => String.duplicate("x", 100_000)})
      forge(view, "picker_search", %{"q" => %{"a" => 1}})
      forge(view, "picker_search", %{"q" => String.duplicate("a", 10_000)})

      assert menu?(view, "to")
      assert chips(view, "to") == []
      assert [value] = attr(view, "#compose-demo-to-menu-q", "value")
      assert String.length(value) <= 320 or value == ""
    end

    test "tick, tabs and search belong to the compact layout alone", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx), %{compact: false})
      view |> element("button[phx-click=toggle_picker][phx-value-role=to]") |> render_click()
      assert has_element?(view, "#compose-demo-to-suggestions")

      before = texts(view, "#compose-demo-to-suggestions")
      forge(view, "picker_search", %{"q" => "dave"})
      forge(view, "picker_tab", %{"group" => "Client"})
      forge(view, "tick", %{"id" => "s-1"})

      assert texts(view, "#compose-demo-to-suggestions") == before
      assert chips(view, "to") == []
    end

    test "the menu carries the fit-height hook only when the host asks", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      open_menu(view, "to")
      refute has_element?(view, "#compose-demo-to-menu[phx-hook]")

      view = mount_form(ctx, conn, draft(ctx), %{fit_height: true})
      open_menu(view, "to")
      assert has_element?(view, ~s(#compose-demo-to-menu[phx-hook=PkFitHeight]))
    end
  end

  describe "the suggestions that come up while typing" do
    test "close with a press outside or Escape; what was typed stays", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))

      render_change(view |> form("#compose-demo-to-form"), %{"query" => "car"})
      assert has_element?(view, "#compose-demo-to-suggestions")
      assert has_element?(view, ~s(#compose-demo-to [phx-click-away="close_picker"]))

      forge(view, "close_picker", %{})
      refute has_element?(view, "#compose-demo-to-suggestions")
      assert attr(view, "#compose-demo-to-input", "value") == ["car"]

      render_change(view |> form("#compose-demo-to-form"), %{"query" => "dav"})
      assert has_element?(view, "#compose-demo-to-suggestions")

      view |> element("#compose-demo-to [phx-keydown]") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#compose-demo-to-suggestions")
    end
  end

  # ── one person, one line ────────────────────────────────────────────────────

  describe "a person is in one line at a time" do
    test "ticked into another line they move there", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx), %{recipient_lines: :all})
      open_menu(view, "to")
      tick(view, "to", "Carol")
      done(view, "to")

      open_menu(view, "cc")
      tick(view, "cc", "Carol")

      refute Enum.any?(chips(view, "to"), &(&1 =~ "Carol"))
      assert Enum.any?(chips(view, "cc"), &(&1 =~ "Carol"))
    end

    test "typed into another line, in any case, they move there", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx), %{recipient_lines: :all})
      open_menu(view, "cc")
      tick(view, "cc", "Carol")
      done(view, "cc")

      type_add(view, "bcc", "CAROL@client.TEST")

      refute Enum.any?(chips(view, "cc"), &(&1 =~ ~r/carol/i))
      assert Enum.any?(chips(view, "bcc"), &(&1 =~ ~r/carol/i))
    end

    test "an account and the same address are one person", %{conn: conn} = ctx do
      both = [
        %{user: ctx.bob.uuid, label: "Bob account", route: :email, group: "G"},
        %{address: ctx.bob.email, label: "Bob address", route: :email, group: "G"}
      ]

      view =
        mount_form(ctx, conn, draft(ctx, context: %{people: both}), %{recipient_lines: :all})

      open_menu(view, "to")
      tick(view, "to", "Bob account")
      assert length(chips(view, "to")) == 1
      done(view, "to")

      open_menu(view, "cc")
      tick(view, "cc", "Bob address")

      assert chips(view, "to") == []
      assert length(chips(view, "cc")) == 1
    end
  end

  # ── what the menu costs ─────────────────────────────────────────────────────

  describe "queries" do
    defp count_user_queries(view, fun) do
      pid = view.pid
      me = self()
      id = "compact-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:phoenix_kit_inbox, :test, :repo, :query],
        fn _event, _measure, meta, _ ->
          if self() == pid and meta.source == "phoenix_kit_users", do: send(me, :users_query)
        end,
        nil
      )

      fun.()
      :telemetry.detach(id)
      drain(0)
    end

    defp drain(n) do
      receive do
        :users_query -> drain(n + 1)
      after
        0 -> n
      end
    end

    test "opening the menu and one search read the accounts once, not once each",
         %{conn: conn} = ctx do
      accounts =
        for n <- 1..50 do
          user = user_fixture(%{first_name: "P#{n}", last_name: "X"})
          %{user: user.uuid, label: "P#{n}", route: :email, group: "G"}
        end

      view = mount_form(ctx, conn, draft(ctx, context: %{people: accounts}))

      assert count_user_queries(view, fn -> open_menu(view, "to") end) == 1
      assert length(texts(view, "#compose-demo-to-menu button[role=option]")) == 50

      searched =
        count_user_queries(view, fn ->
          view |> form("#compose-demo-to-menu-search", %{"q" => "P1"}) |> render_change()
        end)

      assert searched == 1
    end
  end

  # ── the host's slot ─────────────────────────────────────────────────────────

  describe "before_subject" do
    test "sits between the recipient lines and the subject, and gets sending",
         %{conn: conn} = ctx do
      Application.put_env(:phoenix_kit_inbox, :compact_send_mode, :hold)
      view = mount_slot_host(ctx, conn, true)
      html = render(view)

      {bcc_at, _} = :binary.match(html, ~s(id="compose-demo-bcc"))
      {slot_at, _} = :binary.match(html, ~s(id="compose-demo-before-subject"))
      {subject_at, _} = :binary.match(html, ~s(id="compose-demo-subject"))
      assert bcc_at < slot_at and slot_at < subject_at

      refute has_element?(view, "#compose-demo-form #host-slot")
      assert attr(view, "#host-slot", "data-sending") == ["false"]

      submit(view)
      assert_receive {:around, task, _}, 2000
      assert attr(view, "#host-slot", "data-sending") == ["true"]

      send(task, :stop)
      eventually(fn -> attr(view, "#host-slot", "data-sending") == ["false"] end)
    end

    test "leaves nothing behind without the slot", %{conn: conn} = ctx do
      view = mount_slot_host(ctx, conn, false)

      refute has_element?(view, "#compose-demo-before-subject")
      assert has_element?(view, "#compose-demo-subject")
    end

    test "is not rendered for a viewer without access", %{conn: conn} = ctx do
      view = mount_slot_host(ctx, conn, true, scope_for(ctx.alice, [], []))

      refute has_element?(view, "#host-slot")
      refute has_element?(view, "#compose-demo-before-subject")
    end
  end

  # ── :note ───────────────────────────────────────────────────────────────────

  describe "the :note of a suggestion" do
    defmodule Noted do
      @moduledoc false
      @behaviour PhoenixKitInbox.RecipientSource
      @impl true
      def suggest(_scope, _context, _query) do
        [
          %{address: "a@x.test", route: :email, note: "  Designer  "},
          %{address: "b@x.test", route: :email, note: String.duplicate("n", 60)},
          %{address: "c@x.test", route: :email, note: "   "},
          %{address: "d@x.test", route: :email, note: 5},
          %{address: "e@x.test", route: :email}
        ]
      end
    end

    test "is trimmed, cut to 40 characters, and left out when it is nothing",
         %{} = ctx do
      entries = RecipientSource.suggest_all([Noted], ctx.scope, %{}, "x")
      by = Map.new(entries, &{&1.address, &1})

      assert by["a@x.test"].note == "Designer"
      assert by["b@x.test"].note == String.duplicate("n", 40)

      for address <- ["c@x.test", "d@x.test", "e@x.test"],
          do: refute(Map.has_key?(by[address], :note), "#{address} has a note")
    end
  end

  # ── sending ─────────────────────────────────────────────────────────────────

  describe "with :all lines" do
    test "what was typed in Cc and Bcc and not added goes with the send", %{conn: conn} = ctx do
      for compact <- [true, false] do
        view =
          mount_form(
            ctx,
            conn,
            draft(ctx, to: [%{user: ctx.bob.uuid, route: :internal}]),
            %{recipient_lines: :all, compact: compact}
          )

        view
        |> form("#compose-demo-cc-form", %{"query" => "cc-typed@example.com"})
        |> render_change()

        view
        |> form("#compose-demo-bcc-form", %{"query" => "bcc-typed@example.com"})
        |> render_change()

        submit(view)

        assert_receive {:around, _, given}, 2000
        assert Enum.any?(given.cc, &(&1[:address] == "cc-typed@example.com"))
        assert Enum.any?(given.bcc, &(&1[:address] == "bcc-typed@example.com"))
        assert_receive {:inbox_compose, "demo", {:sent, %Message{}}}, 3000
      end
    end
  end

  describe "a real send from the compact form" do
    test "Bcc stays out of what the others see", %{conn: conn} = ctx do
      view =
        mount_form(ctx, conn, draft(ctx, to: [%{user: ctx.bob.uuid, route: :internal}]), %{
          recipient_lines: :all
        })

      open_menu(view, "cc")
      tick(view, "cc", "Carol")
      done(view, "cc")
      open_menu(view, "bcc")
      tick(view, "bcc", "Dave")
      done(view, "bcc")

      submit(view)

      assert_receive {:inbox_compose, "demo", {:sent, %Message{} = message}}, 3000
      assert message.subject == "Offer"

      # The email goes in a task after the commit: wait for its rows.
      eventually(fn ->
        rows = Repo.all(ExternalRecipient)
        rows != [] and Enum.all?(rows, &(&1.status == "sent"))
      end)

      assert [email] = collect_outbound([])
      visible = Enum.map(email.to ++ email.cc, &elem(&1, 1))

      assert "carol@client.test" in Enum.map(visible, &String.downcase/1)
      refute "dave@client.test" in visible
      assert email.bcc == [{"", "dave@client.test"}]

      for part <- [
            inspect(email.headers),
            inspect(email.reply_to),
            email.subject,
            email.html_body,
            email.text_body
          ] do
        refute part =~ "dave@client.test"
      end
    end
  end

  defp collect_outbound(acc) do
    receive do
      {:outbound, email, _, _} -> collect_outbound([email | acc])
    after
      200 -> acc
    end
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not come true")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
