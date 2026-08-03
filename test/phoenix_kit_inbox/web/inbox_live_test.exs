defmodule PhoenixKitInbox.Web.InboxLiveTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages

  setup %{conn: conn} do
    alice = user_fixture()
    bob = user_fixture()

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    conn = put_test_scope(conn, fake_scope(user_uuid: alice.uuid, email: alice.email))

    %{conn: conn, alice: alice, bob: bob, alice_mb: alice_mb, bob_mb: bob_mb}
  end

  test "renders the folder sidebar and the empty reading pane", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/inbox")

    assert html =~ "Inbox"
    assert html =~ "Sent"
    assert html =~ "Drafts"
    assert html =~ "Spam"
    assert html =~ "Trash"
    assert html =~ "Archive"
    assert html =~ "Select any message in the list to view it here."
  end

  test "an empty folder shows the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/inbox")

    assert html =~ "Empty list."
  end

  test "a received message appears in the list", %{conn: conn, alice: alice, bob: bob} do
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    {:ok, _} =
      Messages.send_message(bob_mb, bob.uuid, %{
        "to" => alice.email,
        "subject" => "Ping from Bob",
        "body" => "Are you there?"
      })

    {:ok, _view, html} = live(conn, "/en/admin/inbox")

    assert html =~ "Ping from Bob"
    assert html =~ "Are you there?"
  end

  test "opening a message renders it and marks it seen", %{conn: conn, alice: alice, bob: bob} do
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)

    {:ok, message} =
      Messages.send_message(bob_mb, bob.uuid, %{
        "to" => alice.email,
        "subject" => "Open me",
        "body" => "The body text"
      })

    {:ok, view, _html} = live(conn, "/en/admin/inbox")

    html = view |> element("li[phx-value-uuid='#{message.uuid}']") |> render_click()

    assert html =~ "The body text"
    assert html =~ "Reply"

    assert {:ok, %{delivery: delivery}} = Messages.fetch_for_mailbox(alice_mb.uuid, message.uuid)
    assert delivery.seen_at
  end

  test "switching folders patches the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/inbox")

    view |> element("button[phx-value-folder='sent']") |> render_click()

    assert_patched(view, "/en/admin/inbox?folder=sent")
  end

  test "a message can be trashed from the reading pane", %{conn: conn, alice: alice, bob: bob} do
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)

    {:ok, message} =
      Messages.send_message(bob_mb, bob.uuid, %{"to" => alice.email, "subject" => "Junk"})

    {:ok, view, _html} = live(conn, "/en/admin/inbox?message=#{message.uuid}")

    view
    |> element("button[phx-click='move'][phx-value-folder='trash']")
    |> render_click()

    assert Messages.list_folder(alice_mb.uuid, "inbox") == []
    assert length(Messages.list_folder(alice_mb.uuid, "trash")) == 1
  end

  test "search filters the list", %{conn: conn, alice: alice, bob: bob} do
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    for subject <- ["Invoice March", "Holiday plans"] do
      {:ok, _} =
        Messages.send_message(bob_mb, bob.uuid, %{"to" => alice.email, "subject" => subject})
    end

    {:ok, view, _html} = live(conn, "/en/admin/inbox?search=Invoice")

    html = render(view)
    assert html =~ "Invoice March"
    refute html =~ "Holiday plans"
  end

  test "a user without the inbox permission sees only the denial notice", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(permissions: [], roles: []))

    {:ok, _view, html} = live(conn, "/en/admin/inbox")

    assert html =~ "You don&#39;t have permission to use Inbox."
    refute html =~ "Empty list."
  end
end
