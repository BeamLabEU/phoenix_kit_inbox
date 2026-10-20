defmodule PhoenixKitInbox.Web.MailboxesLiveTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes

  setup %{conn: conn} do
    enable_inbox!()
    alice = user_fixture()

    %{conn: conn, alice: alice}
  end

  defp as(conn, user, permissions) do
    put_test_scope(
      conn,
      fake_scope(user_uuid: user.uuid, email: user.email, roles: [], permissions: permissions)
    )
  end

  test "without inbox.manage_shared the create form is not offered", ctx do
    {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), "/en/admin/inbox/mailboxes")

    refute has_element?(view, "#new-shared-mailbox-form")
  end

  test "a forged create event without inbox.manage_shared creates nothing", ctx do
    {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), "/en/admin/inbox/mailboxes")

    html =
      render_hook(view, "create", %{
        "mailbox" => %{"name" => "Forged", "slug" => "", "address" => "forged@example.com"}
      })

    assert html =~ "You don&#39;t have permission"
    assert Mailboxes.list_shared_mailboxes() == []
  end

  test "with inbox.manage_shared a shared mailbox is created", ctx do
    conn = as(ctx.conn, ctx.alice, ["inbox", "inbox.manage_shared"])
    {:ok, view, _html} = live(conn, "/en/admin/inbox/mailboxes")

    assert has_element?(view, "#new-shared-mailbox-form")

    view
    |> form("#new-shared-mailbox-form", %{
      "mailbox" => %{"name" => "Front Desk", "slug" => "", "address" => "front@example.com"}
    })
    |> render_submit()

    assert [mailbox] = Mailboxes.list_shared_mailboxes()
    assert mailbox.name == "Front Desk"
    assert mailbox.owner_uuid == ctx.alice.uuid
  end
end
