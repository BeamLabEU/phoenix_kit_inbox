defmodule PhoenixKitInbox.Web.ScopeRefreshTest do
  @moduledoc """
  Open pages learn about access changes: a new scope from core's refresh
  (`phoenix_kit_scope_changed/1`, driven through core's own
  `refresh_view_scope_assigns/1` by `LiveCase.refresh_scope/2`) and Inbox's
  own access events (`PhoenixKitInbox.AccessEvents`). Nothing stale stays on
  the page, and the next action runs with the new scope.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Signatures
  alias PhoenixKitInbox.Test.Hooks

  @manage ["inbox", "inbox.manage_shared"]
  @external ["inbox", "inbox.send_external"]

  setup %{conn: conn} do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})

    %{
      conn: conn,
      admin: admin,
      alice: alice,
      bob: bob,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      desk: desk,
      manage: scope_for(admin, @manage)
    }
  end

  defp as(conn, scope), do: put_test_scope(conn, scope)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The topics the LiveView process is subscribed to on core's PubSub.
  defp topics(view), do: Registry.keys(:phoenix_kit_internal_pubsub, view.pid)

  defp external_topic(mailbox), do: "phoenix_kit_inbox:external:#{mailbox.uuid}"

  describe "Inbox" do
    test "losing the inbox permission empties the page; a forged action does nothing", ctx do
      {:ok, message} =
        Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
          "to" => ctx.alice.email,
          "subject" => "Before",
          "body" => "Visible until revoked"
        })

      {:ok, view, html} =
        live(as(ctx.conn, scope_for(ctx.alice)), Paths.inbox(message: message.uuid))

      assert html =~ "Visible until revoked"

      # Another permission keeps the admin area, so the test hook (core's
      # decision, no module key in tests) leaves the page to be looked at.
      html = refresh_scope(view, scope_for(ctx.alice, ["integrations"]))

      assert html =~ "You don&#39;t have permission to use Inbox."
      refute html =~ "Visible until revoked"
      assert assigns(view).mailboxes == []
      assert assigns(view).selected == nil
      refute external_topic(ctx.alice_mb) in topics(view)

      render_click(view, "toggle_star", %{"uuid" => message.uuid})
      {:ok, entry} = Messages.fetch_for_mailbox(ctx.alice_mb.uuid, message.uuid)
      refute entry.delivery.starred
    end

    test "a grant shows the new mailbox and follows its external sends", ctx do
      {:ok, view, _html} = live(as(ctx.conn, scope_for(ctx.alice)), Paths.inbox())
      refute has_element?(view, "#mailbox-switch-form")

      {:ok, _} = Mailboxes.grant_access(ctx.manage, ctx.desk, ctx.alice.uuid, "read")
      render(view)

      assert has_element?(view, "#mailbox-switch-form option[value='#{ctx.desk.uuid}']")
      assert external_topic(ctx.desk) in topics(view)
    end

    test "a refresh reads the open message again without marking it seen", ctx do
      {:ok, message} =
        Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
          "to" => ctx.alice.email,
          "subject" => "Keep unseen",
          "body" => "Body"
        })

      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice)), Paths.inbox(message: message.uuid))

      # The list was read before opening marked it seen: the first toggle
      # catches up, the second marks it unseen.
      render_click(view, "toggle_seen", %{"uuid" => message.uuid})
      render_click(view, "toggle_seen", %{"uuid" => message.uuid})
      {:ok, entry} = Messages.fetch_for_mailbox(ctx.alice_mb.uuid, message.uuid)
      assert entry.delivery.seen_at == nil

      {:ok, _} = Mailboxes.grant_access(ctx.manage, ctx.desk, ctx.alice.uuid, "read")
      render(view)

      assert assigns(view).selected.message.uuid == message.uuid
      {:ok, entry} = Messages.fetch_for_mailbox(ctx.alice_mb.uuid, message.uuid)
      assert entry.delivery.seen_at == nil
    end

    test "an archived mailbox left open keeps its external updates until it is left", ctx do
      grant_fixture(ctx.desk, ctx.alice, "read")

      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice)), Paths.inbox(mailbox: ctx.desk.uuid))

      {:ok, _} = Mailboxes.archive_mailbox(ctx.manage, ctx.desk)
      render(view)

      assert assigns(view).mailbox.uuid == ctx.desk.uuid
      refute Enum.any?(assigns(view).mailboxes, &(&1.uuid == ctx.desk.uuid))
      assert external_topic(ctx.desk) in topics(view)

      render_patch(view, Paths.inbox())
      refute external_topic(ctx.desk) in topics(view)
      assert external_topic(ctx.alice_mb) in topics(view)
    end

    test "a revoked grant on the open mailbox goes back to the personal one", ctx do
      grant_fixture(ctx.desk, ctx.alice, "read")

      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice)), Paths.inbox(mailbox: ctx.desk.uuid))

      assert assigns(view).mailbox.uuid == ctx.desk.uuid

      :ok = Mailboxes.revoke_access(ctx.manage, ctx.desk, ctx.alice.uuid)
      render(view)

      assert_patch(view, Paths.inbox())
      html = render(view)
      assert html =~ "You no longer have access to “Desk”."
      assert assigns(view).mailbox.uuid == ctx.alice_mb.uuid
      refute has_element?(view, "#mailbox-switch-form")
      refute external_topic(ctx.desk) in topics(view)
    end
  end

  describe "Compose" do
    setup :outbound_setup

    setup ctx do
      smtp = mail_integration_fixture(:system, username: "noreply@company.test")
      senders = grant_role!(ctx.alice, @external)

      {:ok, common} =
        Identities.create_shared(ctx.manage, %{
          "label" => "Common",
          "from_name" => "Company",
          "integration_uuid" => smtp
        })

      Map.merge(ctx, %{senders: senders, common: common})
    end

    defp type(view, params) do
      view
      |> element("#compose-form")
      |> render_change(
        Map.merge(%{"to" => "", "cc" => "", "bcc" => "", "subject" => "", "body" => ""}, params)
      )
    end

    test "losing write on the sending mailbox switches to the personal one, keeping the text",
         ctx do
      grant_fixture(ctx.desk, ctx.alice, "write")
      scope = scope_for(ctx.alice, @external, [ctx.senders])

      {:ok, view, _html} = live(as(ctx.conn, scope), Paths.compose(mailbox: ctx.desk.uuid))
      assert assigns(view).mailbox.uuid == ctx.desk.uuid

      type(view, %{"to" => "@#{ctx.bob.username}", "subject" => "Kept", "body" => "Typed text"})

      :ok = Mailboxes.revoke_access(ctx.manage, ctx.desk, ctx.alice.uuid)
      html = render(view)

      assert html =~ "You can no longer send from “Desk”"
      assert assigns(view).mailbox.uuid == ctx.alice_mb.uuid
      assert Enum.map(assigns(view).mailboxes, & &1.uuid) == [ctx.alice_mb.uuid]
      assert has_element?(view, "input[name='to'][value='@#{ctx.bob.username}']")
      assert has_element?(view, "input[name='subject'][value='Kept']")
      assert html =~ "Typed text"
    end

    test "a revoked inbox.send_external drops the chosen sender; an external send is refused",
         ctx do
      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice, @external, [ctx.senders])), Paths.compose())

      type(view, %{"to" => "client@example.com", "identity_uuid" => ctx.common.uuid})
      assert has_element?(view, "#compose-identity option[selected][value='#{ctx.common.uuid}']")

      html = refresh_scope(view, scope_for(ctx.alice, ["inbox"], [ctx.senders]))

      assert html =~ "The sender you chose is no longer available"
      refute has_element?(view, "#compose-identity")
      assert assigns(view).form.params["identity_uuid"] == ""
      assert has_element?(view, "input[name='to'][value='client@example.com']")

      view
      |> element("#compose-form")
      |> render_submit(%{
        "to" => "client@example.com",
        "subject" => "Offer",
        "body" => "Hello",
        "identity_uuid" => ctx.common.uuid
      })

      assert render_async(view) =~ "You can&#39;t send as that sender."
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
      refute_received {:outbound, _, _, _}
    end

    test "a sender closed to the user's roles elsewhere leaves the open compose", ctx do
      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice, @external, [ctx.senders])), Paths.compose())

      type(view, %{"identity_uuid" => ctx.common.uuid})

      {:ok, _} = Identities.update_identity(ctx.manage, ctx.common, %{"role_uuids" => []})
      html = render(view)

      assert html =~ "The sender you chose is no longer available"
      refute has_element?(view, "#compose-identity")
    end

    test "a Reply-To that is no longer allowed is reset to the default", ctx do
      grant_fixture(ctx.desk, ctx.alice, "write")

      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice, @external, [ctx.senders])), Paths.compose())

      type(view, %{"reply_to" => "desk@company.test", "body" => "Hello"})
      assert has_element?(view, "#compose-reply-to option[selected][value='desk@company.test']")

      :ok = Mailboxes.revoke_access(ctx.manage, ctx.desk, ctx.alice.uuid)
      html = render(view)

      assert html =~ "The Reply-To you chose is no longer available"
      assert assigns(view).mailbox.uuid == ctx.alice_mb.uuid
      assert assigns(view).form.params["reply_to"] == ctx.alice.email
    end

    test "losing and regaining Inbox does not keep the draft of the mailbox left", ctx do
      grant_fixture(ctx.desk, ctx.alice, "write")
      params = %{"to" => "@#{ctx.bob.username}", "subject" => "Draft", "body" => "Body"}

      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice)), Paths.compose(mailbox: ctx.desk.uuid))

      type(view, params)
      render_click(view, "save_draft", %{})
      render_async(view)
      assert [_] = Messages.list_folder(ctx.desk.uuid, "drafts")

      # Inbox switched off and on again (core calls the page on a module
      # toggle too); another permission keeps the admin area.
      refresh_scope(view, scope_for(ctx.alice, ["integrations"]))
      refresh_scope(view, scope_for(ctx.alice))

      assert assigns(view).mailbox.uuid == ctx.alice_mb.uuid
      assert assigns(view).draft_uuid == nil

      view
      |> element("#compose-form")
      |> render_submit(Map.merge(%{"cc" => "", "bcc" => ""}, params))

      assert_redirect(view)
      assert [_] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
    end

    test "a grant offers the new mailbox in the From picker", ctx do
      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice, @external, [ctx.senders])), Paths.compose())

      refute has_element?(view, "select[name='mailbox']")

      {:ok, _} = Mailboxes.grant_access(ctx.manage, ctx.desk, ctx.alice.uuid, "write")
      render(view)

      assert has_element?(view, "select[name='mailbox'] option[value='#{ctx.desk.uuid}']")
      assert assigns(view).mailbox.uuid == ctx.alice_mb.uuid
    end
  end

  # The attachment policy holds a draft save in its task until the test
  # lets it go: the page is then "saving" for as long as the test needs.
  def hold(_scope, _users, _rows) do
    send(Application.get_env(:phoenix_kit_inbox, :hold_test_pid), {:held, self()})

    receive do
      :go -> :ok
    after
      5_000 -> :ok
    end
  end

  describe "Compose while a save runs" do
    setup :storage_setup

    setup ctx do
      grant_fixture(ctx.desk, ctx.alice, "write")
      # A reader besides the writer: the policy is asked about the desk's draft.
      grant_fixture(ctx.desk, ctx.bob, "read")
      other = shared_mailbox_fixture(ctx.admin, %{name: "Other"})

      Application.put_env(:phoenix_kit_inbox, :attachment_policy, {__MODULE__, :hold})
      Application.put_env(:phoenix_kit_inbox, :hold_test_pid, self())

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_inbox, :attachment_policy)
        Application.delete_env(:phoenix_kit_inbox, :hold_test_pid)
      end)

      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice)), Paths.compose(mailbox: ctx.desk.uuid))

      type(view, %{"to" => "@#{ctx.bob.username}", "subject" => "Draft", "body" => "Body"})

      view
      |> file_input("#compose-form", :attachments, [
        %{name: "scan.pdf", content: "%PDF", type: "application/pdf"}
      ])
      |> render_upload("scan.pdf")

      render_click(view, "save_draft", %{})
      assert_receive {:held, task}

      Map.merge(ctx, %{view: view, task: task, other: other})
    end

    defp type(view, params) do
      view
      |> element("#compose-form")
      |> render_change(
        Map.merge(%{"to" => "", "cc" => "", "bcc" => "", "subject" => "", "body" => ""}, params)
      )
    end

    defp finish(ctx) do
      send(ctx.task, :go)
      render_async(ctx.view)
      Application.delete_env(:phoenix_kit_inbox, :attachment_policy)
    end

    test "an access event is applied after it; the draft is neither lost nor doubled", ctx do
      {:ok, _} = Mailboxes.grant_access(ctx.manage, ctx.other, ctx.alice.uuid, "write")
      render(ctx.view)

      # Nothing moves under the running save.
      refute has_element?(ctx.view, "select[name='mailbox'] option[value='#{ctx.other.uuid}']")
      assert assigns(ctx.view).draft_uuid == nil

      finish(ctx)

      assert [%{message: draft}] = Messages.list_folder(ctx.desk.uuid, "drafts")
      assert assigns(ctx.view).mailbox.uuid == ctx.desk.uuid
      assert assigns(ctx.view).draft_uuid == draft.uuid
      assert has_element?(ctx.view, "select[name='mailbox'] option[value='#{ctx.other.uuid}']")

      render_click(ctx.view, "save_draft", %{})
      render_async(ctx.view)

      assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.desk.uuid, "drafts")
      assert uuid == draft.uuid
    end

    test "a grant revoked meanwhile: the save finishes in its mailbox, then the page moves",
         ctx do
      :ok = Mailboxes.revoke_access(ctx.manage, ctx.desk, ctx.alice.uuid)
      html = render(ctx.view)

      refute html =~ "You can no longer send from"
      assert assigns(ctx.view).mailbox.uuid == ctx.desk.uuid

      finish(ctx)

      assert [%{message: draft}] = Messages.list_folder(ctx.desk.uuid, "drafts")
      assert [%{filename: "scan.pdf"}] = PhoenixKitInbox.Attachments.list_for_message(draft.uuid)
      assert render(ctx.view) =~ "You can no longer send from “Desk”"
      assert assigns(ctx.view).mailbox.uuid == ctx.alice_mb.uuid
      assert assigns(ctx.view).draft_uuid == nil
      assert has_element?(ctx.view, "input[name='subject'][value='Draft']")

      render_click(ctx.view, "save_draft", %{})
      render_async(ctx.view)

      assert [_] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
      assert [_] = Messages.list_folder(ctx.desk.uuid, "drafts")
    end

    test "core's scope refresh is applied after it", ctx do
      refresh_scope(ctx.view, scope_for(ctx.alice, ["integrations"]))

      assert assigns(ctx.view).module_access
      assert assigns(ctx.view).mailbox.uuid == ctx.desk.uuid

      finish(ctx)

      assert [_] = Messages.list_folder(ctx.desk.uuid, "drafts")
      refute assigns(ctx.view).module_access
      assert assigns(ctx.view).mailbox == nil
      assert assigns(ctx.view).draft_uuid == nil
    end
  end

  describe "Mailboxes" do
    @path "/en/admin/inbox/mailboxes"

    test "losing inbox.manage_shared hides the create form, closes Signatures, refuses a create",
         ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.manage), @path)

      view |> element("button[phx-click='toggle_signatures']") |> render_click()
      assert has_element?(view, "#mailbox-signatures")
      assert has_element?(view, "#new-shared-mailbox-form")

      refresh_scope(view, scope_for(ctx.admin, ["inbox"]))

      refute has_element?(view, "#new-shared-mailbox-form")
      refute has_element?(view, "#mailbox-signatures")
      refute has_element?(view, "button[phx-click='toggle_signatures']")

      render_hook(view, "create", %{"mailbox" => %{"name" => "Forged"}})
      assert Enum.map(Mailboxes.list_shared_mailboxes(), & &1.name) == ["Desk"]

      render_click(view, "sig_new", %{})

      render_submit(view, "sig_save", %{
        "signature" => %{"label" => "Forged", "body" => "x"}
      })

      assert Signatures.list(ctx.desk.uuid) == []
    end

    test "a revoked admin grant closes the open Access panel and drops the row", ctx do
      grant_fixture(ctx.desk, ctx.alice, "admin")

      {:ok, view, _html} = live(as(ctx.conn, scope_for(ctx.alice)), @path)
      view |> element("button[phx-click='toggle_grants']") |> render_click()
      assert has_element?(view, "#grant-form")

      :ok = Mailboxes.revoke_access(ctx.manage, ctx.desk, ctx.alice.uuid)
      render(view)

      refute has_element?(view, "#grant-form")
      assert assigns(view).mailboxes == []

      render_submit(view, "grant", %{"user_uuid" => ctx.bob.uuid, "access" => "admin"})
      assert Mailboxes.list_grants(ctx.desk.uuid) == []
    end

    test "losing the inbox permission empties the list", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.manage), @path)
      assert assigns(view).mailboxes != []

      html = refresh_scope(view, scope_for(ctx.admin, ["integrations"]))

      assert html =~ "You don&#39;t have permission to use Inbox."
      assert assigns(view).mailboxes == []
    end
  end

  describe "Mail settings (shared)" do
    test "losing inbox.manage_shared removes the senders; a forged add is refused", ctx do
      smtp = mail_integration_fixture(:system, username: "noreply@company.test")

      {:ok, _} =
        Identities.create_shared(ctx.manage, %{"label" => "Common", "integration_uuid" => smtp})

      {:ok, view, _html} = live(as(ctx.conn, ctx.manage), "/en/admin/settings/inbox")
      assert has_element?(view, "#shared-identities")

      html = refresh_scope(view, scope_for(ctx.admin, ["inbox"]))

      refute has_element?(view, "#shared-identities")
      assert html =~ "Shared mail is managed by holders"
      assert assigns(view).identities == []

      html = render_click(view, "ident_new", %{})
      assert html =~ "You don&#39;t have permission"
      assert assigns(view).ident_form == nil
    end
  end

  describe "My mail settings" do
    @my "/en/dashboard/inbox-settings"

    test "losing the inbox permission leaves the page with a flash", ctx do
      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice, ["inbox", "integrations"])), @my)

      send_scope_refresh(view, scope_for(ctx.alice, ["integrations"]))

      {path, flash} = assert_redirect(view)
      assert path == Paths.dashboard()
      assert flash["error"] =~ "You no longer have access to Inbox."
    end

    test "losing every permission leaves it to core's eviction, without a second navigation",
         ctx do
      {:ok, view, _html} = live(as(ctx.conn, scope_for(ctx.alice)), @my)

      send_scope_refresh(view, scope_for(ctx.alice, []))

      {path, flash} = assert_redirect(view)
      assert path == Hooks.eviction_path()
      assert flash["error"] =~ "core eviction"
    end

    test "losing the integrations permission hides the connections link", ctx do
      {:ok, view, _html} =
        live(as(ctx.conn, scope_for(ctx.alice, ["inbox", "integrations"])), @my)

      assert has_element?(view, "#my-integrations-link")

      refresh_scope(view, scope_for(ctx.alice, ["inbox"]))

      refute has_element?(view, "#my-integrations-link")
    end

    test "a grant on a shared mailbox with an address offers it as Reply-To", ctx do
      {:ok, view, _html} = live(as(ctx.conn, scope_for(ctx.alice)), @my)
      refute has_element?(view, "#reply-to-form option[value='desk@company.test']")

      {:ok, _} = Mailboxes.grant_access(ctx.manage, ctx.desk, ctx.alice.uuid, "write")
      render(view)

      assert has_element?(view, "#reply-to-form option[value='desk@company.test']")
    end
  end
end
