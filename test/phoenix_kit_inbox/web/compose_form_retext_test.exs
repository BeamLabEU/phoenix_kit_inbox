defmodule PhoenixKitInbox.Web.ComposeFormRetextTest do
  @moduledoc """
  Another text for the letter the form holds (`retext`, or the same
  `letter_key` with another draft): the text and the sender's defaults come
  from the new draft; the recipients, what is typed, the files and the key
  stay. The host may take three routes and none of them may lose the letter.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Test.ComponentHostLive
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposeForm

  defmodule HostLive do
    @moduledoc false
    # A page holding one form. Its events are the host's callbacks: each does
    # what a real page does, in the order it does it.
    use Phoenix.LiveView

    alias PhoenixKitInbox.Test.ComponentHostLive
    alias PhoenixKitInbox.Web.Components.ComposeForm

    @impl true
    def mount(_params, session, socket) do
      drafts = fetch(session["drafts"])
      test_pid = session["test_pid"]

      {:ok,
       assign(socket,
         scope: fetch(session["scope"]),
         drafts: drafts,
         draft: drafts["d0"],
         letter_key: session["letter_key"],
         tick: 0,
         test_pid: test_pid,
         around_send: fn _scope, draft, send_fun ->
           send(test_pid, {:around, self(), draft})
           act(Application.get_env(:phoenix_kit_inbox, :retext_mode, :pass), draft, send_fun)
         end
       )}
    end

    defp act(:pass, draft, send_fun), do: send_fun.(draft)
    defp act(:error, _draft, _send_fun), do: {:error, {:refused, "Not now."}}

    defp act(:hold, draft, send_fun) do
      receive do
        :go -> send_fun.(draft)
        :stop -> {:error, {:refused, "Stopped by the test."}}
      after
        5_000 -> {:error, :never_released}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <span id="tick">{@tick}</span>
      <.live_component
        module={ComposeForm}
        id="demo"
        scope={@scope}
        draft={@draft}
        letter_key={@letter_key}
        tick={@tick}
        around_send={@around_send}
      />
      """
    end

    @impl true
    # The host says the draft (a render with it), the letter, or both.
    def handle_event("assign", %{"draft" => key} = params, socket) do
      socket = assign(socket, draft: socket.assigns.drafts[key])
      {:noreply, if(params["key"], do: assign(socket, letter_key: params["key"]), else: socket)}
    end

    def handle_event("retext", %{"draft" => key}, socket) do
      send_update(ComposeForm, id: "demo", retext: socket.assigns.drafts[key])
      {:noreply, socket}
    end

    # Both in one callback: the render comes before the update's message.
    def handle_event("assign_and_retext", %{"draft" => key}, socket) do
      send_update(ComposeForm, id: "demo", retext: socket.assigns.drafts[key])
      {:noreply, assign(socket, draft: socket.assigns.drafts[key])}
    end

    # A render that changes an attribute of the form (here a counter it ignores),
    # so that LiveView updates the component with every attribute again, the
    # draft the host still passes among them.
    def handle_event("rerender", _params, socket),
      do: {:noreply, update(socket, :tick, &(&1 + 1))}

    @impl true
    def handle_info({:inbox_compose, _id, _what} = message, socket) do
      send(socket.assigns.test_pid, message)
      {:noreply, socket}
    end

    defp fetch({:stash, ref}), do: :persistent_term.get({ComponentHostLive, ref})
  end

  @external ["inbox", "inbox.send_external"]

  setup :outbound_setup

  setup do
    enable_inbox!()
    on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :retext_mode) end)

    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture(%{username: "retext_bob", first_name: "Bob"})
    {:ok, _} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, _} = Mailboxes.ensure_user_mailbox(bob)
    senders = grant_role!(alice, @external)
    smtp = mail_integration_fixture(:system, username: "noreply@company.test")
    manager = scope_for(user_fixture(), ["inbox", "inbox.manage_shared"])

    {:ok, common} =
      Identities.create_shared(manager, %{
        "label" => "Common",
        "from_name" => "Company",
        "integration_uuid" => smtp
      })

    %{
      alice: alice,
      bob: bob,
      common: common,
      scope: scope_for(alice, @external, [senders])
    }
  end

  defp mode(mode), do: Application.put_env(:phoenix_kit_inbox, :retext_mode, mode)

  defp stash(value) do
    stashed = ComponentHostLive.stash(value)
    on_exit(fn -> ComponentHostLive.unstash(stashed) end)
    stashed
  end

  defp draft(attrs) do
    struct!(
      ComposeDraft,
      Keyword.merge([to: [%{address: "@retext_bob", label: "Bob", route: :internal}]], attrs)
    )
  end

  defp three_drafts do
    %{
      "d0" => draft(subject: "S0", body: "B0"),
      "d1" => draft(subject: "S1", body: "B1", body_format: "markdown", html_body: "<p>1</p>"),
      "d2" => draft(subject: "S2", body: "B2")
    }
  end

  defp mount_host(ctx, conn, drafts, session \\ %{}, scope \\ nil) do
    session =
      Map.merge(
        %{
          "scope" => stash(scope || ctx.scope),
          "drafts" => stash(drafts),
          "test_pid" => self()
        },
        session
      )

    {:ok, view, _html} = live_isolated(conn, HostLive, session: session)
    view
  end

  defp q(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp texts(view, selector), do: view |> q(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))
  defp subject(view), do: view |> q("#compose-demo-subject") |> LazyHTML.attribute("value")
  defp body(view), do: texts(view, "#compose-demo-body")
  defp chips(view), do: texts(view, "#compose-demo-to li[id^=compose-demo-chip-]")
  defp host(view, event, draft), do: render_click(view, event, %{"draft" => draft})

  defp host(view, event, draft, key),
    do: render_click(view, event, %{"draft" => draft, "key" => key})

  defp sent?(view), do: has_element?(view, "#compose-demo-sent")

  # The person adds an outside recipient (its send is not what these tests
  # are about: outside mail is not set up here) and types a text of their own.
  defp write(view) do
    view |> form("#compose-demo-to-form", %{"query" => "added@example.com"}) |> render_submit()
    write_text(view)
  end

  defp write_text(view) do
    view
    |> form("#compose-demo-form", %{"subject" => "typed", "body" => "typed body"})
    |> render_change()
  end

  defp submit(view), do: view |> form("#compose-demo-form") |> render_submit()

  defp letter_kept?(view), do: Enum.any?(chips(view), &(&1 =~ "added@example.com"))

  describe "what a retext replaces and what it keeps" do
    test "the text comes from the draft; recipients, typed address and key stay",
         %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())
      write(view)

      mode(:error)
      submit(view)
      assert_receive {:around, _, %{idempotency_key: key}}, 2000
      assert render(view) =~ "Not now."

      view |> form("#compose-demo-to-form", %{"query" => "half@typed.example"}) |> render_change()
      host(view, "retext", "d1")

      assert subject(view) == ["S1"]
      assert body(view) == ["B1"]
      assert letter_kept?(view)
      assert render(view) =~ ~s(value="half@typed.example")
      refute render(view) =~ "Not now."

      submit(view)
      assert_receive {:around, _, given}, 2000
      assert given.idempotency_key == key
    end

    test "the draft's own text and hidden parts reach the send", %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())

      host(view, "retext", "d1")
      submit(view)

      assert_receive {:around, _, given}, 2000
      assert given.html_body == "<p>1</p>"
      assert given.body_format == "markdown"
      assert_receive {:inbox_compose, "demo", {:sent, %Message{subject: "S1", body: "B1"}}}, 3000
    end

    test "a retext applies to the draft the form holds", %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())
      assert subject(view) == ["S0"]

      host(view, "retext", "d1")
      assert subject(view) == ["S1"]
    end

    test "a form that holds no draft (no access) has nothing to retext", %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts(), %{}, scope_for(ctx.alice, [], []))

      host(view, "retext", "d1")

      refute has_element?(view, "#compose-demo-form")
    end
  end

  describe "the three routes of a host" do
    test "(a) the host keeps passing the first draft", %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())
      write(view)

      host(view, "retext", "d1")
      render_click(view, "rerender", %{})
      assert subject(view) == ["S1"]
      assert letter_kept?(view)

      host(view, "retext", "d2")
      render_click(view, "rerender", %{})
      assert subject(view) == ["S2"]
      assert letter_kept?(view)
    end

    test "(b) the host assigns the draft and retexts in one callback", %{conn: conn} = ctx do
      # The render comes before the update's message. Without a key that is a
      # new draft; with `letter_key` it is the same letter, and the update
      # that follows changes nothing.
      view = mount_host(ctx, conn, three_drafts(), %{"letter_key" => "letter-1"})
      write(view)

      host(view, "assign_and_retext", "d1")

      assert subject(view) == ["S1"]
      assert letter_kept?(view)
    end

    test "(b) without a letter_key a render with another draft is a new letter",
         %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())
      write(view)

      host(view, "assign_and_retext", "d1")

      assert subject(view) == ["S1"]
      refute letter_kept?(view)
    end

    test "(c) the host renders the draft it retexted, then retexts again", %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())
      write(view)

      host(view, "retext", "d1")
      host(view, "assign", "d1")
      assert subject(view) == ["S1"]
      assert letter_kept?(view)

      host(view, "retext", "d2")
      assert subject(view) == ["S2"]

      # Any render that still passes d1 (or d0) is the same letter.
      render_click(view, "rerender", %{})
      assert subject(view) == ["S2"]
      assert letter_kept?(view)

      host(view, "assign", "d0")
      assert subject(view) == ["S2"]
      assert letter_kept?(view)
    end

    test "a draft the form never held is a new letter", %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())
      write(view)
      host(view, "retext", "d1")

      host(view, "assign", "d2")

      assert subject(view) == ["S2"]
      refute letter_kept?(view)
    end

    test "with a letter_key another draft is another text of the same letter",
         %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts(), %{"letter_key" => "letter-1"})
      write(view)

      host(view, "assign", "d1")
      assert subject(view) == ["S1"]
      assert letter_kept?(view)

      # Back to an earlier text: the host said so, and the key is the same.
      host(view, "assign", "d0")
      assert subject(view) == ["S0"]
      assert letter_kept?(view)
    end

    test "a new letter_key is a new letter, even for a draft the form had replaced",
         %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts(), %{"letter_key" => "a"})
      write(view)
      host(view, "retext", "d1")
      assert letter_kept?(view)

      host(view, "assign", "d0", "b")

      assert subject(view) == ["S0"]
      refute letter_kept?(view)
    end

    test "a new letter_key with the very draft the form holds is a new letter",
         %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts(), %{"letter_key" => "a"})
      write(view)

      host(view, "assign", "d0", "b")
      refute letter_kept?(view)
      assert subject(view) == ["S0"]

      # The form holds the new key now: this is the same letter.
      write(view)
      host(view, "assign", "d1", "b")
      assert subject(view) == ["S1"]
      assert letter_kept?(view)
    end

    test "a key given for the first time names the letter the form holds", %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())
      write(view)

      host(view, "assign", "d0", "a")
      assert letter_kept?(view)

      host(view, "assign", "d1", "a")
      assert subject(view) == ["S1"]
      assert letter_kept?(view)
    end
  end

  describe "after the letter went" do
    defp send_it(view) do
      submit(view)
      assert_receive {:inbox_compose, "demo", {:sent, %Message{}}}, 3000
      assert sent?(view)
    end

    test "the same letter_key with another draft is a new letter", %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts(), %{"letter_key" => "k"})
      write_text(view)
      send_it(view)

      # The host still renders what it had: the letter stays as it is.
      render_click(view, "rerender", %{})
      assert sent?(view)

      host(view, "assign", "d1")

      refute sent?(view)
      assert subject(view) == ["S1"]
    end

    test "without a key the draft the letter was written from opens a new letter",
         %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())
      host(view, "retext", "d1")
      host(view, "assign", "d1")
      send_it(view)

      host(view, "assign", "d0")

      refute sent?(view)
      assert subject(view) == ["S0"]
    end

    test "a retext no longer changes a letter that went", %{conn: conn} = ctx do
      view = mount_host(ctx, conn, three_drafts())
      send_it(view)

      host(view, "retext", "d1")

      assert sent?(view)
      assert subject(view) == ["S0"]
    end
  end

  describe "a retext while a letter is on its way" do
    test "waits for the answer: applied after an error", %{conn: conn} = ctx do
      mode(:hold)
      view = mount_host(ctx, conn, three_drafts())
      write_text(view)
      submit(view)
      assert_receive {:around, task, _}, 2000

      host(view, "retext", "d1")
      assert subject(view) == ["typed"]

      send(task, :stop)

      eventually(fn -> subject(view) == ["S1"] end)
      assert chips(view) != []
    end

    test "a new draft that waits too wins over a retext, in either order", %{conn: conn} = ctx do
      for order <- [:retext_first, :draft_first] do
        mode(:hold)
        view = mount_host(ctx, conn, three_drafts())
        write_text(view)
        submit(view)
        assert_receive {:around, task, _}, 2000

        case order do
          :retext_first ->
            host(view, "retext", "d1")
            host(view, "assign", "d2")

          :draft_first ->
            host(view, "assign", "d2")
            host(view, "retext", "d1")
        end

        send(task, :stop)
        eventually(fn -> subject(view) == ["S2"] end)
        assert chips(view) != []
      end
    end

    test "is dropped when the letter went", %{conn: conn} = ctx do
      mode(:hold)
      view = mount_host(ctx, conn, three_drafts())
      write_text(view)
      submit(view)
      assert_receive {:around, task, _}, 2000

      host(view, "retext", "d1")
      send(task, :go)

      assert_receive {:inbox_compose, "demo", {:sent, %Message{subject: "typed"}}}, 3000
      assert subject(view) == ["typed"]
    end
  end

  describe "the sender after a retext, when the person may choose it" do
    defp chosen(view),
      do: view |> q("#compose-demo-from-select option[selected]") |> LazyHTML.attribute("value")

    defp choose(view, key),
      do: view |> form("#compose-demo-from-form") |> render_change(%{"from" => key})

    test "keeps the person's choice while the draft's sender is the same", %{conn: conn} = ctx do
      drafts = %{
        "d0" => draft(subject: "S0", from: :user_default, from_editable: true),
        "d1" => draft(subject: "S1", from: :user_default, from_editable: true)
      }

      view = mount_host(ctx, conn, drafts)
      choose(view, "identity:" <> ctx.common.uuid)
      assert chosen(view) == ["identity:" <> ctx.common.uuid]

      host(view, "retext", "d1")

      assert subject(view) == ["S1"]
      assert chosen(view) == ["identity:" <> ctx.common.uuid]
    end

    test "follows the draft when its sender changed", %{conn: conn} = ctx do
      drafts = %{
        "d0" => draft(subject: "S0", from: :user_default, from_editable: true),
        "d1" => draft(subject: "S1", from: {:identity, ctx.common.uuid}, from_editable: true)
      }

      view = mount_host(ctx, conn, drafts)
      assert chosen(view) == ["user_default"]

      host(view, "retext", "d1")

      assert chosen(view) == ["identity:" <> ctx.common.uuid]
    end
  end

  describe "the sender after a retext" do
    test "with a fixed sender the form shows the one the letter goes from", %{conn: conn} = ctx do
      shared = shared_mailbox_fixture(ctx.alice, %{})
      bob = [%{user: ctx.bob.uuid, label: "Bob", route: :internal}]

      drafts = %{
        "d0" => draft(to: bob, subject: "S0", from: :user_default, from_editable: false),
        "d1" => draft(to: bob, subject: "S1", from: {:mailbox, shared.uuid}, from_editable: false)
      }

      view = mount_host(ctx, conn, drafts)
      refute render(view) =~ shared.name
      assert has_element?(view, "#compose-demo-personal-note")

      host(view, "retext", "d1")

      assert render(view) =~ shared.name
      refute has_element?(view, "#compose-demo-personal-note")

      submit(view)
      assert_receive {:inbox_compose, "demo", {:sent, %Message{} = message}}, 3000
      assert message.sender_mailbox_uuid == shared.uuid
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
